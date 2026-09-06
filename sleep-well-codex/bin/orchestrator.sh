#!/usr/bin/env bash
# orchestrator.sh — sleep-well-codex 的唯一编排逻辑。由 launchd 每 5 分钟触发。
#
# 编排器是 shell 而不是 AI 会话。sleep-well 自陈「The orchestrator IS a Claude session,
# so a full Anthropic outage disables sleep-well itself — a monitor cannot watch its own
# death」。shell 编排器在两侧 AI 全挂时依然活着: 能重试、出早报、推「夜班挂了」。
#
# 一跳的语义: 抢到锁的那一跳一直工作到收工。
# ⚠️ 这里原先写着「其余触发发现锁被占毫秒级退出」——**那个机制并不存在**:
#    launchd.plist(5) 规定 job 运行期间的 interval 会被丢弃，根本不会有第二个实例
#    （Codex R14 P3）。抢锁保留是为手工调用与异常并发兜底。
# 等价于「长驻工作进程 + 5 分钟粒度死亡自动重启」——**仅覆盖崩溃，不覆盖挂起**，
# 挂起由进程内看门狗兜底。
#
# ⚠️ 变量展开紧接全角标点时一律 ${VAR}: bash 3.2 + 任意 UTF-8 locale 下 `$n（` 会被解析
# 成变量名 `n（` 而 set -u 立即退出（claude-handoff 项目实测三种 locale 全复现）。

set -uo pipefail
umask 077

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SELF_DIR/.." && pwd)"
CLI="$SKILL_DIR/lib/cli.mjs"
REVIEW_SH="${SLEEP_WELL_CLAUDE_REVIEW:-$HOME/.codex/skills/claude-handoff/scripts/claude-code-review.sh}"

ROOT="${SLEEP_WELL_ROOT:-$HOME/sleep-well}"
case "$ROOT" in
  /*) ;;
  *) printf 'SLEEP_WELL_ROOT 必须是绝对路径\n' >&2; exit 1 ;;
esac
mkdir -p "$ROOT" || exit 1
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || exit 1
SW_ACCOUNT_HOME="$(cd "$HOME" 2>/dev/null && pwd -P)" || exit 1
case "$ROOT" in
  /|"$SW_ACCOUNT_HOME")
    printf 'SLEEP_WELL_ROOT 不得是 / 或账户 HOME\n' >&2
    exit 1 ;;
esac
# Preserve the caller's real Codex configuration root before defining this
# skill's private runtime tree. A custom CODEX_HOME may hold the only valid
# login state and must not be overwritten by an internal variable.
SW_USER_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SW_RUNTIME_HOME="$ROOT/codex"
STATE_DIR="$SW_RUNTIME_HOME/state"
LOG_DIR="$SW_RUNTIME_HOME/logs"
LOCK="$ROOT/NIGHT.lock"
STOP_FILE="$ROOT/STOP"
HEARTBEAT="$STATE_DIR/heartbeat"
CONFIG="$SW_RUNTIME_HOME/config.json"
CODEX_BIN="${SLEEP_WELL_CODEX:-codex}"
PLIST_LABEL="com.user.sleepwell-codex"
# 心跳停滞多久算「持有者挂了」。必须大于单次 AI 调用超时，否则正常的长调用会被误判接管。
HANG_LIMIT_SECS="${SLEEP_WELL_HANG_LIMIT:-2700}"
# 看门狗轮询间隔与终止宽限期可覆写，以便做真实的进程终止回归测试。
WATCHDOG_POLL_SECS="${SLEEP_WELL_WATCHDOG_POLL:-30}"
WATCHDOG_GRACE_SECS="${SLEEP_WELL_WATCHDOG_GRACE:-30}"
# Commands that must run before the in-process watchdog can be armed (notably
# lock-owner ps probes and TERMINATED recovery) get their own short process-
# group timeout. This prevents a broken system shim from swallowing every
# later launchd interval before NIGHT.lock or a heartbeat exists.
STARTUP_TIMEOUT_SECS="${SLEEP_WELL_STARTUP_TIMEOUT:-15}"

# launchd 的非交互环境不保证包含用户在 shell rc 中添加的目录。
# 常见安装位置只在现有 PATH 后追加，确保调用方显式选择的二进制仍然优先。
for _d in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin; do
  [ -d "$_d" ] && PATH="$PATH:$_d"
done
if [ -d "$HOME/.nvm/versions/node" ]; then
  for _nb in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$_nb" ] && PATH="$PATH:$_nb"; done
fi
export PATH

mkdir -p "$LOG_DIR" "$STATE_DIR" || exit 1
chmod 700 "$ROOT" "$SW_RUNTIME_HOME" "$LOG_DIR" "$STATE_DIR" || exit 1
[ ! -e "$CONFIG" ] || chmod 600 "$CONFIG" || exit 1
RUNLOG="$LOG_DIR/orchestrator-$(date '+%Y-%m-%d').log"
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$RUNLOG"; }

# Shell arithmetic treats a leading zero as octal, while `test` compares these
# configuration strings as decimal. Normalize digits without arithmetic before
# any value is consumed by `$(( ... ))`, so values such as 08 cannot pass the
# range gate and then abort the process at the first calculation.
normalize_decimal() { # $1=unsigned decimal; prints canonical decimal
  local value="$1"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  while [ "${#value}" -gt 1 ] && [ "${value#0}" != "$value" ]; do
    value="${value#0}"
  done
  printf '%s' "$value"
}

if STARTUP_TIMEOUT_SECS="$(normalize_decimal "$STARTUP_TIMEOUT_SECS")"; then
  # Anything wider than the documented maximum is clamped without asking the
  # shell to parse an integer that may exceed its native range.
  [ "${#STARTUP_TIMEOUT_SECS}" -le 3 ] || STARTUP_TIMEOUT_SECS=300
else
  log "⚠️ SLEEP_WELL_STARTUP_TIMEOUT 非法，回落 15"
  STARTUP_TIMEOUT_SECS=15
fi
[ "$STARTUP_TIMEOUT_SECS" -lt 3 ] && STARTUP_TIMEOUT_SECS=3
[ "$STARTUP_TIMEOUT_SECS" -gt 300 ] && STARTUP_TIMEOUT_SECS=300

# Bound one startup/recovery command in its own process group. The regular
# watchdog is intentionally armed only after this process owns NIGHT.lock;
# this helper closes the smaller pre-lock window without creating competing
# watchdogs that share one heartbeat file.
run_startup_bounded() { # $1=diagnostic label, remaining args=command/function
  local label="$1" prev_m pid polls=0 max_polls rc
  shift
  max_polls=$((STARTUP_TIMEOUT_SECS * 10))
  case "$-" in *m*) prev_m=yes ;; *) prev_m=no ;; esac
  set -m
  ( "$@" ) &
  pid=$!
  [ "$prev_m" = no ] && set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$polls" -ge "$max_polls" ]; then
      log "⚠️ 启动阶段命令超时（${STARTUP_TIMEOUT_SECS}s）: ${label}"
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    polls=$((polls + 1))
  done
  wait "$pid" 2>/dev/null; rc=$?
  return "$rc"
}

bounded_capture() { # $1=diagnostic label, remaining args=command
  local label="$1" out rc value
  shift
  out="$(mktemp "${STATE_DIR}/startup-capture.XXXXXX")" || return 1
  run_startup_bounded "$label" "$@" >"$out" 2>>"$RUNLOG"; rc=$?
  value="$(<"$out")"
  rm -f "$out" 2>/dev/null
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$value"
}

# jq_get: 取 JSON 字段。**区分「解析失败」与「字段为空」**（Codex R1 #15）——
# 原实现把两者都折叠成空串，于是状态损坏导致 next-task 失败时，空 task.id 会被
# 当成「队列清空」而调 finalize。现在解析失败返回非零，调用处必须检查。
# 把任意 id 转成安全的文件名片段（Codex R16 #2）: 非 [A-Za-z0-9._-] 一律换成 _，
# 再拼上原 id 的 8 位哈希，避免 `a b` 与 `a-b` 编码后撞成同一个文件。
safe_id() {
  local raw="$1" cleaned h
  cleaned="$(printf '%s' "$raw" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-40)"
  # 哈希取自**原始 id**（不是截断后的），前 40 字节相同的两个长 id 才不会撞名。
  # ⚠️ 8 位十六进制只有 32 位防撞边界，**可构造碰撞**（Codex R18 #3 给出了实例:
  #    `A*40:32126` 与 `A*40:69965` 的 SHA-256 前八位同为 e27bc051，清理后的前 40 字节也相同）。
  #    碰撞会让两个任务混写同一份 `${sid}.md` 与输出文件。取 128 位。
  h="$(printf '%s' "$raw" | shasum -a 256 2>/dev/null | cut -c1-32)"
  # ⚠️ 哈希失败必须失败关闭（Codex R17 #2 / 自查 S-2）: 原来回落 `nohash`，
  #    于是所有 id 拼同一个后缀——长中文 id 全变下划线后**必然撞名**，
  #    两个任务的日志与 rotate 记录会写进同一组文件。哈希就是防撞的唯一边界，
  #    它失效时不能静默降级。
  if [ -z "$h" ]; then
    log "⚠️ 无法为任务 id 生成哈希（shasum 不可用），拒绝派生文件名"
    return 1
  fi
  # 前缀 `t_` 保证派生名不以点开头——以点开头的 id 会生成隐藏日志文件，难以发现（R17 #4）。
  printf 't_%s-%s' "$cleaned" "$h"
}

jq_get() {
  printf '%s' "$1" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let o; try{o=JSON.parse(s)}catch{process.exit(2)}
      let v=o; for(const k of process.argv[1].split("."))v=v?.[k];
      if(v===undefined||v===null){process.stdout.write("");process.exit(3)}
      process.stdout.write(String(v));
    })' "$2"
}
# cli_json: 调 cli.mjs 并要求成功；失败即中止本跳（绝不把失败当成空结果继续）
cli_json() {
  local o rc
  o="$(node "$CLI" "$@" 2>>"$RUNLOG")"; rc=$?
  if [ $rc -ne 0 ]; then log "cli 失败(rc=${rc}): $*"; return 1; fi
  printf '%s' "$o"
}

# ── 推送（ntfy.sh）────────────────────────────────────────────────────
NTFY_TOPIC=""
read_ntfy_topic_without_node() {
  # This runs before NIGHT.lock and the main watchdog exist, so use Bash's
  # builtin file read and parameter expansion only—no node/sed/head process is
  # allowed here. Capture the complete JSON string; push() later validates the
  # exact value and rejects escapes, dots, slashes, or other unsafe characters.
  local raw rest topic
  raw="$(<"$1")" 2>/dev/null || return 1
  case "$raw" in *'"ntfy_topic"'*) rest="${raw#*\"ntfy_topic\"}" ;; *) return 1 ;; esac
  case "$rest" in *:*) rest="${rest#*:}" ;; *) return 1 ;; esac
  case "$rest" in *\"*) rest="${rest#*\"}" ;; *) return 1 ;; esac
  topic="${rest%%\"*}"
  [ -n "$topic" ] || return 1
  printf '%s' "$topic"
}
if [ -f "$CONFIG" ]; then
  NTFY_TOPIC="$(read_ntfy_topic_without_node "$CONFIG" 2>/dev/null || true)"
fi
redact_push_text() {
  local s="$1"
  # ntfy topics are publicly subscribable. Never expose the account's home path.
  if [ -n "${HOME:-}" ]; then s="${s//${HOME}/\~}"; fi
  # Keep user-controlled text literal even if a future curl call regresses from --data-raw.
  case "$s" in @*|-*) s=" $s" ;; esac
  printf '%s' "$s"
}
truncate_push_text() {
  local limit="$1" input cleaned bytes
  input="$(cat)" || return 1
  # Filter C0/C1 controls before slicing so a queue title cannot become an
  # injected HTTP header. Array.from slices Unicode code points and therefore
  # never emits half of a UTF-8 character as printf '%.Ns' can.
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$input" | node -e 'let s=""; const n=Number(process.argv[1]); process.stdin.setEncoding("utf8"); process.stdin.on("data", d => { s += d; }); process.stdin.on("end", () => { process.stdout.write(Array.from(s).filter(c => !/\p{Cc}/u.test(c)).slice(0, n).join("")); });' "$limit" \
      && return 0
  fi
  # node may be the missing/broken dependency we are trying to report. Keep a
  # conservative byte-bounded fallback for the fixed short failure alerts.
  cleaned="$(printf '%s' "$input" | LC_ALL=C tr -d '\001-\037\177')" || return 1
  bytes="$(printf '%s' "$cleaned" | LC_ALL=C wc -c | tr -d ' ')" || return 1
  [ "$bytes" -le "$limit" ] || return 1
  printf '%s' "$cleaned"
}
push() {
  local safe_title safe_body
  log "PUSH[$1] $2"
  [ -z "$NTFY_TOPIC" ] && return 0
  # topic 未校验就拼进 URL 会静默改变端点（`a/../../evil`、`a?priority=5`）——
  # 来源是用户自己的 config.json，所以是配置错误而非攻击面，但错了会推到别处而无人知晓。
  case "$NTFY_TOPIC" in
    *[!A-Za-z0-9_-]*|'') log "⚠️ ntfy_topic 含非法字符（只允许 A-Za-z0-9_-），本次不推送"; return 0 ;;
  esac
  # 只推任务标题与状态——绝不推代码片段、路径、findings 正文（ntfy 是公开服务）。
  # 固定调用点不应传路径；这里再把 $HOME 替换成 ~ 作为纵深防御。
  safe_title="$(redact_push_text "$1")"
  safe_body="$(redact_push_text "$2")"
  # 任务标题来自 queue.md；按 Unicode code point 截断，既守住字符上限，也不
  # 会像 bash printf 的字节精度那样把中文截成非法 UTF-8。
  safe_title="$(printf '%s' "$safe_title" | truncate_push_text 60)" \
    || { log "PUSH 标题截断失败（已忽略）"; return 0; }
  safe_body="$(printf '%s' "$safe_body" | truncate_push_text 200)" \
    || { log "PUSH 正文截断失败（已忽略）"; return 0; }
  curl -fsS --max-time 10 -H "Title: $safe_title" --data-raw "$safe_body" \
    "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 \
    || log "PUSH 失败（已忽略）"
}

# Persist notification attempts across launchd retries.  The marker is a
# directory because mkdir is atomic even when two manual invocations race.
# A failed archive deliberately leaves the run active for retry; without this
# gate the same morning summary and archive alarm would be published every five
# minutes until the underlying disk/permission fault is repaired.
push_once() {
  local key="$1"; shift
  local marker="$STATE_DIR/.push-once-${key}"
  local fallback_marker="$SW_RUNTIME_HOME/.push-once-fallback-${key}"
  if [ -d "$marker" ] || [ -d "$fallback_marker" ]; then
    log "PUSH_ONCE[${key}] 已尝试，跳过重复通知"
    return 0
  fi
  if mkdir "$marker" 2>/dev/null; then
    push "$@"
  elif [ -d "$marker" ] || [ -d "$fallback_marker" ]; then
    # Another invocation won the atomic mkdir race.
    log "PUSH_ONCE[${key}] 已尝试，跳过重复通知"
  elif mkdir "$fallback_marker" 2>/dev/null; then
    # A corrupt or read-only state directory must not silence the only useful
    # failure alert. The runtime-root marker still deduplicates later ticks.
    log "PUSH_ONCE[${key}] 状态标记不可写，使用运行根备用标记"
    push "$@"
  elif [ -d "$fallback_marker" ]; then
    log "PUSH_ONCE[${key}] 已尝试，跳过重复通知"
  else
    # If neither durable location is writable, silence is worse than a repeat.
    log "⚠️ PUSH_ONCE[${key}] 无法持久化去重标记，降级直接通知"
    push "$@"
  fi
}
clear_push_once() {
  rmdir "$STATE_DIR/.push-once-$1" 2>/dev/null || true
  rmdir "$SW_RUNTIME_HOME/.push-once-fallback-$1" 2>/dev/null || true
}

# ── 锁 ────────────────────────────────────────────────────────────────
HAVE_LOCK=no
normalize_ps_start() {
  local raw="$1" dow mon day clock year extra
  read -r dow mon day clock year extra <<EOF
$raw
EOF
  [ -n "$dow" ] && [ -n "$mon" ] && [ -n "$day" ] \
    && [ -n "$clock" ] && [ -n "$year" ] && [ -z "$extra" ] || return 1
  printf '%s %s %s %s %s' "$dow" "$mon" "$day" "$clock" "$year"
}
_write_owner() {
  local started raw_started
  raw_started="$(bounded_capture "读取当前进程启动时间" ps -o lstart= -p $$)" || return 1
  started="$(normalize_ps_start "$raw_started")" || return 1
  [ -n "$started" ] || return 1
  printf '%s\n%s\n' "$$" "$started" >"$1"
}
_publish_lock() {
  # Write a complete owner record first, then publish it with one atomic hard
  # link. The previous mkdir-then-write sequence exposed a missing-owner window
  # in which a competitor could misclassify a brand-new lock as stale.
  local candidate
  candidate="$(mktemp "${LOCK}.owner.XXXXXX")" || return 1
  if ! _write_owner "$candidate"; then rm -f "$candidate"; return 1; fi
  # Use link(1), not ln(1): BSD `ln source existing-directory` succeeds by
  # creating `existing-directory/<basename>` and would falsely report that a
  # legacy directory lock had been acquired. link's target is always exact.
  if link "$candidate" "$LOCK" 2>/dev/null; then
    rm -f "$candidate"
    HAVE_LOCK=yes
    return 0
  fi
  rm -f "$candidate"
  return 1
}
_lock_owner_path() {
  # Read legacy directory locks as well so upgrades do not steal a live lock.
  if [ -d "$LOCK" ] && [ ! -L "$LOCK" ]; then printf '%s\n' "$LOCK/owner"; else printf '%s\n' "$LOCK"; fi
}
_remove_lock_artifact() {
  if [ -d "$1" ] && [ ! -L "$1" ]; then rm -rf "$1"; else rm -f "$1"; fi
}
acquire_lock() {
  _publish_lock && { clear_push_once lock-anomaly; return 0; }
  local pid started raw_owner_started owner
  owner="$(_lock_owner_path)"
  pid="$(sed -n 1p "$owner" 2>/dev/null)"
  raw_owner_started="$(sed -n 2p "$owner" 2>/dev/null)"
  started="$(normalize_ps_start "$raw_owner_started" 2>/dev/null || true)"
  # A missing owner field means the live/stale distinction is unavailable. Do
  # not steal a possibly-live lock; fail closed and leave it for diagnosis.
  if [ -z "$pid" ] || [ -z "$started" ]; then
    log "锁 owner 记录不完整，无法可靠判断是否陈旧，本跳退出"
    return 2
  fi
  # PID 会被复用（重启后尤其常见）——只判 kill -0 会把无关的长寿进程当成锁持有者，
  # 于是每次启动都退出、永远不开工且无告警（Codex R4 #15）。加进程启动时间比对。
  local current_started=""
  if kill -0 "$pid" 2>/dev/null; then
    local raw_current_started
    raw_current_started="$(bounded_capture "读取锁持有者启动时间" ps -o lstart= -p "$pid")" \
      || { log "无法读取锁持有者启动时间，本跳退出"; return 2; }
    current_started="$(normalize_ps_start "$raw_current_started")" \
      || { log "锁持有者启动时间格式异常，本跳退出"; return 2; }
    [ -n "$current_started" ] \
      || { log "锁持有者启动时间为空，本跳退出"; return 2; }
  fi
  if [ -n "$current_started" ] && [ "$current_started" = "$started" ]; then
    # 持有者活着就退出本跳。**不在这里做挂起接管**（Codex R9 #1）:
    # launchd.plist(5) 原文——「If the job is running during an interval firing,
    # that interval firing will likewise be missed.」持有者挂起时 launchd 根本不会
    # 起第二个实例，接管代码永远执行不到，是死代码。挂起由**进程内看门狗**兜底，见 start_watchdog。
    log "锁被 pid ${pid} 持有，本跳退出"; return 1
  fi
  # 陈旧锁接管必须原子（Codex R1 #1）: 原实现直接覆写 owner，两个同时发现陈旧锁的
  # 进程会**都**认为自己拿到了锁，且其一退出时删掉另一个正在用的锁。
  # 用 mv 把陈旧锁改名——rename 是原子的，只有一个进程能成功——再正常 mkdir 抢。
  local stale="${LOCK}.stale.$$.$(date +%s)"
  if mv "$LOCK" "$stale" 2>/dev/null; then
    _remove_lock_artifact "$stale"
    log "已移除陈旧锁（原持有者 pid ${pid:-未知} 不存在）"
    _publish_lock && return 0
  fi
  log "陈旧锁接管竞争失败，本跳退出"; return 1
}
release_lock() { [ "$HAVE_LOCK" = yes ] && _remove_lock_artifact "$LOCK"; }

# Relinquish every runtime ownership artifact before asking launchd to unload
# this job. `launchctl unload` may terminate the running instance, so cleanup
# cannot be deferred exclusively to an EXIT trap.
release_runtime_ownership() {
  stop_watchdog
  if [ "$HAVE_LOCK" = yes ]; then
    rm -f "$ACTIVE_PGID_FILE" 2>/dev/null
    release_lock
    HAVE_LOCK=no
  fi
}

# ── 进程内看门狗（Codex R9 #1）────────────────────────────────────────
#
# 为什么不能靠 launchd: `StartInterval` 在 job 仍在运行时**丢弃**该次触发
# （launchd.plist(5) 原文）。所以「持有者挂起 → 下一跳接管」这条路根本不存在——
# R8 我把接管写在 acquire_lock 里，那是死代码。
#
# 看门狗是本进程 fork 出来的独立子进程: 父进程卡死时它照样在跑。
# 判据用「心跳是否推进」而不是绝对时长: 正常一跳可以很久（一个任务要跑实现+审查+修复
# 三次 AI 调用），但心跳每轮循环都会刷新。
#
# ⚠️ 两条关于「杀谁」的教训，缺一条就等于没杀（R10）:
#
#  (a) **编排器不是进程组组长**（我自查实测）。三种启动方式下 pgid 都不等于 $$:
#      shell 直接启动 / 管道中 / 由 wrapper 脚本调用，pgid 全是调用方 shell 的。
#      所以 `kill -TERM -$$` 要么打到一个不存在的组（失败后静默回退成单进程 kill，
#      「整组终止」的意图落空），要么打到一个同号的**无关**进程组。
#      ⇒ 不要杀「父进程组」，改为递归杀父进程的**进程树**。
#
#  (b) **AI 子进程根本不在父进程的组里**（Codex R10 #1）。`run_with_timeout` 用 set -m
#      把它放进了自己的组，正是为了能整组终止它。父进程停滞时那个循环也停了，
#      没人去终止那个分离的组；看门狗只杀父树的话，AI 进程会在锁与 hook 都恢复之后
#      **继续往仓库里写**——恰恰是 R9 #2 要根除的那个问题换了条路径复发。
#      ⇒ 活动子进程组号写进磁盘文件，看门狗先杀它，再杀父树。
ACTIVE_PGID_FILE="$STATE_DIR/active-pgid"
# >>>TESTABLE:watchdog>>>  （test/watchdog.test.sh 按这对标记抽取，勿删）

# 杀进程树。$3 = 要跳过的 pid（看门狗自己也是父进程的子进程，不跳过就会第一刀砍掉自己）。
#
# 两条约束打架，解法是**对根与后代区别对待**:
#
#  · 后代要先冻住再杀（Codex R11 #5）: `pgrep -P` 是一次快照，进程在收到信号前还能再 fork，
#    新孩子不在快照里，父死后被 reparent 到 init，后续遍历再也找不到——「杀干净了」其实没有。
#    SIGSTOP 不可捕获，冻住就 fork 不了。
#  · 但 **STOP 之后必须能不依赖 CONT 就结束它**（自查，已实测）: 若我在 STOP 与 CONT 之间
#    自己被杀（看门狗被 stop_watchdog 杀、或被父进程的 KILL 扫到），目标就**永久 stopped**——
#    状态 T、永不退出、不占 CPU、极难发现，比孤儿继续运行更糟。
#    实测确认 **SIGKILL 对 stopped 进程直接生效，不需要先 CONT**。
#  ⇒ 后代一律 STOP → 递归 → KILL，全程不需要 CONT，那个窗口根本不存在。
#
#  · 根进程（编排器）**不 STOP**: 它要收 TERM 好让 EXIT trap 跑完（释放锁、恢复 hook），
#    而 TERM 发给 stopped 进程会一直挂起。代价是根进程在收到 TERM 前还能再 fork 一次，
#    那个孩子会在根退出后被 reparent 而逃出后续遍历——**这是已知残留，没有解决**
#    （Codex R14 #9: 本注释原先声称由 `_kill_tree_sweep` 反复清扫兜底，
#     但 R13 改了顺序之后 sweep 已无生产调用者；对外边界见 SKILL.md 已知限制
#     「看门狗终止挂起编排器时的根进程再次 fork 窗口」）。
_kill_descendants() {
  local p="$1" skip="${2:-}" c
  for c in $(pgrep -P "$p" 2>/dev/null); do
    [ "$c" = "$skip" ] && continue
    kill -STOP "$c" 2>/dev/null       # 冻住，防止它在被杀前再 fork
    _kill_descendants "$c" "$skip"
    kill -KILL "$c" 2>/dev/null       # KILL 对 stopped 进程直接生效，无需 CONT
  done
  return 0
}
# （`_kill_tree_sweep` 已删除: R13 改顺序后它没有生产调用者了，留着会暗示一个
#   并不存在的兜底机制——根 fork 残留窗口是真实存在且未解决的，见上。）

WATCHDOG_PID=""
start_watchdog() {
  local ppid=$$
  local prev_m; case "$-" in *m*) prev_m=yes ;; *) prev_m=no ;; esac
  set -m
  (
    # 子 shell 里不用 local（bash 3.2 下行为不可靠），全用 wd_ 前缀的普通变量
    #
    # ⚠️⚠️ 不能写 wd_self=$$（Codex R11 #1，bash 3.2 实测）⚠️⚠️
    # bash 3.2 里子 shell 的 `$$` **仍是父进程的 PID**，而且没有 BASHPID。
    # 于是 wd_self == ppid，`_kill_tree "$ppid" ... "$wd_self"` 把**编排器本身**
    # 当成「看门狗自己」跳过了——AI 组是杀了，卡死的编排器却毫发无损，
    # 锁一直占着、EXIT 清理不跑、早报也没有。这是我第三次「挂起兜底看着对但根本没生效」:
    #   R8  写在 acquire_lock 里 → launchd 在 job 运行时不触发，死代码
    #   R10 kill -TERM -$ppid    → 编排器不是进程组组长，打空或打到无关组
    #   R11 _kill_tree 跳过自己  → 跳过的其实是编排器
    # 三次的共同点: **没有任何测试真的让看门狗去杀一个卡死的编排器**。已补 e2e。
    # `sh -c 'echo $PPID'` 里那个 $PPID 是 sh 的父进程 = 本子 shell，实测可用。
    wd_self="$(sh -c 'echo $PPID' 2>/dev/null)"
    case "$wd_self" in
      ''|*[!0-9]*|"$ppid")
        printf '%s ⚠️ 看门狗无法确定自身 PID，退出（宁可不看门，也不能误杀编排器）\n' \
          "$(date '+%H:%M:%S')" >>"$RUNLOG"; exit 0 ;;
    esac
    while kill -0 "$ppid" 2>/dev/null; do
      sleep "$WATCHDOG_POLL_SECS"
      kill -0 "$ppid" 2>/dev/null || exit 0
      # ⚠️ 遥测失败与确认停滞必须分开（Codex R9 #7）: 下面每一处失败都 continue，
      #    只有**成功读到并算出**心跳确实停滞才会走到终止那步。
      wd_hb="$(cat "$HEARTBEAT" 2>/dev/null)" || continue
      [ -n "$wd_hb" ] || continue
      wd_now="$(date -u +%s 2>/dev/null)" || continue
      wd_t="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$wd_hb" +%s 2>/dev/null)" || continue
      [ -n "$wd_t" ] || continue
      wd_age=$((wd_now - wd_t))
      [ "$wd_age" -lt "$HANG_LIMIT_SECS" ] && continue
      printf '%s ⚠️ 看门狗: 心跳停滞 %ss（上限 %ss），终止本跳\n' \
        "$(date '+%H:%M:%S')" "$wd_age" "$HANG_LIMIT_SECS" >>"$RUNLOG"
      # 1) 先终止分离的 AI 子进程组——父进程停滞时没有别人会去动它。
      # ⚠️ 文件内容是「owner_pid pgid」，只有 owner 是**当前编排器**时才采信
      #    （Codex R11 #4 / 我自查 T-1）: 进程若在 run_with_timeout 期间被 KILL，
      #    文件会残留；下一跳读到陈旧 pgid 而该号已被复用，就会打到无关进程组——
      #    正是 R10 #3 那条被我搬了个位置。三层设防: 开工前清残留 + owner 校验 + 存在性检查。
      wd_pg=""
      wd_rec="$(cat "$ACTIVE_PGID_FILE" 2>/dev/null)"
      wd_owner="${wd_rec%% *}"; wd_cand="${wd_rec##* }"
      if [ "$wd_owner" = "$ppid" ]; then
        case "$wd_cand" in
          ''|*[!0-9]*) : ;;
          *) if kill -0 -"$wd_cand" 2>/dev/null; then
               wd_pg="$wd_cand"
               kill -TERM -"$wd_pg" 2>/dev/null
               printf '%s   看门狗: 已向 AI 子进程组 %s 发 TERM\n' "$(date '+%H:%M:%S')" "$wd_pg" >>"$RUNLOG"
             fi ;;
        esac
      fi
      # 2) 给 AI 组宽限期（Codex R13 #2）: 它虽有独立 PGID，但**仍是编排器的后代**——
      #    原来紧接着就 _kill_tree_sweep，`_kill_descendants` 会立刻把它 STOP+KILL，
      #    上面那句 TERM 的优雅退出根本没机会生效，正在写文件的 codex 会被拦腰砍断。
      #    先等宽限期，再动树。
      sleep "$WATCHDOG_GRACE_SECS"
      [ -n "$wd_pg" ] && kill -0 -"$wd_pg" 2>/dev/null && kill -KILL -"$wd_pg" 2>/dev/null
      # 3) 树还完整时先清后代，再 TERM 根——顺序反了的话根一退出，后代就被 reparent，
      #    后续 `pgrep -P` 再也找不到它们（Codex R13 #3）。
      #    ⚠️ 仍有残留窗口: 根在收到 TERM 之前还能再 fork 一次，那个孩子会逃掉。
      #    根不能 STOP（TERM 发给 stopped 进程会一直挂起，EXIT trap 就跑不成），
      #    所以这一条是**已知残留**，明确写在 SKILL.md 已知限制
      #    「看门狗终止挂起编排器时的根进程再次 fork 窗口」。
      _kill_descendants "$ppid" "$wd_self"
      kill -TERM "$ppid" 2>/dev/null
      sleep "$WATCHDOG_GRACE_SECS"
      kill -0 "$ppid" 2>/dev/null && { _kill_descendants "$ppid" "$wd_self"; kill -KILL "$ppid" 2>/dev/null; }
      exit 0
    done
  ) &
  WATCHDOG_PID=$!
  # ⚠️ disown: set -m 打开了作业控制，之后 kill 这个后台作业时 bash 会把**整个函数体**
  #    作为「Terminated: 15 ...」打进 stderr——每次正常收工都刷一屏，
  #    而 launchd wrapper 把 stderr 写进 ~/Library/Logs/sleep-well/codex.err。刚修完误导性诊断，
  #    不能又用噪音把真正的错误淹掉。
  disown "$WATCHDOG_PID" 2>/dev/null || true
  [ "$prev_m" = no ] && set +m
  return 0
}
# 看门狗自成进程组（set -m），所以整组杀——只杀它本身会把它的 sleep 子进程留成孤儿（自查 T-2，实测）。
stop_watchdog() {
  [ -n "$WATCHDOG_PID" ] && { kill -TERM -"$WATCHDOG_PID" 2>/dev/null || kill -TERM "$WATCHDOG_PID" 2>/dev/null; }
  WATCHDOG_PID=""; return 0
}

# <<<TESTABLE:watchdog<<<

# 心跳原子写（Codex R9 #7）: 原地重定向会先截断，并发读能看到空文件。
beat() {
  local t="${HEARTBEAT}.tmp.$$"
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$t" 2>/dev/null && mv -f "$t" "$HEARTBEAT" 2>/dev/null
  rm -f "$t" 2>/dev/null
  return 0
}

# 内部错误退出必须推送（Codex R13 符合性扫查）: 这些路径都写 `FINISHED=yes; exit 1`，
# 而 on_exit 的异常推送恰恰以 `FINISHED != yes` 为条件——于是编排器因内部错误退出时
# **一声不吭**，用户早上既没有早报也没有告警，只能自己去翻日志。
hop_fail() {
  log "⚠️ 本跳异常退出: $1"
  # Internal state/CLI failures are not transient AI availability failures.
  # Stop once and self-unload so launchd cannot publish the same alert every
  # five minutes all night. finish_without_run preserves/archives active state.
  finish_without_run "内部错误" "$1" "⚠️ 夜班异常退出" 1 \
    "内部错误；$1；详情见本机日志"
}

# A planned launchd hand-off may leave implementing/reviewing/fixing state on
# disk. Publish run-bound proof only at the guarded exit boundary; a crash or
# SIGKILL cannot write it, so the next process will quarantine instead.
graceful_hop_exit() {
  local why="${1:-计划内跳退出}"
  cli_json graceful-hop-exit "$why" >/dev/null \
    || hop_fail "计划内跳退出标记写入失败"
  log "计划内跳退出: ${why}"
  FINISHED=yes
  exit 0
}

FINISHED=no
on_exit() {
  local code=$?
  if [ "$FINISHED" != yes ] && [ "$HAVE_LOCK" = yes ]; then
    log "编排器异常退出（code=${code}）"
    push "⚠️ 夜班异常退出" "退出码 ${code}，工作已存盘，下次触发会续跑"
  fi
  # hook 必须在 EXIT trap 里也恢复（Codex R3 #7）: 进程被 kill / 崩溃时
  # _process_task_inner 的包装层根本执行不到，用户的 pre-push 会被永久留下我们的版本。
  guard_uninstall 2>/dev/null || true
  # Only the lock holder owns the shared active-pgid ledger. A competing
  # launchd/manual invocation exits through this trap too and must not erase
  # the live holder's graceful AI-process-group shutdown record.
  release_runtime_ownership
}
trap on_exit EXIT

# ── 收工 ──────────────────────────────────────────────────────────────
# 顺序很重要（Codex R1 #2/#18）: 先把终止状态写进 state 让早报看到「已收工」而不是
# 「运行中」，再出早报；随后归档、落 TERMINATED 标记，最后卸载 launchd。
finalize() {
  local why="$1"
  # Terminal exits (cutoff, STOP, guard failure, exhausted retries) cannot
  # leave unfinished work looking non-actionable in the morning report. Force
  # every in-flight task to needs_human even when the prior process left a
  # valid planned-hop marker: there will be no next hop to resume it.
  if command -v node >/dev/null 2>&1 && [ -s "$STATE_DIR/current-run.json" ]; then
    local terminal_q terminal_q_n
    if terminal_q="$(cli_json quarantine-inflight force)" \
       && terminal_q_n="$(jq_get "$terminal_q" count)"; then
      clear_push_once finalize-quarantine-failure
      [ "$terminal_q_n" -gt 0 ] \
        && log "收工前已将 ${terminal_q_n} 个在途任务转 needs_human"
    else
      log "⚠️ 收工前无法隔离在途任务；早报中的任务状态可能不完整"
      push_once finalize-quarantine-failure \
        "⚠️ 夜班收工异常" "无法确认在途任务状态；请检查本机状态文件与目标仓库"
    fi
  fi
  log "收工: ${why}"
  # 持久化失败必须可见（Codex R3 #11）: 静默失败会让早报与 TERMINATED 状态互相矛盾
  if node "$CLI" mark-terminal-in-state "$why" >/dev/null 2>&1; then
    clear_push_once finalize-terminal-write-failure
  else
    log "⚠️ 终止状态写入失败"
    push_once finalize-terminal-write-failure \
      "⚠️ 夜班收工异常" "终止状态未能写入，请查看日志"
  fi
  # 早报生成失败时**不能照旧推「☀️ 夜班早报」**（R10 自查）: 手机上说早报好了、
  # 打开却是上一夜的陈旧文件，比不推更糟。失败就照实推告警。
  local report_ok=yes
  node "$SKILL_DIR/bin/report.mjs" >/dev/null 2>&1 || { report_ok=no; log "早报生成失败"; }
  local sum total done_n nh
  sum="$(node "$CLI" summary 2>/dev/null)" || sum='{}'
  total="$(jq_get "$sum" total || echo '?')"
  done_n="$(jq_get "$sum" byStatus.done || echo 0)"
  nh="$(jq_get "$sum" needsHuman || echo '')"
  if [ "$report_ok" = yes ]; then
    push_once finalize-summary "☀️ 夜班早报" "共 ${total} 任务，完成 ${done_n}${nh:+；待拍板 ${nh}}。收工原因: ${why}"
  else
    push_once finalize-summary "⚠️ 早报生成失败" "夜班已收工（${why}），但早报未能生成，请查看 logs/ 与各仓库 git log"
  fi
  # 顺序: 归档 → 落终止标记 → 最后才自卸载（Codex R2 #13: 先卸载可能打断归档）
  # 归档失败就不落 TERMINATED、不卸载（Codex R4 #14）: 否则状态既没归档又被标终止，
  # 下一夜 init 会看到残留的活动状态而行为不明。留着让下一跳重试收工。
  if ! node "$CLI" archive >/dev/null 2>&1; then
    log "⚠️ 归档失败——不落终止标记，下一跳重试收工"
    push_once archive-failure "⚠️ 夜班收工异常" "归档失败，将在下次触发重试"
    guard_uninstall 2>/dev/null || true
    FINISHED=yes; exit 1
  fi
  clear_push_once finalize-summary
  clear_push_once archive-failure
  clear_push_once finalize-quarantine-failure
  clear_push_once finalize-terminal-write-failure
  node "$CLI" terminal-set "${why}" >/dev/null 2>&1 \
    || { log "⚠️ TERMINATED 标记写入失败——下一跳可能重跑整夜"; push "⚠️ 夜班收工异常" "终止标记未写入"; }
  if ! guard_uninstall; then
    # hook 还没还回去就卸载 = 永远没有下一跳来重试（Codex R6 #4）
    log "⚠️ hook 未恢复，不卸载 launchd，留待下一跳重试"
    push "⚠️ 需要注意" "你的 pre-push hook 尚未恢复，夜班保持挂载以便重试"
    FINISHED=yes; exit 1
  fi
  # Unload can SIGTERM this very process. Publish the finished state and
  # release the lock/watchdog ledger before invoking it.
  FINISHED=yes
  release_runtime_ownership
  launchctl unload "$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist" 2>/dev/null \
    && log "已自卸载 launchd" || log "launchd 卸载跳过（可能未安装）"
  exit 0
}

# Stop cleanly before a new run exists, or when dependency loss interrupts an active run.
# The detailed error stays in the local log; the public ntfy body contains only a stable category.
finish_without_run() {
  local public_reason="$1" detail="$2" push_title="${3:-}" exit_code="${4:-0}"
  local public_body="${5:-${public_reason}；详情见本机日志}"
  local keep_loaded_if_unarchived="${6:-no}"
  local push_key="${7:-finish-without-run}"
  log "未开工收工: ${detail}"
  local had_active=no can_archive=yes
  local report_status='- 状态: 未开工或异常收工'
  local report_action=''
  if [ -s "$STATE_DIR/current-run.json" ]; then
    had_active=yes
    if command -v node >/dev/null 2>&1 \
       && node -e 'process.exit(0)' >/dev/null 2>&1; then
      local terminal_q terminal_q_n
      if terminal_q="$(cli_json quarantine-inflight force)" \
         && terminal_q_n="$(jq_get "$terminal_q" count)"; then
        [ "$terminal_q_n" -gt 0 ] \
          && log "异常收工前已将 ${terminal_q_n} 个在途任务转 needs_human"
      else
        log "⚠️ 异常收工前无法隔离在途任务；保留现状供人工诊断"
      fi
      # Dependency loss can happen after a run has started. Mark it terminal
      # before rendering so an unloaded job cannot still look active.
      if ! node "$CLI" mark-terminal-in-state "$public_reason" >/dev/null 2>&1; then
        # The active state may itself be corrupt. Preserve it in place for
        # diagnosis; the caller decides whether this path may terminate with
        # an unarchived state (for example an explicit STOP).
        log "⚠️ 活动运行的终止状态写入失败——保留原状态、不归档"
        can_archive=no
      fi
    else
      log "⚠️ 检测到活动运行但 node 不可用——保留原状态、不归档"
      can_archive=no
    fi
  fi
  if [ "$had_active" = yes ]; then
    [ -n "$push_title" ] || push_title='⚠️ 夜班异常收工'
    if [ "$can_archive" != yes ] && [ "$keep_loaded_if_unarchived" = yes ]; then
      report_status='- 状态: 本跳暂停；本夜已有活动运行（未归档）'
      report_action='- 待处理: 请检查本机状态文件与目标仓库残留；修复依赖后由下一跳重试'
    elif [ "$can_archive" != yes ]; then
      report_status='- 状态: 本跳终止；本夜已有活动运行（未归档）'
      report_action='- 待处理: 本夜不会自动重试；重新武装前请核对状态与仓库，并归档或改名隔离 current-run.json，再执行 terminal-clear 并重新 load'
      public_body="${public_body}；重新武装前请归档或改名隔离 current-run.json，再执行 terminal-clear 并重新 load"
    else
      report_status='- 状态: 本跳异常收工；检测到已有活动运行'
      report_action='- 后续: 将尝试归档活动状态；若归档失败会保持 loaded 并告警重试'
    fi
  else
    [ -n "$push_title" ] || push_title='⚠️ 夜班未开工'
  fi
  if ! node "$SKILL_DIR/bin/report.mjs" >/dev/null 2>&1; then
    log "早报生成失败（未开工路径），写入最小故障早报"
    local report_tmp="$SW_RUNTIME_HOME/morning-report.md.tmp.$$"
    mkdir -p "$SW_RUNTIME_HOME" 2>/dev/null
    { printf '# sleep-well-codex 早报\n\n';
      printf '%s\n' "$report_status";
      printf -- '- 原因: %s\n' "$public_reason";
      [ -z "$report_action" ] || printf '%s\n' "$report_action";
      printf -- '- 时间: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')";
      printf '\n完整诊断见本机日志。\n'; } >"$report_tmp" 2>/dev/null \
      && mv -f "$report_tmp" "$SW_RUNTIME_HOME/morning-report.md" 2>/dev/null \
      || { rm -f "$report_tmp" 2>/dev/null; log "最小故障早报写入失败"; }
  fi
  push_once "$push_key" "$push_title" "$public_body"
  if [ "$had_active" = yes ] && [ "$can_archive" != yes ] \
     && [ "$keep_loaded_if_unarchived" = yes ]; then
    # A dependency may recover on the next launchd interval. Keep the active
    # state attached to a live retry path; fixed push_once text prevents spam.
    log "⚠️ 活动状态未归档——不落 TERMINATED、不卸载，留待依赖恢复后重试"
    FINISHED=yes; exit 1
  fi
  if [ "$had_active" = yes ] && [ "$can_archive" = yes ] \
     && ! node "$CLI" archive >/dev/null 2>&1; then
    # Match finalize(): never leave a TERMINATED marker next to an unarchived
    # active run, because clearing the marker next night would revive stale state.
    log "⚠️ 活动运行归档失败——不落终止标记、不卸载，留待下一跳重试"
    push_once archive-failure "⚠️ 夜班收工异常" "活动状态归档失败，将在下次触发重试"
    guard_uninstall 2>/dev/null || true
    FINISHED=yes; exit 1
  fi
  clear_push_once "$push_key"
  clear_push_once archive-failure
  if ! node "$CLI" terminal-set "$public_reason" >/dev/null 2>&1; then
    # node itself may be the missing dependency. The orchestrator only checks
    # for marker existence, so a plain-text fallback still prevents a push loop.
    mkdir -p "$SW_RUNTIME_HOME" 2>/dev/null
    printf 'at=%s\nreason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$public_reason" \
      >"$SW_RUNTIME_HOME/TERMINATED" 2>/dev/null \
      || { log "⚠️ TERMINATED 标记写入失败（未开工路径）"; push "⚠️ 夜班收工异常" "终止标记未写入"; }
  fi
  FINISHED=yes
  release_runtime_ownership
  launchctl unload "$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist" 2>/dev/null \
    && log "已自卸载 launchd" || log "launchd 卸载跳过（可能未安装）"
  exit "$exit_code"
}

# ── 护栏 ──────────────────────────────────────────────────────────────
# **主门禁是 codex 自带的进程级沙箱**（见 run_codex）。2026-08-10 实测（含正对照）:
#   工作区内写 ✓允许 / 工作区外写 ✓阻断(Operation not permitted) /
#   push 到工作区外 bare 且带 --no-verify ✓阻断(remote rejected) / 网络 ✓阻断
#   已知放行: /tmp 等临时目录是 seatbelt 的可写根（设计如此，风险低）
#
# ⚠️ pre-push hook **不是**门禁，只防手滑: 实测 `--no-verify` 与
#    `core.hooksPath=/dev/null` 都能绕过（Codex R2 #1 指出，我已复现）。
#    它在这里仅作纵深防御，且必须保存/恢复用户原有的 hook（Codex R2 #2:
#    否则夜班跑一次就永久破坏用户自己的 push 流程）。
GUARD_HEAD=""; GUARD_REFS=""; GUARD_BRANCH=""; GUARD_PROT=""; GUARD_HOOK_BAK=""
GUARD_GIT_META=""; GUARD_META_DOTGIT=""; GUARD_META_GITDIR=""; GUARD_META_COMMON=""; GUARD_META_HOOKS=""
GUARD_ABORT_REASON="护栏不可得"
HOOK_PATH=""

# ── hook 恢复状态机（Codex R8 #6-#11 整体重做）──────────────────────────
#
# R7 为了让恢复元数据跨进程而加了 hook-recovery.json，却**重新引入了 R2 #2**
# （「夜班跑一次就永久破坏你自己的 push 流程」）——而且是在完全正常的路径上:
#   guard_install 写状态 → guard_uninstall 成功恢复但**不清状态**
#   → 下一跳 recover_pending_hook 拿着陈旧记录，无条件 rm 掉已经归位的用户 hook
#   → 备份已被 mv 走故 [ -e ] 为假 → 清状态、return 0（报告成功）
#   → 用户的 pre-push 就此消失，全程无告警。已实测复现。
#
# 重做的四条不变量:
#   1. 破坏性操作**之前**先原子落盘恢复意图（tmp + rename），且用 node 生成合法 JSON
#      （手写 printf 遇到路径里的 " 或 \ 会产出非法 JSON，解析失败后被当成「无事」）。
#   2. 只删**带哨兵串的、确实是我们装的** hook。用户自己的 hook 一律不碰。
#   3. 成功恢复后立刻清状态；这是 #6 的直接修复。
#   4. 任何「不确定」都失败关闭并保留状态: 元数据解析失败、记录了备份却找不到、
#      当前 hook 不是我们的但备份也在（冲突）——都不清状态、告警、返回非零。
# >>>TESTABLE:hook>>>  （test/hook-state.test.sh 按这对标记抽取，勿删）
HOOK_SENTINEL="sleep-well-codex-guard-hook-v1"
HOOK_STATE="$SW_RUNTIME_HOME/hook-recovery.json"

# 身份判据经过三轮才定型，三条约束缺一不可:
#   R9 #9  —— 不能是「包含公开的静态哨兵串」: 用户从我们的版本改来的 hook 会碰撞，
#             guard_uninstall 会把它当自己的删掉。
#   R10 #4 —— 不能用 `[ "$(cat f)" = "$(_hook_body)" ]`: 命令替换会剥掉两边的尾随换行，
#             于是「只多了几个空行」的外部改动仍被判为我们的，与声称的逐字节相等矛盾。
#   自查   —— 不能拿**代码里生成的内容**当基准: 将来改一行提示文案，上一版装下的 hook
#             就认不出来，guard_uninstall 走「不是我们的，保留不动」并返回非零 → 整夜停摆。
# ⇒ 用**每次安装生成的随机 token**（Codex R9 #9 原话「每次安装的不可伪造标识」）:
#   token 写进 hook、同时存进 hook-recovery.json，判据是拿存下来的 token 重建预期内容后
#   用 cmp 做**逐字节**比对。碰撞、版本迁移、尾随空白三个问题一次解决。
HOOK_TOKEN=""
_new_hook_token() {
  local t
  t="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 1
  [ -n "$t" ] || return 1
  printf '%s' "$t"
}
_hook_body() {   # $1=token
  printf '#!/bin/sh\n# %s %s\necho "sleep-well-codex: push 被夜班护栏阻断（纵深防御层）" >&2\nexit 1\n' \
    "$HOOK_SENTINEL" "$1"
}
# R9 时代的 hook 体（无 token）。只用于**一次性升级识别**，不参与常规判定——
# 常规判定必须用 token，否则就退回到 R9 #9 那个可碰撞的哨兵匹配。
_hook_is_legacy_ours() {
  [ -f "$1" ] || return 1
  [ -L "$1" ] && return 1
  local exp; exp="$(mktemp)" || return 1
  printf '#!/bin/sh\n# %s\necho "sleep-well-codex: push 被夜班护栏阻断（纵深防御层）" >&2\nexit 1\n' \
    "$HOOK_SENTINEL" >"$exp" 2>/dev/null || { rm -f "$exp"; return 1; }
  cmp -s "$1" "$exp"; local rc=$?
  rm -f "$exp"
  return $rc
}
_hook_is_ours() {   # $1=hook 路径 $2=token
  [ -f "$1" ] || return 1
  [ -L "$1" ] && return 1                       # 被换成符号链接就不是我们的
  [ -n "${2:-}" ] || return 1                   # 没有 token 就无法确认身份 → 一律当成不是我们的
  local exp; exp="$(mktemp)" || return 1
  _hook_body "$2" >"$exp" 2>/dev/null || { rm -f "$exp"; return 1; }
  cmp -s "$1" "$exp"; local rc=$?
  rm -f "$exp"
  return $rc
}

# 原子写: 先写临时文件再 rename（同一目录内 rename 是原子的）。
# 进程在中途被 SIGKILL 时，读到的要么是旧内容要么是新内容，不会是半截。
_write_hook_state() {
  local hp="$1" bk="$2" tok="$3" tmp
  tmp="$(mktemp "${HOOK_STATE}.XXXXXX")" || return 1
  node -e 'process.stdout.write(JSON.stringify({hook:process.argv[1],backup:process.argv[2],token:process.argv[3]}))' \
    "$hp" "$bk" "$tok" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$HOOK_STATE" 2>/dev/null || { rm -f "$tmp"; return 1; }
}
_clear_hook_state() { rm -f "$HOOK_STATE" 2>/dev/null; }

# 启动路径优先处理上一次遗留的恢复。返回非零 = 必须中止本跳（调用方不得继续装新 hook）。
recover_pending_hook() {
  [ -f "$HOOK_STATE" ] || return 0
  local raw hp bk tok
  if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(0)' >/dev/null 2>&1; then
    log "⚠️ node 不可用，无法解析 hook 恢复元数据；保留原文件待重试"
    return 2
  fi
  raw="$(cat "$HOOK_STATE" 2>/dev/null)" || {
    log "⚠️ hook 恢复元数据不可读，拒绝继续"; return 1; }
  # 解析失败**不等于**无需恢复（R8 #9）: 原实现把 jq_get 的失败折叠成空串然后删掉记录，
  # 于是既留下了阻断 hook，又丢掉了定位用户备份的唯一线索。
  hp="$(jq_get "$raw" hook)" || hp=""
  bk="$(jq_get "$raw" backup)" || bk=""
  tok="$(jq_get "$raw" token)" || tok=""
  if [ -z "$hp" ]; then
    log "⚠️ hook 恢复元数据损坏（保留原文件待人工处理）: $(printf '%.120s' "$raw")"
    return 1
  fi
  log "发现上一次遗留的 hook 恢复任务: ${hp}"

  if [ -n "$bk" ] && [ -e "$bk" ]; then
    # 有备份要还。只有「当前是我们的 hook」或「当前根本没有 hook」时才允许覆盖。
    # ⚠️ 无 token 的 R9 记录**也要能走到这里**（Codex R12 #4）: 我 R11 只把
    #    `_hook_is_legacy_ours` 接在「无备份」那一支上，而带用户备份的升级场景会进本支，
    #    `_hook_is_ours` 因 token 为空必然拒绝 → 阻断 hook 留着、用户 hook 困在备份名下、
    #    此后每一夜都拒绝开工。迁移必须两支都覆盖。
    if _hook_is_ours "$hp" "$tok" || { [ -z "$tok" ] && _hook_is_legacy_ours "$hp"; } || [ ! -e "$hp" ]; then
      rm -f "$hp" 2>/dev/null
      if mv "$bk" "$hp" 2>/dev/null; then
        log "已恢复用户原有 hook"; _clear_hook_state; return 0
      fi
      log "⚠️ 仍无法恢复原有 hook（备份: ${bk}）"
      return 1
    fi
    # 用户在崩溃后自己换了 hook——两份都留着，交人工（R8 #10）
    log "⚠️ 当前 pre-push 不是夜班装的，且备份仍在: 冲突，两份都保留待人工"
    return 1
  fi

  if [ -z "$bk" ]; then
    # 原本就没有用户 hook，只需撤掉我们自己的。
    # ⚠️ 但「认不出来」不等于「不用管」（Codex R11 #2）: R9 时代写下的恢复记录没有 token，
    #    `_hook_is_ours` 必然返回 false，而原来这里照样清状态并报告成功——
    #    **阻断 hook 就永久留在那儿了，用户的 git push 从此一直被拦**，且再无记录可循。
    #    后来的安装还会把它当成「用户自己的 hook」备份并恢复，把错误固化下去。
    if _hook_is_ours "$hp" "$tok"; then
      rm -f "$hp" 2>/dev/null || {
        log "⚠️ 无法移除遗留的夜班 hook: ${hp}"; return 1; }
    elif [ -e "$hp" ]; then
      # 无 token 的旧记录（R9 → R10 升级）: 用旧版哨兵体做一次性识别，认出来就清掉。
      if [ -z "$tok" ] && _hook_is_legacy_ours "$hp"; then
        log "识别出 R9 时代的夜班 hook（无 token 记录），已移除"
        rm -f "$hp" 2>/dev/null || {
          log "⚠️ 无法移除遗留的夜班 hook: ${hp}"; return 1; }
      else
        # 既不是本版的、也不是旧版的 —— 不认识就不动，更不能清掉唯一的记录
        log "⚠️ ${hp} 存在但无法确认归属，保留文件与恢复记录待人工"
        return 1
      fi
    fi
    _clear_hook_state; return 0
  fi

  # 记录过备份却找不到文件——绝不当成成功（R8 #12）。此时不动任何文件。
  log "⚠️ 恢复元数据记录了备份 ${bk} 但文件不存在，保留状态并中止"
  return 1
}

guard_install() {
  # 上一份用户 hook 还没归位时，绝不开新工——否则新的 _write_hook_state 会覆盖
  # 旧记录，把仍然存在的备份变成永久孤儿（R8 #7）。
  [ -f "$HOOK_STATE" ] && { log "存在未完成的 hook 恢复，拒绝安装新 hook"; return 1; }
  # linked worktree 的 .git 是**文件**，hooks 不在 repo/.git/hooks 下
  # （Codex R3 #13）。用 git 解析真实的 hooks 目录。
  local gitdir; gitdir="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$gitdir" in /*) : ;; *) gitdir="$1/$gitdir" ;; esac
  local hp="$gitdir/hooks/pre-push" bak=""
  mkdir -p "$gitdir/hooks" 2>/dev/null || { log "无法创建 hooks 目录"; return 1; }
  [ -e "$hp" ] && bak="${hp}.sleepwell-bak.$$"

  # 先落盘意图，再做破坏性操作（R8 #8）: 中途被 SIGKILL 也留得下完整记录。
  HOOK_TOKEN="$(_new_hook_token)" || { log "无法生成 hook 身份 token，拒绝安装"; return 1; }
  _write_hook_state "$hp" "$bak" "$HOOK_TOKEN" || { log "无法持久化 hook 恢复意图，拒绝安装"; return 1; }
  HOOK_PATH="$hp"; GUARD_HOOK_BAK="$bak"

  if [ -n "$bak" ]; then
    mv "$hp" "$bak" || { log "无法备份原有 pre-push hook"; _clear_hook_state; HOOK_PATH=""; GUARD_HOOK_BAK=""; return 1; }
  fi
  # 写入与 chmod 都要检查（R8 #11）: 脚本无 set -e，原实现在写失败后照样返回 0，
  # 任务会在**没有纵深 hook** 的情况下继续跑。任一步失败即回滚。
  if ! _hook_body "$HOOK_TOKEN" >"$hp" 2>/dev/null || ! chmod +x "$hp" 2>/dev/null; then
    log "⚠️ 写入夜班 hook 失败，回滚"
    rm -f "$hp" 2>/dev/null
    # ⚠️ 回滚的 mv 也可能失败（Codex R9 #10）: 原实现忽略它的返回值就无条件清状态，
    #    于是用户的 hook 留在备份名下、而下一跳已经没有自动恢复的记录了。
    #    只有确认备份归位才清状态；否则保留状态与备份，交给下一跳/人工。
    if [ -n "$bak" ] && [ -e "$bak" ]; then
      if ! mv "$bak" "$hp" 2>/dev/null; then
        log "⚠️ 回滚时无法还原原有 hook，保留恢复状态与备份: ${bak}"
        push "⚠️ 需要手动处理" "pre-push 安装失败且未能回滚，备份见日志"
        HOOK_PATH=""; GUARD_HOOK_BAK=""      # 不清状态文件
        return 1
      fi
    fi
    _clear_hook_state; HOOK_PATH=""; GUARD_HOOK_BAK=""
    return 1
  fi
  return 0
}

guard_uninstall() {
  [ -z "$HOOK_PATH" ] && return 0
  # 只删我们自己装的（R8 #10 同源）: 夜里用户手动换了 hook 的话不该被我们抹掉。
  if _hook_is_ours "$HOOK_PATH" "$HOOK_TOKEN"; then
    if ! rm -f "$HOOK_PATH"; then
      log "⚠️ 无法移除夜班 hook: ${HOOK_PATH}（保留恢复状态供重试）"
      return 1
    fi
  elif [ -e "$HOOK_PATH" ]; then
    log "⚠️ 当前 pre-push 不是夜班装的，保留不动；备份仍在 ${GUARD_HOOK_BAK:-（无）}"
    push "⚠️ 需要手动处理" "pre-push 已被外部改动，夜班未做覆盖"
    return 1
  fi
  if [ -n "$GUARD_HOOK_BAK" ] && [ -e "$GUARD_HOOK_BAK" ]; then
    if ! mv "$GUARD_HOOK_BAK" "$HOOK_PATH"; then
      log "⚠️ 原有 pre-push hook 恢复失败，备份保留在: $GUARD_HOOK_BAK"
      push "⚠️ 需要手动处理" "你的 pre-push hook 未能自动恢复，备份见日志"
      return 1     # 保留 GUARD_HOOK_BAK 与状态文件，供下次或人工恢复（Codex R4 #11）
    fi
  fi
  # 恢复成功才清状态——不清就是 R8 #6 那条「正常路径销毁用户 hook」的直接成因。
  _clear_hook_state
  GUARD_HOOK_BAK=""; HOOK_PATH=""; HOOK_TOKEN=""
  return 0
}

# <<<TESTABLE:hook<<<

# Resolve every repository-controlled metadata path while Git configuration is
# still trusted, then hash those paths with Node only. Verification after an AI
# process must not invoke Git before this check: a modified config could install
# a clean filter/fsmonitor command, and a modified hook could run at checkpoint.
_resolve_git_meta_paths() {
  local repo="$1" gd common hook_cfg hook_rc
  gd="$(git -C "$repo" rev-parse --git-dir 2>>"$RUNLOG")" || return 1
  common="$(git -C "$repo" rev-parse --git-common-dir 2>>"$RUNLOG")" || return 1
  case "$gd" in /*) : ;; *) gd="$repo/$gd" ;; esac
  case "$common" in /*) : ;; *) common="$repo/$common" ;; esac
  gd="$(cd "$gd" 2>/dev/null && pwd -P)" || return 1
  common="$(cd "$common" 2>/dev/null && pwd -P)" || return 1

  hook_cfg="$(git -C "$repo" config --path --get core.hooksPath 2>>"$RUNLOG")"
  hook_rc=$?
  if [ "$hook_rc" -eq 1 ]; then
    hook_cfg="$common/hooks"
  elif [ "$hook_rc" -ne 0 ]; then
    log "护栏: 无法解析 core.hooksPath"
    return 1
  elif [ -z "$hook_cfg" ]; then
    hook_cfg="$common/hooks"
  else
    case "$hook_cfg" in /*) : ;; *) hook_cfg="$repo/$hook_cfg" ;; esac
  fi

  GUARD_META_DOTGIT=""
  if [ -f "$repo/.git" ] || [ -L "$repo/.git" ]; then GUARD_META_DOTGIT="$repo/.git"; fi
  GUARD_META_GITDIR="$gd"
  GUARD_META_COMMON="$common"
  GUARD_META_HOOKS="$hook_cfg"
  return 0
}

_git_meta_digest() {
  local raw
  raw="$(node "$CLI" path-content-snapshot \
    "$GUARD_META_DOTGIT" \
    "$GUARD_META_GITDIR/config" "$GUARD_META_GITDIR/config.worktree" \
    "$GUARD_META_GITDIR/info/attributes" "$GUARD_META_GITDIR/info/exclude" "$GUARD_META_GITDIR/info/sparse-checkout" "$GUARD_META_GITDIR/info/grafts" \
    "$GUARD_META_GITDIR/hooks" \
    "$GUARD_META_COMMON/config" "$GUARD_META_COMMON/config.worktree" \
    "$GUARD_META_COMMON/info/attributes" "$GUARD_META_COMMON/info/exclude" "$GUARD_META_COMMON/info/sparse-checkout" "$GUARD_META_COMMON/info/grafts" \
    "$GUARD_META_COMMON/hooks" \
    "$GUARD_META_COMMON/objects/info/alternates" "$GUARD_META_COMMON/objects/info/http-alternates" \
    "$GUARD_META_HOOKS" 2>>"$RUNLOG")" || return 1
  jq_get "$raw" digest
}

guard_git_meta_snapshot() {
  local repo="$1"
  _resolve_git_meta_paths "$repo" || {
    log "护栏快照失败: 无法解析 Git 元数据路径"
    return 1
  }
  GUARD_GIT_META="$(_git_meta_digest)" || {
    log "护栏快照失败: 无法摘要 Git 元数据"
    return 1
  }
  [ -n "$GUARD_GIT_META" ] || { log "护栏快照失败: Git 元数据摘要为空"; return 1; }
}

guard_git_meta_verify() {
  local repo="$1" now
  # Do not re-resolve paths with Git here. The baseline paths were captured
  # before AI execution; using a possibly modified config to choose what to
  # verify would let the modification move itself outside the check.
  now="$(_git_meta_digest)" || {
    GUARD_ABORT_REASON="护栏不可得"
    log "护栏核验失败: 无法摘要 Git 元数据"
    push "🚨 护栏核验失败" "无法核验 Git hooks/config，夜班已中止"
    return 1
  }
  if [ "$now" != "$GUARD_GIT_META" ]; then
    GUARD_ABORT_REASON="护栏违规"
    log "护栏违规: Git hooks/config/info 元数据发生变化"
    push "🚨 护栏违规" "检出 Git 元数据变化，夜班已中止"
    return 1
  fi
  return 0
}

# 列出受保护文件（已跟踪 **+ 未跟踪未忽略**——Codex R2 #5: 原实现只看已跟踪，
# 新增的合同/凭据类文件漏检）。失败返回非零，调用方失败关闭（Codex R2 #4）。
#
# 「什么算受保护」**只有一处定义**: lib/guardrails.mjs 的 isProtectedPath，
# 经 `cli.mjs protected-in-null` 调用。本函数只负责枚举候选与摘要内容，不做任何模式判断。
# >>>TESTABLE:prot-hash>>>  （test/prot-hash.test.sh 按这对标记抽取，勿删）
PROT_MAX_ENTRIES=500000        # 总候选条目上限（20 万实测 0.33s，留足余量）
PROT_MAX_DIR_ENTRIES=20000     # 单个受保护链接所指目录的展开上限（含递归后代）

# 摘要一个**仓库内目录**的全部内容，跟随其中的目录链接（Codex R10 #2）。
#
# R9 那版只做一层 `find -print0 | shasum`，遇到目录内的嵌套目录链接时 shasum 失败，
# 被我的 `|| printf 'UNREADABLE %s'` 兜底成一个**恒定值**——于是
# `.env.dir -> data`、`data/nested -> ../target` 时，改 `target/plain.txt` 摘要纹丝不动。
# 已实测复现。兜底成常量比不摘要更糟: 它让漏检看起来像已覆盖。
#
# $1=绝对目录 $2=real_repo $3=visited 文件（防环） $4=计数文件（有界）
# 任何读取失败一律 return 1（失败关闭），绝不用常量占位。
_dir_digest() {
  local d="$1" real_repo="$2" vis="$3" cnt="$4" out="" e rp n lst sub one id dmode tmode
  local modesf entries_n modes_n emode extra_mode entry_sum entry_key link_text link_sum link_key sub_sum sub_key
  # ⚠️ visited 身份用 **dev:inode**，不用路径（Codex R11 #3）:
  #    路径写进按行分隔的文件，含换行的目录名会裂成多条——比如某个链接指向 `z\nfoo`，
  #    留下的 `/repo/z` 那行会让后来真实的 `/repo/z` 目录被误判成环而整个跳过，
  #    改它底下的文件护栏毫无反应。这是 R9 #3 那个「行协议」缺陷在我新写的代码里复发。
  #    dev:inode 天然无换行，还能识破硬链接与经不同路径到达的同一目录（实测 a 与 alink/ 同号）。
  id="$(stat -f '%d:%i' "$d" 2>>"$RUNLOG")" \
    || { log "护栏: stat 目录身份失败: ${d}"; return 1; }
  dmode="$(stat -f '%p' "$d" 2>>"$RUNLOG")" \
    || { log "护栏: stat 目录权限失败: ${d}"; return 1; }
  out="${out}DIRMODE ${id} ${dmode}"$'\n'
  [ -n "$id" ] || return 1
  grep -qxF -- "$id" "$vis" 2>/dev/null && { printf 'CYCLE %s\n' "$id"; return 0; }
  printf '%s\n' "$id" >>"$vis" || return 1
  lst="$(mktemp)" || return 1
  # A protected symlink may resolve to the repository root. The adapter-owned
  # .review tree and Git's own mutable metadata remain excluded there exactly
  # as they are in the top-level task baseline and checkpoint pathspecs.
  if [ "$d" = "$real_repo" ]; then
    find "$d" -mindepth 1 -maxdepth 1 ! -name .review ! -name .git -print0 2>>"$RUNLOG" \
      | LC_ALL=C sort -z >"$lst" \
      || { log "护栏: 枚举受保护目录失败: ${d}"; rm -f "$lst"; return 1; }
  else
    find "$d" -mindepth 1 -maxdepth 1 -print0 2>>"$RUNLOG" \
      | LC_ALL=C sort -z >"$lst" \
      || { log "护栏: 枚举受保护目录失败: ${d}"; rm -f "$lst"; return 1; }
  fi
  # Mode metadata is part of the protected snapshot. Keep it in a parallel
  # newline-safe stream (modes contain no newlines); paths remain NUL-framed and
  # are represented below only by fixed-length SHA-256 keys.
  modesf="$(mktemp)" || { rm -f "$lst"; return 1; }
  if [ -s "$lst" ]; then
    xargs -0 stat -f '%p' <"$lst" >"$modesf" 2>>"$RUNLOG" \
      || { log "护栏: 批量读取目录条目权限失败: ${d}"; rm -f "$lst" "$modesf"; return 1; }
  fi
  entries_n="$(tr -dc '\0' <"$lst" | wc -c | tr -d ' ')" \
    || { rm -f "$lst" "$modesf"; return 1; }
  modes_n="$(wc -l <"$modesf" | tr -d ' ')" \
    || { rm -f "$lst" "$modesf"; return 1; }
  [ "$entries_n" = "$modes_n" ] || { rm -f "$lst" "$modesf"; return 1; }
  exec 7<"$modesf" || { rm -f "$lst" "$modesf"; return 1; }
  while IFS= read -r -d '' e; do
    IFS= read -r emode <&7 || { exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
    entry_sum="$(printf '%s' "$e" | shasum -a 256)" \
      || { exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
    entry_key="${entry_sum%% *}"
    out="${out}ENTRY ${entry_key} ${emode}"$'\n'
    n="$(cat "$cnt" 2>/dev/null)" || { exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
    n=$((n + 1)); printf '%s\n' "$n" >"$cnt"
    [ $((n % 20)) -eq 0 ] && beat
    if [ "$n" -gt "$PROT_MAX_DIR_ENTRIES" ]; then
      log "护栏: 受保护目录展开超过 ${PROT_MAX_DIR_ENTRIES} 条，失败关闭"
      exec 7<&-; rm -f "$lst" "$modesf"; return 1
    fi
    if [ -L "$e" ]; then
      link_text="$(readlink "$e" 2>>"$RUNLOG")" \
        || { log "护栏: readlink 失败: ${e}"; exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
      link_sum="$(printf '%s' "$link_text" | shasum -a 256)" \
        || { exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
      link_key="${link_sum%% *}"
      out="${out}LINK ${entry_key} ${link_key}"$'\n'
      if rp="$(realpath "$e" 2>/dev/null)"; then
        case "$rp" in
          "$real_repo"|"$real_repo"/*)
            if [ -d "$rp" ]; then
              sub="$(_dir_digest "$rp" "$real_repo" "$vis" "$cnt")" \
                || { log "护栏: 摘要链接目录失败: ${rp}"; exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
              sub_sum="$(printf '%s' "$sub" | shasum -a 256)" \
                || { exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
              sub_key="${sub_sum%% *}"
              out="${out}SUBDIR ${entry_key} ${sub_key}"$'\n'
            elif [ -f "$rp" ]; then
              tmode="$(stat -f '%p' "$rp" 2>>"$RUNLOG")" \
                || { log "护栏: stat 链接目标失败: ${rp}"; exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
              one="$(shasum -a 256 <"$rp" 2>>"$RUNLOG")" \
                || { log "护栏: 哈希链接目标失败: ${rp}"; exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
              out="${out}TARGETFILE ${entry_key} ${tmode} ${one%% *}"$'\n'
            else
              out="${out}NOT-A-REGULAR-FILE ${entry_key}"$'\n'
            fi ;;
          *) out="${out}OUTSIDE-REPO ${entry_key}"$'\n' ;;
        esac
      else
        out="${out}UNRESOLVABLE ${entry_key}"$'\n'
      fi
    elif [ -d "$e" ]; then
      sub="$(_dir_digest "$e" "$real_repo" "$vis" "$cnt")" \
        || { log "护栏: 摘要子目录失败: ${e}"; exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
      sub_sum="$(printf '%s' "$sub" | shasum -a 256)" \
        || { exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
      sub_key="${sub_sum%% *}"
      out="${out}SUBDIR ${entry_key} ${sub_key}"$'\n'
    elif [ -f "$e" ]; then
      one="$(shasum -a 256 <"$e" 2>>"$RUNLOG")" \
        || { log "护栏: 哈希目录文件失败: ${e}"; exec 7<&-; rm -f "$lst" "$modesf"; return 1; }
      out="${out}FILE ${entry_key} ${one%% *}"$'\n'
    else
      out="${out}SPECIAL ${entry_key}"$'\n'
    fi
  done <"$lst"
  if IFS= read -r extra_mode <&7; then
    exec 7<&-; rm -f "$lst" "$modesf"; return 1
  fi
  exec 7<&-
  rm -f "$lst" "$modesf"
  printf '%s' "$out"
}
# realpath 缺失（旧版 macOS）时每个受保护链接都会稳定落到 UNRESOLVABLE，而函数照样返回成功——
# 摘要从此对链接目标的任何变化都无反应，**且没有任何信号**（Codex R9 #5）。
# 依赖缺失必须在开工前拒绝，不能退化成一个静默失效的护栏。
require_realpath() {
  command -v realpath >/dev/null 2>&1 && return 0
  log "⚠️ 系统缺少 realpath，受保护符号链接无法解析——拒绝开工"
  push "⚠️ 夜班无法开工" "系统缺少 realpath 命令，护栏不完整"
  return 1
}
_prot_hash() {
  local repo="$1" lst exp h=""
  lst="$(mktemp)" || return 1
  exp="$(mktemp)" || { rm -f "$lst"; return 1; }
  # 三条枚举各自检查退出码（Codex R5 #4）: 合在一个 {} 里只有整体失败才捕获，
  # 其中一条静默失败会让那一类文件整体从受保护快照中消失。
  # .review is the review adapter's allowed output namespace. Exclude it from
  # the protected snapshot just as baseline checks and checkpoint commits do;
  # otherwise a finding filename containing "contract" can trip the guard.
  git -C "$repo" ls-files -z -- . ':(exclude).review' >"$lst" 2>>"$RUNLOG" \
    || { log "护栏: git ls-files tracked 失败: ${repo}"; rm -f "$lst" "$exp"; return 1; }
  git -C "$repo" ls-files -z --others --exclude-standard -- . ':(exclude).review' >>"$lst" 2>>"$RUNLOG" \
    || { log "护栏: git ls-files untracked 失败: ${repo}"; rm -f "$lst" "$exp"; return 1; }
  # ignored 用 --directory 折叠（性能: 不展开 node_modules 的十万个文件）
  git -C "$repo" ls-files -z --others --ignored --exclude-standard --directory -- . ':(exclude).review' >>"$lst" 2>>"$RUNLOG" \
    || { log "护栏: git ls-files ignored 失败: ${repo}"; rm -f "$lst" "$exp"; return 1; }

  # ── 展开被折叠的 ignored 目录，**不做任何 shell 层模式预筛**（Codex R8 #3）──
  #
  # R7 为了性能加了一套 `-name` 预筛，等于把「什么算受保护」写了第二遍。
  # 它在写下的那一刻就与 lib/guardrails.mjs 的权威判定发散了四处:
  #   · CJK 法务词（合同/契約/法律）预筛里完全没有
  #   · 正则匹配整条路径含目录段，预筛的 -iname 只作用于 -type f/-l → `archive/legal/x.txt` 漏
  #   · -type d 只列了 .ssh/.aws/.gnupg/.kube 四个固定名
  #   · `service[-_]?account` 的分隔符可选，而 `-name 'service?account*'` 的 ? 必须占一位
  # 实测: 5 份权威判定为受保护的文件，只有 1 份进了摘要，改其余 4 份护栏毫无反应。
  #
  # R7 #2 的真实成因**不是耗时**，是那个 20000 的单目录硬上限失败关闭。实测代价:
  #   20 万文件 find 全展开 0.20s + 20 万条过 protected-in-null 0.05s，整函数 0.33s。
  # 全展开不构成性能问题，所以正解是**删掉第二处模式集**，而不是给它补四条模式。
  # ⚠️ 整条管线必须是 **NUL 分隔**（Codex R9 #3，已实测）: git 允许文件名含换行，
  #    原来 `tr '\0' '\n'` 一上来就把 NUL 换成换行，`legal\nnotes.txt` 被拆成两条，
  #    权威判定看到的是并不存在的 `legal`，真实文件从头到尾没进过摘要——改它护栏毫无反应。
  #    所以: ls-files -z → find -print0 → protected-in-null → read -d ''，全程不落行协议。
  # ⚠️ 初始化与每一次追加都要检查（Codex R20 #1 报的是 `plain`，我复现时发现 `exp`
  #    上有同一个缺陷、而且从 R8 起就在）: 磁盘满/配额/只读时这些写入静默失败，
  #    随后的计数是从**这个空文件**算出来的——自洽但错误，结果是
  #    「退出码 0、stdout 零字节」的静默漏检（正常应为 185 字节）。实测复现过。
  : >"$exp" || { log "护栏: 无法初始化枚举列表（磁盘/配额？）"; rm -f "$lst" "$exp"; return 1; }
  local e exp_n=0 one k enum_i=0
  while IFS= read -r -d '' e; do
    [ -z "$e" ] && continue
    enum_i=$((enum_i + 1))
    [ $((enum_i % 20)) -eq 0 ] && beat
    if [ -d "$repo/$e" ]; then
      one="$(mktemp)" || { rm -f "$lst" "$exp"; return 1; }
      (cd "$repo" && find "$e" \( -type f -o -type l \) -print0 2>>"$RUNLOG" | LC_ALL=C sort -z) >"$one"
      local find_rc=$?
      if [ "$find_rc" -ne 0 ]; then
        log "护栏: 展开被忽略目录失败: ${repo}/${e}"; rm -f "$one" "$lst" "$exp"; return 1
      fi
      k="$(tr -dc '\0' <"$one" | wc -c | tr -d ' ')" \
        || { rm -f "$one" "$lst" "$exp"; return 1; }
      cat "$one" >>"$exp" \
        || { log "护栏: 写入目录展开列表失败"; rm -f "$one" "$lst" "$exp"; return 1; }
      rm -f "$one"
      exp_n=$((exp_n + k))
    else
      printf '%s\0' "$e" >>"$exp" || { log "护栏: 写入枚举列表失败"; rm -f "$lst" "$exp"; return 1; }
      exp_n=$((exp_n + 1))
    fi
  done <"$lst"
  rm -f "$lst"

  # 有界（Codex R6 #6，R7 重写时被删掉却留着注释——R8 #5 指出）。
  # 上限落在**总条目数**而非单目录: 单目录上限正是 R7 #2 里 node_modules 卡死整夜的成因。
  # 用 NUL 计数，不能再用 wc -l（含换行的文件名会被多算）。
  local n; n="$(tr -dc '\0' <"$exp" | wc -c | tr -d ' ')" || { rm -f "$exp"; return 1; }
  # 交叉校验: 文件里的条数必须等于我们**打算写入**的条数。写失败已在上面拦住，
  # 这一条是兜底——自己数自己永远相符，必须锚在独立的计数器上。
  if [ "$n" != "$exp_n" ]; then
    log "护栏: 枚举列表条数不符（打算 ${exp_n} 实得 ${n}），失败关闭"
    rm -f "$exp"; return 1
  fi
  if [ "$n" -gt "$PROT_MAX_ENTRIES" ]; then
    log "护栏: 待检条目 ${n} 超过上限 ${PROT_MAX_ENTRIES}，失败关闭（绝不静默少查）"
    rm -f "$exp"; return 1
  fi

  local pf; pf="$(mktemp)" || return 1
  # Keep original filename bytes all the way through selection and output.
  # JSON strings cannot represent a non-UTF-8 POSIX filename losslessly.
  node "$CLI" protected-in-null "$exp" "$pf" >/dev/null 2>>"$RUNLOG" \
    || { log "护栏: protected-in 权威判定失败: ${repo}"; rm -f "$exp" "$pf"; return 1; }
  rm -f "$exp"

  # 可选: 把解析后的受保护清单导出给调用方（备份用）。NUL 分隔。
  if [ -n "${PROT_LIST_OUT:-}" ] && ! cp "$pf" "$PROT_LIST_OUT" 2>>"$RUNLOG"; then
    # The content guard itself remains valid, so do not turn a recovery-copy
    # failure into a guard false positive. It must still be loud: every
    # untracked protected file will lack a restorable pre-change copy.
    log "⚠️ 无法导出受保护清单，本次不做未跟踪凭据备份"
    push "⚠️ 部分受保护文件无备份" "受保护清单导出失败；护栏报警时这些文件无副本可还原"
  fi
  local real_repo; real_repo="$(cd "$repo" && pwd -P)" \
    || { log "护栏: 仓库规范化失败: ${repo}"; return 1; }
  local plain plain_n=0
  plain="$(mktemp)" || return 1
  : >"$plain" || { rm -f "$plain"; return 1; }
  local f prot_i=0 fmode tmode fsum fkey lsum lkey
  while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    prot_i=$((prot_i + 1))
    [ $((prot_i % 20)) -eq 0 ] && beat
    if [ -L "$repo/$f" ]; then
      # 链接文本入摘要（R6 #5: 改指向即可绕过内容哈希）**并且**摘要它所指的内容
      # （R7 #3: `tmpstuff/.env -> payload` 时改 payload 不改链接文本，凭据修改绕过护栏）。
      local lt; lt="$(readlink "$repo/$f" 2>>"$RUNLOG")" \
        || { log "护栏: readlink 失败: ${repo}/${f}"; return 1; }
      fsum="$(printf '%s' "$f" | shasum -a 256 2>>"$RUNLOG")" \
        || { log "护栏: 哈希受保护路径名失败"; return 1; }
      fkey="${fsum%% *}"
      lsum="$(printf '%s' "$lt" | shasum -a 256 2>>"$RUNLOG")" \
        || { log "护栏: 哈希链接文本失败: ${repo}/${f}"; return 1; }
      lkey="${lsum%% *}"
      fmode="$(stat -f '%p' "$repo/$f" 2>>"$RUNLOG")" \
        || { log "护栏: stat 受保护链接失败: ${repo}/${f}"; return 1; }
      h="${h}LINKMODE ${fmode} ${fkey}"$'\n'
      h="${h}LINK ${lkey} ${fkey}"$'\n'
      # ⚠️ R7 那版自己拼路径: dirname(链接自身) + basename(链接文本)——**把链接文本里的
      #    目录部分丢了**。`tmp/.env -> ../data/blob.txt` 被解析成 `tmp/blob.txt`（不存在），
      #    于是连 TARGET 行都不产生，改 data/blob.txt 完全无感知（R8 #4，已实测）。
      #    R7 的复现用例恰好是同目录裸文件名，是唯一能工作的形态。
      #    这里改用 realpath 一次解析到底: 链条、`..`、绝对路径都对，悬空与成环返回非零。
      #    包含检查用带引号的 "$real_repo"——bash 把引号内视作字面量，仓库路径含 [ * ? 也不会误判。
      local real_tgt
      if real_tgt="$(realpath "$repo/$f" 2>/dev/null)"; then
        # ⚠️ `"$real_repo"` 本身也要算「仓库内」（Codex R9 #4，已实测）:
        #    `tmp/.env.dir -> ..` 时 real_tgt 恰好等于 real_repo，只匹配 "$real_repo"/* 的话
        #    会被记成 OUTSIDE-REPO，于是改仓库根下的文件完全无痕迹。
        case "$real_tgt" in
          "$real_repo"|"$real_repo"/*)
            if [ -f "$real_tgt" ]; then
              tmode="$(stat -f '%p' "$real_tgt" 2>>"$RUNLOG")" \
                || { log "护栏: stat 链接目标失败: ${real_tgt}"; return 1; }
              h="${h}TARGETMODE ${fkey} ${tmode}"$'\n'
              local tc; tc="$(shasum -a 256 <"$real_tgt" 2>>"$RUNLOG")" \
                || { log "护栏: 哈希链接目标失败: ${real_tgt}"; return 1; }
              h="${h}TARGET ${fkey} ${tc%% *}"$'\n'
            elif [ -d "$real_tgt" ]; then
              # 指向目录时也要摘要目录内容（R8 #4），且必须**递归跟随内部的目录链接**
              # （R10 #2）——否则 `.env.dir -> data`、`data/nested -> ../target` 时
              # 改 target/ 里的文件毫无痕迹。_dir_digest 带 visited 防环、计数有界、
              # 任何读取失败即失败关闭（不再用 UNREADABLE 常量占位）。
              local vf cf dtc
              vf="$(mktemp)" || return 1
              cf="$(mktemp)" || { rm -f "$vf"; return 1; }
              printf '0\n' >"$cf"
              dtc="$(_dir_digest "$real_tgt" "$real_repo" "$vf" "$cf")" \
                || { log "护栏: 摘要受保护链接目录失败: ${real_tgt}"; rm -f "$vf" "$cf"; return 1; }
              local dn; dn="$(cat "$cf" 2>/dev/null)" || dn="?"
              rm -f "$vf" "$cf"
              dtc="$(printf '%s' "$dtc" | shasum -a 256)" || return 1
              h="${h}TARGETDIR ${fkey} ${dn} ${dtc}"$'\n'
            else
              h="${h}TARGET ${fkey} NOT-A-REGULAR-FILE"$'\n'
            fi ;;
          *) h="${h}TARGET ${fkey} OUTSIDE-REPO"$'\n' ;;
        esac
      else
        # 悬空 / 成环: **记录状态**而不是静默跳过——夜里它变成有效文件时摘要必须变化
        h="${h}TARGET ${fkey} UNRESOLVABLE"$'\n'
      fi
    elif [ -f "$repo/$f" ]; then
      # 普通文件攒起来批量哈希（见下）——逐个 shasum 是进程创建开销，实测 1 万个文件
      # 要 81 秒，批量只要 0.27 秒（R19 自查，300 倍）。
      # ⚠️ 追加必须检查（Codex R20 #1，他复现了）: 磁盘满/配额/IO 错误时追加失败，
      #    而下面的 `want` 又是从**这个已被截断的文件**算出来的——两个数字自洽，
      #    校验形同虚设，结果是「退出码 0、零哈希字节」的静默漏检。
      #    自洽的校验不等于正确的校验: 计数必须锚在**打算写入的条数**上。
      printf '%s\0' "$repo/$f" >>"$plain" || { log "护栏: 写入哈希输入失败（磁盘/配额？）"; rm -f "$plain"; return 1; }
      plain_n=$((plain_n + 1))
    elif [ ! -e "$repo/$f" ]; then
      # A tracked path remains in `git ls-files` after deletion. Record the
      # missing state in the digest so snapshot-vs-verify classifies it as an
      # actual protected-path change, not as unavailable guard telemetry.
      fsum="$(printf '%s' "$f" | shasum -a 256 2>>"$RUNLOG")" \
        || { log "护栏: 哈希缺失受保护路径名失败"; rm -f "$pf" "$plain"; return 1; }
      fkey="${fsum%% *}"
      log "护栏: 受保护路径缺失: ${repo}/${f}"
      h="${h}MISSING ${fkey}"$'\n'
    else
      # The selector received this byte-exact path from the just-built
      # enumeration. Silently skipping it would make snapshot and verify agree
      # on an incomplete protected set (notably after filename transcoding).
      log "护栏: 受保护清单条目既非普通文件也非链接，失败关闭: ${repo}/${f}"
      rm -f "$pf" "$plain"
      return 1
    fi
  done <"$pf"
  rm -f "$pf"
  # ⚠️ 批量哈希（R19 自查）: R10 我为了「避免 xargs 分批影响结果」改成逐个 shasum，
  #    **没测过代价**。分批的顺序问题用 `sort` 就解决了，而逐个哈希的代价是每文件一次
  #    进程创建——一个 contracts/ 放了 1 万份文件的仓库，每次 guard_snapshot 要 81 秒，
  #    而 snapshot 与 verify 每个任务各跑一次。
  #    xargs 任一批失败返回 123/124/125，`|| return 1` 即失败关闭，不会静默少查。
  if [ -s "$plain" ]; then
    local bulk bulk_rc mode_json mode_n mode_digest
    bulk="$(xargs -0 shasum -a 256 <"$plain" 2>>"$RUNLOG" | LC_ALL=C sort)"
    bulk_rc=$?
    [ "$bulk_rc" -eq 0 ] \
      || { log "护栏: 批量哈希受保护文件失败: ${repo}"; rm -f "$plain"; return 1; }
    mode_json="$(node "$CLI" mode-list-snapshot "$plain" 2>>"$RUNLOG")" \
      || { log "护栏: 批量读取受保护文件权限失败: ${repo}"; rm -f "$plain"; return 1; }
    mode_n="$(jq_get "$mode_json" count)" \
      || { log "护栏: 权限快照条数不可得"; rm -f "$plain"; return 1; }
    mode_digest="$(jq_get "$mode_json" digest)" \
      || { log "护栏: 权限快照摘要不可得"; rm -f "$plain"; return 1; }
    # 条数必须对得上，否则说明有文件被跳过（xargs 遇错会继续处理其余批次）
    # want 取自**计数器**而非文件——文件被截断时它自己数自己永远相符（R20 #1）
    local want got
    want="$plain_n"
    got="$(printf '%s\n' "$bulk" | grep -c . )" || got=0
    if [ "$want" != "$got" ]; then
      log "护栏: 批量哈希条数不符（期望 ${want} 实得 ${got}），失败关闭"
      rm -f "$plain"; return 1
    fi
    if [ "$want" != "$mode_n" ]; then
      log "护栏: 权限快照条数不符（期望 ${want} 实得 ${mode_n}），失败关闭"
      rm -f "$plain"; return 1
    fi
    h="${h}MODESET ${mode_n} ${mode_digest}"$'\n'"${bulk}"$'\n'
  fi
  rm -f "$plain"
  printf '%s' "$h"
}

# <<<TESTABLE:prot-hash<<<

# 备份受保护文件里**未被 git 跟踪**的那些（Codex R11 收尾 / 自查 T-4）。
#
# 为什么只备份未跟踪的: 已跟踪文件由收尾的 git checkpoint 兜底，能从 git 还原；
# 而被 gitignore 的凭据（典型如 .env）git 里根本没有——护栏能**检出**它被改，
# 却**无法还原**。sleep-well 在改文件前会 backupFile，本技能把 backup.mjs 复制了过来
# 却一直没有接线，等于静默丢了这项恢复能力，而早报里还挂着一节永远为空的「已备份的文件」。
#
# 有界: 单个文件超过 PROT_BACKUP_MAX_BYTES 就跳过并记日志（合同 PDF 可能很大，
# 但每晚复制一遍大文件不值得）；备份失败**不阻塞开工**——它是恢复能力，不是门禁，
# 门禁是 GUARD_PROT 比对。
PROT_BACKUP_MAX_BYTES="${SLEEP_WELL_BACKUP_MAX_BYTES:-10485760}"
# 备份单个绝对路径。已跟踪→跳过（git 兜底）；超限→跳过并记日志；失败→记日志。
# 返回 0 表示确实产生了备份（调用方据此计数——之前 cli 失败时 exit 0，计数是假的）。
_backup_one() {
  local repo="$1" abs="$2" root="$3" day="$4" rel="$5" sz
  case "$rel" in
    ''|/*|..|../*) log "⚠️ 备份路径无法映射到仓库内相对路径: ${abs}"; return 1 ;;
  esac
  # `rel` is a filename, not a pathspec. Without literal magic, a name such as
  # `*.pem` can match an unrelated tracked PEM and be mistaken for tracked.
  git -C "$repo" ls-files --error-unmatch -- ":(literal)$rel" >/dev/null 2>&1 && return 1
  sz="$(stat -f '%z' "$abs" 2>/dev/null)" || return 1
  if [ "$sz" -gt "$PROT_BACKUP_MAX_BYTES" ]; then
    # 超限要让用户知道（R15 #6: 文档已声称会告警而这支原来只 log），但**推送要聚合**
    # （Codex R16 #4）: 一个仓库里多个超限文件会逐个 push，每次最多等 10 秒——
    # N 个文件就是 N×10 秒，既刷屏又可能在开工前就撞上看门狗阈值。
    # 逐个记日志（诊断要精确），计数交给调用方在快照结束时推一条。
    log "备份跳过（${sz} 字节超过上限 ${PROT_BACKUP_MAX_BYTES}）: ${rel}"
    BACKUP_SKIPPED_N=$((BACKUP_SKIPPED_N + 1))
    return 1
  fi
  # ⚠️ `backupFile` 对同日已存在的备份返回 `skipped:true` 且**成功退出**（Codex R13 #6）。
  #    原来丢掉输出只看退出码，于是一夜十个任务就报十次「已备份 N 份」，
  #    而实际新副本只有第一次那一份——日志会让你以为每个任务都留了快照。
  # ⚠️ 失败告警必须可达（Codex R14 #5）: 上一版写成 `|| return 1` 直接返回，
  #    后面那句 log 成了死代码——备份失败时用户什么也不知道，还以为有副本可还原。
  local outj
  if ! outj="$(node "$CLI" backup-file "$abs" "$root" "$day" "guard-snapshot" 2>/dev/null)"; then
    log "⚠️ 备份失败（不阻塞开工，但护栏报警时将无副本可还原）: ${rel}"
    BACKUP_FAILED_N=$((BACKUP_FAILED_N + 1))
    return 1
  fi
  case "$outj" in
    *'"skipped":true'*) return 1 ;;    # 幂等跳过: 不算新增，也不是失败
  esac
  return 0
}
BACKUP_SKIPPED_N=0
BACKUP_FAILED_N=0
_backup_untracked_protected() {
  local repo="$1" listf="$2" p sz n=0 scan_n=0
  BACKUP_SKIPPED_N=0; BACKUP_FAILED_N=0
  local root="$SW_RUNTIME_HOME/backups" day; day="$(date '+%Y-%m-%d')"
  # 上限值本身要校验（Codex R12 #9）: 非数值时整数比较失败、超大文件反而照备；
  # 负值则每个文件都跳过。两种都让「有界」这个承诺落空且无人知晓。
  if PROT_BACKUP_MAX_BYTES="$(normalize_decimal "$PROT_BACKUP_MAX_BYTES")" \
     && [ "${#PROT_BACKUP_MAX_BYTES}" -le 18 ]; then
    :
  else
    log "⚠️ SLEEP_WELL_BACKUP_MAX_BYTES 非法，回落 10485760"
    PROT_BACKUP_MAX_BYTES=10485760
  fi
  [ "$PROT_BACKUP_MAX_BYTES" -lt 1024 ] && PROT_BACKUP_MAX_BYTES=1024

  local tgt real_repo rel
  real_repo="$(cd "$repo" && pwd -P)" || return 0
  while IFS= read -r -d '' p; do
    [ -z "$p" ] && continue
    scan_n=$((scan_n + 1))
    [ $((scan_n % 20)) -eq 0 ] && beat
    if [ -L "$repo/$p" ]; then
      # ⚠️ 不能一律跳过链接（Codex R12 #3）: `.env -> config/runtime` 时护栏会跟随并
      #    保护 target，但 target 自身的路径不受保护、也进不了这个清单——
      #    于是 Codex 通过链接写入时，护栏检出了改动却**没有任何副本可还原**，
      #    正好是这次接线要解决的那个问题换了条路径。改为备份**解析后的仓库内目标**。
      tgt="$(realpath "$repo/$p" 2>/dev/null)" || continue
      case "$tgt" in "$real_repo"|"$real_repo"/*) : ;; *) continue ;; esac   # 仓库外不碰
      [ -f "$tgt" ] || continue
      rel="${tgt#"$real_repo"/}"
      _backup_one "$repo" "$repo/$rel" "$root" "$day" "$rel" && n=$((n+1))
      continue
    fi
    [ -f "$repo/$p" ] || continue
    _backup_one "$repo" "$repo/$p" "$root" "$day" "$p" && n=$((n+1))
  done <"$listf"
  [ "$n" -gt 0 ] && log "已备份 ${n} 份未跟踪的受保护文件"
  # 聚合成一条推送（Codex R16 #4）: 逐文件 push 会 N×10 秒 + 刷屏。
  if [ "$BACKUP_FAILED_N" -gt 0 ] || [ "$BACKUP_SKIPPED_N" -gt 0 ]; then
    push "⚠️ 部分受保护文件无备份" \
         "失败 ${BACKUP_FAILED_N} 份、超限跳过 ${BACKUP_SKIPPED_N} 份；护栏报警时这些文件无副本可还原（明细见日志）"
  fi
  return 0
}

guard_branch_identity() {
  local repo="$1" current
  current="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>>"$RUNLOG")" && {
    printf '%s' "$current"
    return 0
  }
  current="$(git -C "$repo" rev-parse --verify HEAD 2>>"$RUNLOG")" || return 1
  printf '%s' "$current"
}

guard_snapshot() {
  local repo="$1"
  GUARD_ABORT_REASON="护栏不可得"
  beat
  GUARD_HEAD="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || { log "护栏快照失败: rev-parse"; return 1; }
  # 所有本地分支的位置——squash/ff merge 不产生提交，但会动 ref 或暂存区
  GUARD_REFS="$(git -C "$repo" for-each-ref refs/heads 2>/dev/null)" || { log "护栏快照失败: for-each-ref"; return 1; }
  guard_git_meta_snapshot "$repo" || return 1
  local plist; plist="$(mktemp)" || { log "护栏快照失败: mktemp"; return 1; }
  GUARD_PROT="$(PROT_LIST_OUT="$plist" _prot_hash "$repo")" || {
    rm -f "$plist"; log "护栏快照失败: 受保护路径哈希"; return 1; }
  beat
  _backup_untracked_protected "$repo" "$plist"
  beat
  rm -f "$plist"
  return 0
}

guard_verify() {
  local repo="$1"
  GUARD_ABORT_REASON="护栏不可得"
  # Must be the first verification step: every later Git command may honor
  # repository config, fsmonitor or hooks that an AI process tried to install.
  guard_git_meta_verify "$repo" || return 1
  # ① Codex 回合内不得有新提交（覆盖普通 merge 与野生 commit）
  # rev-list 失败（坏 sha、仓库损坏）会让 wc -l 得到 0 → 被当成「没有新提交」而放行。
  # 必须先判命令本身成功（Codex R3 #6）。
  local rl; rl="$(git -C "$repo" rev-list "${GUARD_HEAD}..HEAD" 2>>"$RUNLOG")" || {
    log "护栏核验失败: rev-list 出错"; push "🚨 护栏核验失败" "无法核验提交，夜班已中止"; return 1; }
  local n; n="$(printf '%s' "$rl" | grep -c . || true)"
  if [ "${n:-0}" -gt 0 ]; then
    GUARD_ABORT_REASON="护栏违规"
    log "护栏违规: Codex 回合内出现 ${n} 个新提交"; push "🚨 护栏违规" "检出未授权提交，夜班已中止"; return 1
  fi
  # ② squash / ff merge 不产生提交（Codex R2 #3，我已复现: --squash 后新提交数为 0
  #    而暂存区已被改，编排器随后的 add -A 会把 merge 内容当成任务产出提交）。
  #    靠三个残留标记 + 本地 ref 位置比对来抓。
  local gd; gd="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)" || { log "护栏核验失败: 无法解析 git-dir"; return 1; }
  case "$gd" in /*) : ;; *) gd="$repo/$gd" ;; esac
  for m in SQUASH_MSG MERGE_HEAD MERGE_MSG; do
    if [ -e "$gd/$m" ]; then
      GUARD_ABORT_REASON="护栏违规"
      log "护栏违规: 检出 .git/${m}（squash 或未完成的 merge）"
      push "🚨 护栏违规" "检出 merge 痕迹，夜班已中止"; return 1
    fi
  done
  local br_now; br_now="$(guard_branch_identity "$repo")" || {
    log "护栏核验失败: 无法核验当前分支"
    push "🚨 护栏核验失败" "无法核验当前分支，夜班已中止"
    return 1
  }
  if [ "$br_now" != "$GUARD_BRANCH" ]; then
    GUARD_ABORT_REASON="护栏违规"
    log "护栏违规: 当前分支由 ${GUARD_BRANCH} 变为 ${br_now}"
    push "🚨 护栏违规" "检出分支切换，夜班已中止"; return 1
  fi
  # ⚠️ 退出码不能忽略（Codex R18 #1）: 命令失败时 refs_now 为空，若快照也为空
  #    （detached HEAD 且无本地分支）两者相等 → **放行**。核验命令自身失败属于
  #    「核验不可得」，必须与「未检出违规」区分开——这是整个护栏失败关闭契约的前提。
  local refs_now
  refs_now="$(git -C "$repo" for-each-ref refs/heads 2>>"$RUNLOG")" || {
    log "护栏核验失败: for-each-ref 出错"; push "🚨 护栏核验失败" "无法核验分支引用，夜班已中止"; return 1; }
  if [ "$refs_now" != "$GUARD_REFS" ]; then
    GUARD_ABORT_REASON="护栏违规"
    log "护栏违规: 本地分支引用发生变化（ff-merge / reset / 建删分支）"
    push "🚨 护栏违规" "检出分支引用变动，夜班已中止"; return 1
  fi
  # ③ 受保护路径内容
  local prot_now; prot_now="$(_prot_hash "$repo")" || { log "护栏核验失败: 受保护路径哈希不可得"; push "🚨 护栏核验失败" "无法核验受保护文件，夜班已中止"; return 1; }
  if [ "$prot_now" != "$GUARD_PROT" ]; then
    GUARD_ABORT_REASON="护栏违规"
    log "护栏违规: 受保护路径内容变化"; push "🚨 护栏违规" "受保护文件被修改，夜班已中止"; return 1
  fi
  return 0
}

# ── 跑一次 codex ──────────────────────────────────────────────────────
# 回显退出码；调用方必须 classify（Codex R1 #10: 修复轮原本完全不看返回码）
# 隔离的 CODEX_HOME（Codex R4 #1）: `-c mcp_servers={}` **实测无效**——加不加参数
# `codex mcp list` 输出完全相同。我上一轮只验证了参数「被接受」，没验证「起作用」。
# 有效做法是给夜班一个干净的 CODEX_HOME: 自带极简 config.toml、无任何 MCP/插件，
# auth.json 软链回真实 home 以保留登录。实测该 home 下 `codex mcp list` 输出
# 「No MCP servers configured yet」。
# 这很重要：已有用户配置可能启用了带凭据或外部写权限的 MCP；
# 无人值守时它们会扩大外带与外部副作用面。
SW_CODEX_HOME=""
prepare_codex_home() {
  SW_CODEX_HOME="$SW_RUNTIME_HOME/codex-home"
  mkdir -p "$SW_CODEX_HOME" || return 1
  cat >"$SW_CODEX_HOME/config.toml" <<'TOML'
# sleep-well-codex 专用的极简 Codex 配置——刻意不含任何 mcp_servers / plugins。
#
# ⚠️⚠️ web_search 必须留在**任何 [表头] 之前**。⚠️⚠️
# TOML 的表不会因空行回到根级: 写在 [sandbox_workspace_write] 之后就变成
# `sandbox_workspace_write.web_search`，成为一个谁都不读的死键。
# R7 就是这么错的——键名对、位置错，于是「已阻断」的说法整整两轮都是假的，
# 而 R8 我和 Codex 两边都拿着这份坏配置去做负测试，一起得出「关不掉」的错误结论（R9 #12 指出）。
#
# 原生工具（Responses API 侧）不走 shell，seatbelt 的 network_access=false 对它们无效，
# 只能靠这个键。2026-08-10 配对负测试（各跑两次，同一提示同一模型）:
#   键在 [sandbox_workspace_write] 下 → `web search:` 事件 2/2 次，拿到 example.com 真实 <h1>
#   键在顶层                          → 事件 0/2 次，模型回 BLOCKED
# 判据是**工具调用事件是否出现**，不是模型自陈（R9 #12）。
# 回归探针: bin/probe-native-web.sh，Codex 升级后重跑。
sandbox_mode = "workspace-write"
web_search = "disabled"

[sandbox_workspace_write]
network_access = false

[features]
# 以下开关的「生效状态」经 `codex features list` 确认确实翻成了 false。
# 但**生效状态不等于行为改变**——本项目已在这上面栽过四次。逐项交代验证深度:
#   image_generation —— 行为负测试通过（Codex R7 实测）
#   computer_use     —— **未能验证开关有效**: 负测试里 A/B 两种配置都返回 NO_COMPUTER_USE，
#                       即正对照失败，说明该工具在 `codex exec` 这个调用面上本来就不提供，
#                       与开关无关。对 exec 而言是好消息，但不能据此说「我们关掉了它」。
#   其余             —— 仅确认生效状态翻转，未做行为负测试。
# 全部保留是因为它们只会缩小能力面、不会扩大；但**不得据此对外声称已阻断**。
image_generation = false
browser_use = false
browser_use_external = false
browser_use_full_cdp_access = false
in_app_browser = false
computer_use = false
apps = false
plugins = false
remote_plugin = false
plugin_sharing = false
multi_agent = false
TOML
  if [ ! -r "$SW_USER_CODEX_HOME/auth.json" ]; then
    log "⚠️ 未找到可读的 Codex 登录态: ${SW_USER_CODEX_HOME}/auth.json"
    return 1
  fi
  ln -sfn "$SW_USER_CODEX_HOME/auth.json" "$SW_CODEX_HOME/auth.json" || return 1
  [ -r "$SW_CODEX_HOME/auth.json" ] || {
    log "⚠️ 隔离 CODEX_HOME 的登录态链接不可读，拒绝开工"
    return 1
  }
  # 自检: 确认该 home 下确实没有 MCP。**探测本身失败也要拒绝开工**（Codex R5 #7）——
  # 原写法只看 grep 结果，探测命令出错时输出为空，反而被当成「没有 MCP」放行。
  # ⚠️ 诊断必须说实话（2026-08-16 实测教训）: 这条原来无论什么原因失败都报
  #    「MCP 隔离自检执行失败」。真实情况是 `codex` 根本不在 PATH 里（127），
  #    而日志把人指向「MCP 未能清空」——整夜八小时的日志指错了方向。
  #    先分开判「命令在不在」与「输出对不对」。
  if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
    log "⚠️ 找不到 codex 可执行文件（PATH=${PATH}），拒绝开工"
    return 1
  fi
  local probe probe_rc
  probe="$(CODEX_HOME="$SW_CODEX_HOME" "$CODEX_BIN" mcp list 2>&1)"; probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    log "⚠️ codex mcp list 退出码 ${probe_rc}，拒绝开工: $(printf '%.200s' "$probe")"
    return 1
  fi
  # ⚠️ 不能写成 `printf ... | grep -q ...`（R8 自查，已实测）: 脚本开了 set -o pipefail，
  #    而 grep -q 命中后立刻退出，上游 printf 收到 SIGPIPE → 管道退出码 141 →
  #    被这里的 `!` 反转成「仍检出 MCP」→ 明明干净却拒绝开工。输出超过管道缓冲（64KB）即复现。
  #    用 case 做纯字符串匹配，根本不经过管道。
  case "$probe" in
    *'No MCP servers configured'*) : ;;
    *) log "⚠️ 隔离 CODEX_HOME 下仍检出 MCP，拒绝开工: $(printf '%.200s' "$probe")"; return 1 ;;
  esac
  return 0
}

# ── 超时看门狗（R8 自查）────────────────────────────────────────────────
#
# 整个脚本原本**没有任何超时**。这不是边角: 一次挂起会让编排器永久持有 NIGHT.lock，
# 之后每 5 分钟的 launchd 触发都只打印「锁被 pid X 持有」然后退出——整夜死掉，
# 且**没有早报、没有推送**。SKILL.md 宣称的「进程崩了下一跳续跑」只覆盖崩溃，不覆盖挂起；
# 而挂起恰恰是无人值守最需要防的失效模式。acquire_lock 也只在持有者进程**已死**时接管，
# 活着但卡住的进程会一直霸占锁。
#
# 这条是我自己测出来的: `codex exec` 在 stdin 未关闭时会打印
# 「Reading additional input from stdin...」并**无限等待**——run_codex 原来不重定向 stdin，
# 只是碰巧 launchd 默认给 /dev/null 才没在生产里炸。
#
# macOS 无 GNU timeout，自己实现: 后台跑 → 轮询到期 → TERM，宽限 10s 后 KILL。超时返回 124。
AI_TIMEOUT_SECS="${SLEEP_WELL_AI_TIMEOUT:-1800}"
run_with_timeout() {
  local secs="$1"; shift
  # ⚠️ 必须整**进程组**终止（Codex R9 #2，已实测）: 只 kill 直接子进程时，
  #    codex/claude 派生的孙进程会成为孤儿继续跑——wrapper 已返回 124、hook 已恢复、
  #    锁已释放、甚至下一跳都开工了，那个孤儿还在往仓库里写。
  #    set -m 让后台作业自成进程组，kill -TERM -$pid 才能覆盖整棵树。
  local prev_m; case "$-" in *m*) prev_m=yes ;; *) prev_m=no ;; esac
  set -m
  "$@" &
  local cpid=$!
  [ "$prev_m" = no ] && set +m
  # 把活动子进程组号落盘: 父进程停滞时，只有看门狗还能去终止这个**分离的**组
  # （Codex R10 #1）。set -m 保证 pgid == cpid，实测确认过。
  printf '%s %s\n' "$$" "$cpid" >"$ACTIVE_PGID_FILE" 2>/dev/null
  local waited=0 g
  while kill -0 "$cpid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      log "⚠️ 子进程组 ${cpid} 超过 ${secs}s 未返回，整组终止"
      kill -TERM -"$cpid" 2>/dev/null
      g=0; while kill -0 "$cpid" 2>/dev/null && [ "$g" -lt 10 ]; do sleep 1; g=$((g+1)); done
      # ⚠️ 升级只对**进程组**做，且先确认它还在（Codex R10 #3）:
      #    原来那个 `|| kill -KILL "$cpid"` 回退，在组已退出且 PID 被复用时会打到无关进程。
      kill -0 -"$cpid" 2>/dev/null && kill -KILL -"$cpid" 2>/dev/null
      wait "$cpid" 2>/dev/null
      rm -f "$ACTIVE_PGID_FILE" 2>/dev/null
      return 124
    fi
    sleep 1; waited=$((waited+1))
    # 轮询期间刷新心跳（Codex R9 #6）: 一个任务可能连做实现→审查→修复三次 AI 调用，
    # 若心跳只在外层循环开头更新，合法的无心跳区间能接近 5400s，看门狗会误杀正常夜班。
    # 在这里刷新之后，「无心跳」只可能发生在**有界调用之外**——正是看门狗该管的范围，
    # 而调用内部的卡死由本函数自己的超时兜住，两者不重叠也不留缝。
    [ $((waited % 30)) -eq 0 ] && beat
  done
  wait "$cpid"
  local rc=$?
  rm -f "$ACTIVE_PGID_FILE" 2>/dev/null
  return $rc
}

_run_codex_inner() {
  local repo="$1" body="$2" outfile="$3"
  # </dev/null 是必须的，不是防御性写法: 没有它，stdin 不是 /dev/null 时 codex 会永久阻塞。
  ( cd "$repo" && umask 022 && CODEX_HOME="$SW_CODEX_HOME" "$CODEX_BIN" exec --skip-git-repo-check \
      -s workspace-write -c sandbox_workspace_write.network_access=false \
      "$body" ) </dev/null >"$outfile" 2>&1
}

_run_cli_snapshot_inner() {
  node "$CLI" "$1" "$2" >"$3" 2>>"$RUNLOG"
}
bounded_cli_snapshot() {
  local kind="$1" repo="$2" tmp rc
  tmp="$(mktemp "$STATE_DIR/${kind}.XXXXXX")" || return 1
  run_with_timeout "$AI_TIMEOUT_SECS" _run_cli_snapshot_inner "$kind" "$repo" "$tmp"
  rc=$?
  if [ "$rc" -eq 0 ]; then cat "$tmp"; fi
  rm -f "$tmp" 2>/dev/null
  return "$rc"
}

# 统一的「调用 codex 并处置结果」（Codex R14 #1 推荐）: 三个调用点各写一遍的结果是
# 我 R13 只修了两处、**又漏掉普通修复路径**，护栏洞在同一轮里没修干净。
# 约定: 返回 0=成功（已写恢复证据、已过护栏核验）; 2=该侧不可用;
# 3=护栏中止（GUARD_ABORT_REASON 区分违规与不可得）。
codex_step() {
  local repo="$1" body="$2" outfile="$3" id="$4" what="$5"
  local reserved_before_json reserved_before reserved_after_json reserved_after
  if ! reserved_before_json="$(bounded_cli_snapshot review-content-snapshot "$repo")" \
     || ! reserved_before="$(jq_get "$reserved_before_json" digest)"; then
    GUARD_ABORT_REASON="护栏不可得"
    log "[$id] 无法建立 .review 保留区快照，失败关闭"
    return 3
  fi
  run_codex "$repo" "$body" "$outfile"
  local rc=$? kind
  # This must precede even the .review snapshot, because that snapshot invokes
  # Git and a modified config could activate fsmonitor/filter commands.
  guard_git_meta_verify "$repo" || return 3
  if ! reserved_after_json="$(bounded_cli_snapshot review-content-snapshot "$repo")" \
     || ! reserved_after="$(jq_get "$reserved_after_json" digest)"; then
    GUARD_ABORT_REASON="护栏不可得"
    log "[$id] 无法核验 .review 保留区，失败关闭"
    return 3
  fi
  if [ "$reserved_after" != "$reserved_before" ]; then
    GUARD_ABORT_REASON="护栏违规"
    log "[$id] 护栏违规: 实现者修改了 .review 保留区"
    push "🚨 护栏违规" "实现者修改了审查保留区，夜班已中止"
    return 3
  fi
  kind="$(jq_get "$(node "$CLI" classify "$outfile" "$rc" codex)" kind || echo other)"
  if [ "$kind" != ok ]; then
    log "[$id] ${what}codex 不可用: ${kind}"
    # ⚠️ 失败也要核验（R13 符合性扫查）: codex 可能在失败前已经动过受保护文件，
    #    那份改动没人检出，下一跳 guard_snapshot 会把它当成新基线，从此再也发现不了。
    if ! guard_verify "$repo"; then
      return 3
    fi
    node "$CLI" availability-set codex "$kind" >/dev/null 2>>"$RUNLOG" || {
      log "[$id] codex 不可用状态写入失败"
      return 4
    }
    return 2
  fi
  # ⚠️ **护栏核验必须排在一切之前**（Codex R15 #1，他实测复现）: 我 R14 为了不吞掉
  #    恢复证据的写盘失败，在它前面加了 `return 2`——于是「codex 成功改了受保护文件
  #    + 写盘恰好失败」时直接返回，**跳过了 guard_verify**，那次改动无人检出，
  #    下一跳还会把它重新快照成基线。修一个洞时在同一个函数里开了另一个。
  #    顺序原则: 只要 codex 跑过，无论后续怎么处置，护栏都必须先跑完。
  guard_verify "$repo" || return 3
  # 成功即证明该侧已恢复（R13 #1）。写盘失败不能吞（R14 #3）: 上一跳记了
  # 「codex 不可用」，这次在途重试成功了却没能置回 ok，主循环就会一直停在
  # fix-only、拒绝每一个 pending 任务，最后误报「退避耗尽」。
  if ! node "$CLI" availability-set codex ok >/dev/null 2>>"$RUNLOG"; then
    log "[$id] ⚠️ 可用性恢复证据写盘失败——按不可用处理，避免卡在 fix-only"
    push "⚠️ 夜班状态异常" "可用性状态写盘失败，请查看日志"
    return 2
  fi
  return 0
}

run_codex() {
  local repo="$1" body="$2" outfile="$3"
  # 进程级沙箱是**主门禁**（Codex R2 #1 推荐，2026-08-10 实测有效）:
  #   -s workspace-write            → 仓库内可写、仓库外写入被拒
  #   network_access=false          → 无网络，任何 remote push 不可能
  # 用户全局 config.toml 里 network_access=true，此处逐次覆盖。
  # MCP/插件隔离由 prepare_codex_home 创建的独立 CODEX_HOME 保证；命令行
  # `-c mcp_servers={}` 实测无效，不能把它描述成第二道隔离机制。
  # ⚠️ **读取边界未受约束**（Codex R3 #2，已实测）: workspace-write 挡写不挡读，
  #   Codex 能 cat 仓库外任意可读文件并经输出通道带出。已列入 SKILL.md 已知限制。
  run_with_timeout "$AI_TIMEOUT_SECS" _run_codex_inner "$repo" "$body" "$outfile"
  local rc=$?
  [ "$rc" -eq 124 ] && log "[codex] 超时 ${AI_TIMEOUT_SECS}s，已终止"
  return $rc
}

# ── 单个任务 ──────────────────────────────────────────────────────────
# Persist a terminal human-review state from any live task state. Reading the
# current value avoids relying on _process_task_inner's stale `status` argument
# after one or more transitions. A write failure is an internal fault, never a
# successful task outcome.
mark_task_needs_human() {
  local id="$1" current
  current="$(node "$CLI" get-field "$id" status 2>>"$RUNLOG")" || {
    log "[$id] 无法读取任务状态，不能可靠转人工"
    return 1
  }
  [ "$current" = needs_human ] && return 0
  if [ "$current" = pending ]; then
    node "$CLI" advance "$id" implementing >/dev/null 2>>"$RUNLOG" || {
      log "[$id] pending → implementing 状态写入失败"
      return 1
    }
  fi
  node "$CLI" advance "$id" needs_human >/dev/null 2>>"$RUNLOG" || {
    log "[$id] 转 needs_human 状态写入失败"
    return 1
  }
}

# Advance exactly this task to reviewing. `next-task` is not a status lookup:
# after a concurrent/state failure it may select a different reviewing task.
ensure_task_reviewing() {
  local id="$1" current
  node "$CLI" advance "$id" reviewing >/dev/null 2>>"$RUNLOG" && return 0
  current="$(node "$CLI" get-field "$id" status 2>>"$RUNLOG")" || {
    log "[$id] 无法读取本任务状态，不能确认 reviewing"
    return 1
  }
  [ "$current" = reviewing ] || {
    log "[$id] 无法转入 reviewing（当前状态: ${current}）"
    return 1
  }
}

# 返回 0=本任务告一段落  2=可用性问题（主循环按 decideHop 处置）
#      3=护栏中止（GUARD_ABORT_REASON 区分违规与不可得）
#      4=内部状态故障（立即 hop_fail）
# 包装: 保证任何退出路径都恢复用户原有的 pre-push hook
process_task() {
  local rc
  _process_task_inner "$@"; rc=$?
  # hook 清理失败一律中止整夜（Codex R6 #3）: 保留 rc=2 会让下一跳继续跑并覆盖
  # 恢复状态，用户原有的 hook 就永久丢了。
  guard_uninstall || {
    log "⚠️ hook 恢复失败——升级为护栏中止"
    GUARD_ABORT_REASON="pre-push hook 未能恢复"
    rc=3
  }
  return $rc
}

# A checkpoint must never commit review-adapter artifacts. Excluding .review
# from `git add` is insufficient because a plain `git commit` submits every
# entry already present in the index. The review content snapshot catches an
# adapter that staged .review; this is the final fail-closed boundary directly
# before every checkpoint.
checkpoint_commit() {
  local repo="$1" message="$2" staged_review
  guard_git_meta_verify "$repo" || return 3
  staged_review="$(git -C "$repo" ls-files -- .review 2>>"$RUNLOG")" || {
    GUARD_ABORT_REASON="护栏不可得"
    log "checkpoint 前无法核验 .review 索引，拒绝提交"
    push "🚨 护栏核验失败" "checkpoint 前无法核验 .review 索引，夜班已中止"
    return 3
  }
  if [ -n "$staged_review" ]; then
    GUARD_ABORT_REASON="护栏违规"
    log "checkpoint 拒绝: .review/ 已进入 Git 索引"
    push "🚨 护栏违规" "checkpoint 前检出 .review 已暂存，夜班已中止"
    return 3
  fi
  # The metadata digest is the observable fail-closed boundary. Disable hooks
  # as an additional execution-time barrier for the checkpoint itself.
  ( cd "$repo" \
    && git -c core.hooksPath=/dev/null add -A -- . ':(exclude).review' \
    && git -c core.hooksPath=/dev/null commit --no-verify -q -m "$message" ) 2>>"$RUNLOG"
}

load_constraint_prompt() {
  local name="$1" path="$SKILL_DIR/prompts/$1"
  if [ ! -r "$path" ] || [ ! -s "$path" ]; then
    log "约束提示词缺失、为空或不可读: prompts/${name}"
    return 1
  fi
  cat "$path" 2>>"$RUNLOG" || {
    log "读取约束提示词失败: prompts/${name}"
    return 1
  }
}

# The current metadata guard intentionally covers one complete repository
# worktree. Nested gitdirs, other linked worktrees, and local config includes
# introduce mutable Git configuration outside that frozen path set. Reject
# those shapes before any AI call until they have their own audited enumerator.
UNATTENDED_SHAPE_REASON=""
check_unattended_repo_shape() {
  local repo="$1" staged gitlinks worktrees worktree_n hooks_path hooks_rc worktree_cfg worktree_cfg_rc includes include_rc
  staged="$(git -C "$repo" ls-files --stage 2>>"$RUNLOG")" || return 2
  gitlinks="$(printf '%s\n' "$staged" | awk '$1 == "160000" { n++ } END { print n + 0 }')" || return 2
  if [ "$gitlinks" -gt 0 ]; then
    UNATTENDED_SHAPE_REASON="仓库含子模块 gitlink"
    return 1
  fi

  worktrees="$(git -C "$repo" worktree list --porcelain 2>>"$RUNLOG")" || return 2
  worktree_n="$(printf '%s\n' "$worktrees" | awk '$1 == "worktree" { n++ } END { print n + 0 }')" || return 2
  if [ "$worktree_n" -gt 1 ]; then
    UNATTENDED_SHAPE_REASON="仓库关联了其它 linked worktree"
    return 1
  fi

  hooks_path="$(git -C "$repo" config --path --get core.hooksPath 2>>"$RUNLOG")"
  hooks_rc=$?
  if [ "$hooks_rc" -eq 0 ] && [ -n "$hooks_path" ]; then
    UNATTENDED_SHAPE_REASON="仓库使用自定义 core.hooksPath"
    return 1
  fi
  [ "$hooks_rc" -eq 1 ] || return 2

  worktree_cfg="$(git -C "$repo" config --local --type=bool --get extensions.worktreeConfig 2>>"$RUNLOG")"
  worktree_cfg_rc=$?
  if [ "$worktree_cfg_rc" -eq 0 ] && [ "$worktree_cfg" = true ]; then
    UNATTENDED_SHAPE_REASON="仓库启用了 extensions.worktreeConfig"
    return 1
  fi
  [ "$worktree_cfg_rc" -eq 0 ] || [ "$worktree_cfg_rc" -eq 1 ] || return 2

  includes="$(git -C "$repo" config --local --get-regexp '^include.*\.path$' 2>>"$RUNLOG")"
  include_rc=$?
  if [ "$include_rc" -eq 0 ] && [ -n "$includes" ]; then
    UNATTENDED_SHAPE_REASON="仓库本地 Git 配置使用 include.path/includeIf"
    return 1
  fi
  [ "$include_rc" -eq 1 ] || return 2
  return 0
}

_process_task_inner() {
  local id="$1" repo="$2" status="$3" prompt="$4" title="$5"
  local ts; ts="$(date '+%H%M%S')"
  if [ -z "$repo" ]; then
    log "[$id] repo 为空，拒绝在编排器当前目录执行任务"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: queue 任务缺少 repo"
    return 0
  fi
  # id 保留原样（可能是中文或含空格——queue.md 是用户手写且与 Claude 侧共享的），
  # 只对**派生的文件名**做编码（Codex R16 #2 推荐的方案）。
  # 加 8 位哈希后缀防止 `a b` 与 `a-b` 编码后撞名。
  # ⚠️ `pending -> needs_human` 是 state.mjs 明令禁止的转移（Codex R18 #2）:
  #    原来直接这么转、错误又被 `2>/dev/null` 吞掉，任务会**留在 pending 被反复重试**，
  #    而日志声称已转人工。先走合法的中间态 implementing 再转。
  local sid
  if ! sid="$(safe_id "$id")"; then
    log "[$id] 无法派生安全文件名（shasum 不可用），转人工"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: 无法派生安全文件名"
    return 2
  fi
  local co="$LOG_DIR/${sid}-${ts}.codex.out" ro="$LOG_DIR/${sid}-${ts}.review.out" re="$LOG_DIR/${sid}-${ts}.review.err"
  local repair_evidence="$LOG_DIR/${sid}-${ts}.findings.md"

  # .git 可以是**文件**，所以仓库识别不能只判目录；下方会在独立的
  # unattended-shape 门禁中拒绝尚未覆盖元数据面的 linked worktree / submodule。
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # pending → needs_human 是非法转换（state.mjs 的 LEGAL 只允许 pending→implementing|skipped）；
    # 原实现直接跳，CLI 报错被吞、函数还返回 0，同一任务被主循环反复选中（Codex R1 #16）。
    log "[$id] repo 不是 git 仓库: ${repo}"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: repo 不是 git 仓库"
    return 0
  fi

  # All baseline, protected-path and checkpoint operations are defined over a
  # complete repository. A subdirectory silently narrows pathspec `.` while
  # `git commit` still consumes the whole index, so reject it rather than mix
  # scopes. Canonical paths keep a symlink that resolves to the root valid.
  local repo_top repo_real
  repo_top="$(git -C "$repo" rev-parse --show-toplevel 2>>"$RUNLOG")" || repo_top=""
  [ -z "$repo_top" ] || repo_top="$(cd "$repo_top" 2>/dev/null && pwd -P)"
  repo_real="$(cd "$repo" 2>/dev/null && pwd -P)" || repo_real=""
  if [ -z "$repo_top" ] || [ "$repo_real" != "$repo_top" ]; then
    log "[$id] repo 必须是 Git 仓库顶层目录: ${repo}"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: repo 必须是 Git 仓库顶层目录"
    return 0
  fi
  repo="$repo_top"

  check_unattended_repo_shape "$repo"
  local shape_rc=$?
  if [ "$shape_rc" -eq 1 ]; then
    log "[$id] ${UNATTENDED_SHAPE_REASON}；当前元数据护栏不覆盖，拒绝无人值守"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: ${UNATTENDED_SHAPE_REASON}，暂不支持无人值守"
    return 0
  elif [ "$shape_rc" -ne 0 ]; then
    log "[$id] 无法核验仓库 Git 元数据拓扑 → 转人工"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: 无法核验仓库 Git 元数据拓扑"
    return 0
  fi

  # `.review/` is reserved for review-adapter output and is excluded from
  # baselines, protected snapshots and checkpoint commits. If the target
  # repository tracks that namespace itself, unattended operation would hide
  # real project changes. Refuse the task before installing hooks or invoking AI.
  local tracked_review
  tracked_review="$(git -C "$repo" ls-files -- .review 2>>"$RUNLOG")" || {
    log "[$id] 无法检查保留的 .review 命名空间 → 转人工"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: 无法检查 .review 保留命名空间"
    return 0
  }
  if [ -n "$tracked_review" ]; then
    log "[$id] 目标仓库已跟踪 .review/；该路径是编排器保留命名空间，拒绝无人值守"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: 仓库使用了保留的 .review/ 路径"
    return 0
  fi

  # 干净基线要求（Codex R2 #10）: 仓库若已有用户自己的未提交改动，
  # 本任务结束时的 `git add -A` 会把它们一并提交进 checkpoint。开工前即拒绝。
  # 只在**开工那一刻**要求；任务自身产生的 dirty 由 nextTask 的同仓库串行保证不混。
  if [ "$status" = pending ]; then
    local base_st; base_st="$(git -C "$repo" status --porcelain -- . ':(exclude).review' 2>>"$RUNLOG")" || {
      log "[$id] 无法读取基线状态 → 转人工（不猜）";
      mark_task_needs_human "$id" || return 4
      push "⚠️ 需要拍板" "${title}: 无法读取仓库状态"; return 0; }
    if [ -n "$base_st" ]; then
      log "[$id] 仓库有既存未提交改动，拒绝开工（避免把你的工作混进 checkpoint）:"
      printf '%s\n' "$base_st" | head -10 | sed 's/^/    | /' >>"$RUNLOG"
      mark_task_needs_human "$id" || return 4
      push "⚠️ 需要拍板" "${title}: 仓库有既存未提交改动，未开工"
      return 0
    fi
  fi

  # An unborn repository has no checkpoint baseline. Treat it as a task-local
  # precondition requiring a human bootstrap commit, not as a fabricated guard
  # violation that aborts every later task in the night.
  if ! git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
    log "[$id] repo 尚无可用的 HEAD 提交，无法建立 checkpoint 基线 → 转人工"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: repo 尚无 HEAD 提交，请先建立初始 checkpoint 基线"
    return 0
  fi

  # 记录原始分支（Codex R4 #4）: Codex 若切了分支，后续 checkpoint 会提交到错误分支上
  GUARD_BRANCH="$(guard_branch_identity "$repo")" || {
    log "[$id] 无法捕获当前分支身份 → 护栏不可得"
    return 3
  }
  GUARD_ABORT_REASON="护栏不可得"
  guard_install "$repo" || { log "[$id] 护栏安装失败"; return 3; }
  guard_snapshot "$repo" || { guard_uninstall; log "[$id] 护栏快照失败"; return 3; }

  # 1. 实现——只在 pending/implementing 时做。
  #    fixing 与 reviewing 都**不能**重跑 implement prompt（Codex R1 #9: 原实现在
  #    fixing 状态下会用原任务提示词再实现一遍，每个非零 findings 轮都发生）。
  if [ "$status" = pending ] || [ "$status" = implementing ]; then
    if [ "$status" = pending ]; then
      node "$CLI" advance "$id" implementing >/dev/null 2>>"$RUNLOG" || {
        log "[$id] pending → implementing 状态写入失败"
        return 4
      }
    fi
    log "[$id] 实现开始"
    local implement_rules
    implement_rules="$(load_constraint_prompt implement.md)" || {
      GUARD_ABORT_REASON="约束提示词不可得"
      log "[$id] 无法读取实现约束，拒绝调用 Codex"
      return 3
    }
    codex_step "$repo" "$(printf '%s\n\n%s\n' "$prompt" "$implement_rules")" \
               "$co" "$id" ""
    local crc=$?; [ "$crc" -ne 0 ] && return "$crc"
    ensure_task_reviewing "$id" || return 4
  elif [ "$status" = fixing ]; then
    # 从 fixing 恢复 = 上一跳的修复轮因可用性问题中断，修复**没做完**。
    # 直接转 reviewing 会拿未修的 diff 再审一轮，findings 数不降 → decideNext 判 stall
    # → 把一次临时故障升级成 needs_human（Codex R3 #9）。故重跑修复提示。
    log "[$id] 从中断的修复轮恢复，重跑修复"
    local lastff; lastff="$(node "$CLI" get-field "$id" lastFindingsFile 2>/dev/null || echo '')"
    if [ -z "$lastff" ] || [ ! -f "$lastff" ] || ! cp "$lastff" "$repair_evidence"; then
      log "[$id] 上轮 findings 证据缺失，无法安全恢复修复轮"
      mark_task_needs_human "$id" || return 4
      return 0
    fi
    local resume_fix_rules
    resume_fix_rules="$(load_constraint_prompt fix.md)" || {
      GUARD_ABORT_REASON="约束提示词不可得"
      log "[$id] 无法读取修复约束，拒绝调用 Codex"
      return 3
    }
    codex_step "$repo" "$(printf '原始任务范围（唯一任务授权）:\n%s\n\n继续修复上一轮审查发现的问题（上次修复被中断）。%s\n\n%s\n' \
                          "$prompt" " findings 详见 ${repair_evidence} 的「Findings」节。" \
                          "$resume_fix_rules")" "$co" "$id" "恢复修复时 "
    local crc2=$?; [ "$crc2" -ne 0 ] && return "$crc2"
    ensure_task_reviewing "$id" || return 4
  fi

  # 2. 审查（**不 commit**——审查必须看未提交的 diff）
  # 状态写不进去就不能继续（Codex R5 #9）: 否则崩溃后从旧状态恢复会重跑实现
  ensure_task_reviewing "$id" || return 4
  # defer-review: claude 已知不可用，不必再打一次注定失败的调用——直接挂起
  if [ "${HOP_MODE:-work}" = defer-review ]; then
    log "[$id] claude 不可用，跳过本轮审查并挂起（下一跳重试）"
    node "$CLI" set-field "$id" reviewDeferred true >/dev/null 2>&1 \
      || { log "[$id] 挂起标记写入失败"; return 2; }
    return 0
  fi
  log "[$id] 审查开始"
  # This is the sole production definition of the reviewer argv contract.
  # Keep it in sync with README "Required reviewer"; the E2E fake records and
  # asserts the exact argv so changes here cannot drift behind a dead helper.
  _run_review_inner() { "$REVIEW_SH" -C "$1" --uncommitted -t decision </dev/null >"$2" 2>"$3"; }
  local review_before_json review_before
  if ! review_before_json="$(bounded_cli_snapshot repo-content-snapshot "$repo")" \
     || ! review_before="$(jq_get "$review_before_json" digest)"; then
    GUARD_ABORT_REASON="护栏不可得"
    log "[$id] 无法建立审查器只读快照，失败关闭"
    push "🚨 护栏核验失败" "无法建立审查前内容快照，夜班已中止"
    return 3
  fi
  run_with_timeout "$AI_TIMEOUT_SECS" _run_review_inner "$repo" "$ro" "$re"
  local rcode=$?
  # The reviewer runs outside the Codex sandbox. Once it has run, verify its
  # side effects before interpreting *any* outcome, including timeout,
  # unavailability, malformed output and findings-integrity failure.
  guard_verify "$repo" || return 3
  local review_after_json review_after
  if ! review_after_json="$(bounded_cli_snapshot repo-content-snapshot "$repo")" \
     || ! review_after="$(jq_get "$review_after_json" digest)"; then
    GUARD_ABORT_REASON="护栏不可得"
    log "[$id] 无法建立审查后内容快照，失败关闭"
    push "🚨 护栏核验失败" "无法建立审查后内容快照，夜班已中止"
    return 3
  fi
  if [ "$review_after" != "$review_before" ]; then
    GUARD_ABORT_REASON="护栏违规"
    log "[$id] 护栏违规: 审查适配器修改了 .review/ 之外的 Git 可见内容或索引"
    push "🚨 护栏违规" "审查适配器修改了仓库内容，夜班已中止"
    return 3
  fi
  # A timeout is generated by this orchestrator and therefore cannot represent a complete review,
  # even if the adapter wrote a provisional findings file before it was terminated.
  if [ "$rcode" -eq 124 ]; then
    log "[$id] 审查超时 ${AI_TIMEOUT_SECS}s，按不完整审查转人工"
    mark_task_needs_human "$id" || return 4
    [ -n "$(git -C "$repo" status --porcelain -- . ':(exclude).review' 2>/dev/null)" ] \
      && node "$CLI" set-field "$id" dirtyResidue true >/dev/null 2>&1
    push "⚠️ 需要拍板" "${title}: 审查超时，未采信临时结果"
    return 0
  fi
  local parsed; parsed="$(cli_json parse-review "$ro" "$re" "$rcode")" || return 2
  if [ "$(jq_get "$parsed" ok || echo false)" != true ]; then
    local un; un="$(jq_get "$parsed" unavailable || echo '')"
    if [ -n "$un" ]; then
      log "[$id] claude 不可用: ${un}"
      node "$CLI" availability-set claude "$un" >/dev/null 2>>"$RUNLOG" || {
        log "[$id] claude 不可用状态写入失败"
        return 4
      }
      node "$CLI" set-field "$id" reviewDeferred true >/dev/null 2>>"$RUNLOG" || {
        log "[$id] 挂起审查状态写入失败"
        return 4
      }
      return 2
    fi
    log "[$id] 审查未产出可信 findings: $(jq_get "$parsed" reason || echo '')"
    mark_task_needs_human "$id" || return 4
    [ -n "$(git -C "$repo" status --porcelain -- . ':(exclude).review' 2>/dev/null)" ] \
      && node "$CLI" set-field "$id" dirtyResidue true >/dev/null 2>&1
    push "⚠️ 需要拍板" "${title}: 审查未产出可信结果"
    return 0
  fi

  local ff parsed_n
  if ! ff="$(jq_get "$parsed" findingsFile)" || ! parsed_n="$(jq_get "$parsed" count)"; then
    log "[$id] 审查成功响应缺少 findingsFile/count，按不可信结果转人工"
    mark_task_needs_human "$id" || return 4
    [ -n "$(git -C "$repo" status --porcelain -- . ':(exclude).review' 2>/dev/null)" ] \
      && node "$CLI" set-field "$id" dirtyResidue true >/dev/null 2>&1
    push "⚠️ 需要拍板" "${title}: 审查响应字段不完整"
    return 0
  fi
  # Findings may live outside the repository or inside its reserved .review/
  # namespace, but never at an ordinary repository path. Resolve symlinks before
  # accepting the path so an adapter cannot smuggle a source file in as output.
  local real_repo real_ff
  real_repo="$(realpath "$repo" 2>/dev/null)" || real_repo=""
  real_ff="$(realpath "$ff" 2>/dev/null)" || real_ff=""
  if [ -z "$real_repo" ] || [ -z "$real_ff" ]; then
    log "[$id] findings 路径无法规范化，按不可信结果转人工: ${ff}"
    mark_task_needs_human "$id" || return 4
    push "⚠️ 需要拍板" "${title}: findings 路径无法可信确认"
    return 0
  fi
  case "$real_ff" in
    "$real_repo"/.review/*) : ;;
    "$real_repo"/*)
      log "[$id] findings 位于普通仓库路径而非 .review/，拒绝记录: ${real_ff}"
      mark_task_needs_human "$id" || return 4
      push "⚠️ 需要拍板" "${title}: 审查产物写入了保留区之外"
      return 0 ;;
  esac
  # 审查成功 = claude 已恢复（同 R13 #1 的理由: 以实际成功为恢复证据，
  # 而不是等「两侧都 ok」才 availability-reset——那在单侧故障时永远等不到）
  if ! node "$CLI" availability-set claude ok >/dev/null 2>>"$RUNLOG"; then
    log "[$id] claude 可用性恢复证据写盘失败"
    return 4
  fi
  # 路径可能含引号/反斜杠，手工拼 JSON 会炸——交给 node 转义（Codex R5 #8）
  if ! cp "$ff" "$repair_evidence"; then
    log "[$id] findings 无法复制到仓库外修复证据区，停止本任务"
    mark_task_needs_human "$id" || return 4
    return 0
  fi
  node "$CLI" set-field-str "$id" lastFindingsFile "$repair_evidence" >/dev/null 2>>"$RUNLOG" || {
    # 写不进去 → 中断恢复时会拿陈旧的 findings 路径去修（Codex R6 #7）
    log "[$id] findings 路径持久化失败，停止本任务"; return 2; }
  # 完整性断言失败 = 审查失败（Codex R1 #4: 原实现只记日志继续，声明 0 条就照样提交）
  local rf n authoritative_nh
  if ! rf="$(cli_json record-findings "$ff" "$id" "$repo")"; then
    log "[$id] findings 完整性断言失败——按审查失败处置"
    mark_task_needs_human "$id" || return 4
    [ -n "$(git -C "$repo" status --porcelain -- . ':(exclude).review' 2>/dev/null)" ] \
      && node "$CLI" set-field "$id" dirtyResidue true >/dev/null 2>&1
    push "⚠️ 需要拍板" "${title}: findings 文件完整性可疑"
    return 0
  fi
  if ! n="$(jq_get "$rf" declared)" \
     || ! authoritative_nh="$(jq_get "$rf" needsHuman)" \
     || [ "$n" != "$parsed_n" ]; then
    log "[$id] findings 权威条数不可得或与适配器响应不一致，按不可信结果转人工"
    mark_task_needs_human "$id" || return 4
    [ -n "$(git -C "$repo" status --porcelain -- . ':(exclude).review' 2>/dev/null)" ] \
      && node "$CLI" set-field "$id" dirtyResidue true >/dev/null 2>&1
    push "⚠️ 需要拍板" "${title}: findings 条数无法可信确认"
    return 0
  fi
  log "[$id] findings ${n} 条"

  # 3. 判定
  local d action; d="$(cli_json push-findings-count "$id" "$n")" || return 2
  action="$(jq_get "$d" action)"
  log "[$id] decideNext → ${action}（$(jq_get "$d" reason || echo '')）"
  case "$action" in
    done)
      # 0 findings is not proof that implementation produced a checkpointable
      # change. Distinguish an empty diff from a real commit failure so morning
      # diagnostics do not send the user toward Git configuration or storage.
      local final_status
      if ! final_status="$(git -C "$repo" status --porcelain -- . ':(exclude).review' 2>>"$RUNLOG")"; then
        log "[$id] 无法确认最终工作区状态 → needs_human"
        mark_task_needs_human "$id" || return 4
        push "⚠️ 需要拍板" "${title}: 无法确认最终工作区状态"
        return 0
      fi
      if [ -z "$final_status" ]; then
        log "[$id] 本次实现未产生任何改动，未创建 checkpoint → needs_human"
        mark_task_needs_human "$id" || return 4
        push "⚠️ 需要拍板" "${title}: 本次实现未产生任何改动"
        return 0
      fi
      # 提交失败绝不标 done（Codex R1 #11: 未提交改动会污染下一任务，早报却说已完成）
      local done_checkpoint_rc
      checkpoint_commit "$repo" "sleep-well-codex: ${id} done"
      done_checkpoint_rc=$?
      [ "$done_checkpoint_rc" -eq 3 ] && return 3
      if [ "$done_checkpoint_rc" -ne 0 ]; then
        log "[$id] checkpoint 提交失败 → needs_human"
        mark_task_needs_human "$id" || return 4
        push "⚠️ 需要拍板" "${title}: 审查通过但提交失败"; return 0
      fi
      # 状态持久化失败就不能宣告完成（Codex R4 #13）: 否则推送说完成、
      # 磁盘上任务仍是 reviewing，下一跳会重做一遍。
      if ! node "$CLI" advance "$id" done >/dev/null 2>>"$RUNLOG"; then
        log "[$id] 已 checkpoint 但状态写入失败"
        push "⚠️ 状态异常" "${title}: 已提交但状态未落盘，请查看日志"; return 4
      fi
      push "✓ 任务完成" "$title"
      ;;
    continue)
      # 高严重度不得自动修（Codex R2 #8）: extractFindings 已把「高」映射成
      # needs-human，但原实现并未据此设门，仍会让 Codex 去改。
      # Authoritative count comes from the same extractFindings result that was
      # just persisted. Metadata and a raw heading count remain conservative
      # tertiary signals: any source saying "high" closes the auto-fix gate.
      local hi meta_hi raw_hi
      hi="$authoritative_nh"
      meta_hi="$(jq_get "$parsed" high || echo 0)"
      raw_hi="$(grep -c '^### #[0-9]* \[高\]' "$ff" 2>/dev/null || true)"
      raw_hi="${raw_hi:-0}"
      [ "${meta_hi:-0}" -gt "${hi:-0}" ] && hi="$meta_hi"
      [ "${raw_hi:-0}" -gt "${hi:-0}" ] && hi="$raw_hi"
      if [ "${hi:-0}" -gt 0 ]; then
        log "[$id] 含 ${hi} 条高严重度 findings → 不自动修复，转人工"
        local high_checkpoint_rc
        checkpoint_commit "$repo" "sleep-well-codex: ${id} WIP 高危待人工"
        high_checkpoint_rc=$?
        [ "$high_checkpoint_rc" -eq 3 ] && return 3
        [ "$high_checkpoint_rc" -ne 0 ] \
          && log "[$id] 高危 WIP checkpoint 提交失败（工作仍在工作区）"
        mark_task_needs_human "$id" || return 4
        [ -n "$(git -C "$repo" status --porcelain -- . ':(exclude).review' 2>/dev/null)" ] \
          && node "$CLI" set-field "$id" dirtyResidue true >/dev/null 2>&1
        push "⚠️ 需要拍板" "${title}: ${hi} 条高严重度，未自动修改"
        return 0
      fi
      node "$CLI" advance "$id" fixing >/dev/null 2>>"$RUNLOG" || {
        log "[$id] reviewing → fixing 状态写入失败"
        return 4
      }
      log "[$id] 修复轮"
      local fix_rules
      fix_rules="$(load_constraint_prompt fix.md)" || {
        GUARD_ABORT_REASON="约束提示词不可得"
        log "[$id] 无法读取修复约束，拒绝调用 Codex"
        return 3
      }
      codex_step "$repo" "$(printf '原始任务范围（唯一任务授权）:\n%s\n\n审查发现 %s 条问题，详见仓库外只读证据 %s 的「Findings」节。\n\n%s\n' \
                             "$prompt" "$n" "$repair_evidence" "$fix_rules")" "$co" "$id" "修复轮 "
      local frc=$?; [ "$frc" -ne 0 ] && return "$frc"
      # 修复成功后显式转 reviewing（Codex R4 #3）: 留在 fixing 会让下一轮
      # 走「从中断的修复轮恢复」分支再修一遍，同一份 findings 被重复修改。
      ensure_task_reviewing "$id" || return 4
      ;;
    rotate)
      # rotate 的语义是「对同一份未提交 diff 开全新会话复审」，**不改 diff**
      # （Codex R1 #20: 原实现与 continue 共用修复分支，先改了再复审，语义走样）
      log "[$id] rotate: 摘要归档后以全新会话复审同一 diff"
      { echo "## rotate at $(date '+%F %T')"; echo "findings 条数: ${n}"; echo "findings 文件: ${ff}"; } \
        >>"$LOG_DIR/${sid}.md"
      # rotate 只复审、不改 diff。但不能借道 fixing——「从中断的修复轮恢复」分支会重跑
      # 修复提示（Codex R4 #5）。这里直接留在 reviewing，下一轮循环重新走审查。
      # 留在 reviewing 即可: 下一轮 process_task 见到 reviewing 会跳过实现直接复审。
      # 原先还设了个 rotateOnly 字段，但全仓库无人读取（Codex R5 确认删除安全），
      # 死状态会暗示一个并不存在的机制，故移除。
      :
      ;;
    stop)
      local stop_checkpoint_rc
      checkpoint_commit "$repo" "sleep-well-codex: ${id} WIP needs-human"
      stop_checkpoint_rc=$?
      [ "$stop_checkpoint_rc" -eq 3 ] && return 3
      if [ "$stop_checkpoint_rc" -ne 0 ]; then
        log "[$id] WIP 提交失败（工作仍在工作区）"
      fi
      mark_task_needs_human "$id" || return 4
      # 若工作区仍有残留，持久化 dirtyResidue 以继续阻塞同仓库后续任务（Codex R3 #14）
      [ -n "$(git -C "$repo" status --porcelain -- . ':(exclude).review' 2>/dev/null)" ] \
        && node "$CLI" set-field "$id" dirtyResidue true >/dev/null 2>&1
      push "⚠️ 需要拍板" "${title}: $(jq_get "$d" reason || echo '需人工判断')"
      ;;
    *)
      # ⚠️ 枚举必须有兜底（Codex R14 #8）: `action` 为空（jq_get 拿不到字段时返回非零，
      #    而赋值的退出码被忽略）会让四支全不匹配 → 直接 return 0 = 报告成功而任务未推进
      #    → 主循环反复取到同一个在途任务、同一跳内空转，只被 cutoff 兜住。
      #    ⚠️ 我在 R13 的 read-back 里写过「已加兜底」，**但那批编辑因前一个锚点失败而整体没写入**，
      #    per-item 的 ✓ 输出在中止前照样打印了。教训: 改完必须回读文件本身，不能信脚本输出。
      log "[$id] decideNext 返回了无法识别的 action: [${action}]——转人工，绝不当成成功"
      mark_task_needs_human "$id" || return 4
      push "⚠️ 需要拍板" "${title}: 审修循环判定异常"
      return 2 ;;
  esac
  return 0
}

# ── 主流程 ────────────────────────────────────────────────────────────
# 终止标记必须在抢锁之前检（否则收工后每 5 分钟仍会重跑一夜）
# 终止后仍要处理遗留的 hook 恢复（否则用户的 hook 永远回不来）。整个分支在
# 独立进程组里限时运行，因为此时尚未持锁、主看门狗也不能安全共享心跳。
handle_terminated_state() {
  local recovery_ok=yes had_hook_recovery=no recovery_rc=0
  if [ -f "$SW_RUNTIME_HOME/hook-recovery.json" ]; then
    had_hook_recovery=yes
    HOOK_STATE="$SW_RUNTIME_HOME/hook-recovery.json"
    recover_pending_hook || recovery_rc=$?
    case "$recovery_rc" in
      0) ;;
      2)
        log "node 不可用，终止态 hook 恢复已延期"
        push_once terminated-recovery-node-missing "⚠️ 夜班收尾待恢复" \
          "缺少依赖: node；pre-push hook 恢复材料已保留"
        recovery_ok=no ;;
      *) log "hook 仍待人工恢复；本夜已终止，不重复推送"; recovery_ok=no ;;
    esac
  fi
  # finalize may already have published TERMINATED before hook restoration
  # failed. Keep retrying recovery while loaded; once recovery succeeds, finish
  # the deferred self-unload so the five-minute launchd trigger really stops.
  if [ "$recovery_ok" = yes ]; then
    if [ "$had_hook_recovery" = yes ]; then
      # This is delayed cleanup from a real terminal run, not an operator who
      # forgot terminal-clear. Tell the truth before unload can terminate us.
      push_once terminated-recovery-complete "✓ 夜班收尾恢复" \
        "pre-push hook 已恢复；正在完成 launchd 自卸载。下一夜请照常清 STOP、terminal-clear 后再 load"
    else
      # A marker with no pending recovery most often means the operator
      # re-loaded launchd but forgot the documented terminal-clear step.
      push_once terminated-noop "⚠️ 夜班未开工" "上一夜的终止标记仍在；请先执行 terminal-clear 再重新 load"
    fi
    launchctl unload "$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist" 2>/dev/null \
      && log "终止态 hook 恢复完成，已自卸载 launchd" \
      || log "终止态 launchd 卸载跳过（可能未安装）"
  fi
  return 0
}
if [ -f "$SW_RUNTIME_HOME/TERMINATED" ]; then
  run_startup_bounded "终止态恢复与自卸载" handle_terminated_state \
    || log "⚠️ 终止态恢复未在启动时限内完成；保留状态供下一次重试"
  exit 0
fi
LOCK_RC=0
acquire_lock || LOCK_RC=$?
case "$LOCK_RC" in
  0) ;;
  1) exit 0 ;;
  *)
    # Do not steal or terminate a possibly-live unverifiable owner.  Publish a
    # single durable diagnostic instead; subsequent launchd/manual retries stay
    # quiet until a lock is successfully acquired and clears the marker.
    run_startup_bounded "锁异常告警" push_once lock-anomaly \
      "⚠️ 夜班未开工" "锁状态异常，无法安全验证持有者；详情见本机日志" \
      || log "⚠️ 锁异常告警未在启动时限内完成"
    exit 0 ;;
esac
# Validate watchdog inputs before starting it. The numeric checks are pure
# shell; the failure notification is explicitly bounded because push() may use
# node and curl. Once validation succeeds, publish a fresh heartbeat and arm the
# watchdog before hook recovery, STOP/cutoff handling, or dependency probes.
# 超大超时会同时关掉 run_with_timeout 与主看门狗：长调用每 30 秒刷新心跳，
# 所以看门狗也不会替一个几百万秒的 AI 超时兜底。对显式垃圾值必须在任何 AI、
# 依赖探针和 hook 操作之前可见地失败关闭，不能静默采用或进入算术扩张。
AI_TIMEOUT_VALID=yes
if AI_TIMEOUT_SECS="$(normalize_decimal "$AI_TIMEOUT_SECS")"; then :; else AI_TIMEOUT_VALID=no; fi
if [ "$AI_TIMEOUT_VALID" = yes ] \
   && { [ "${#AI_TIMEOUT_SECS}" -gt 5 ] || [ "$AI_TIMEOUT_SECS" -lt 1 ] || [ "$AI_TIMEOUT_SECS" -gt 86400 ]; }; then
  AI_TIMEOUT_VALID=no
fi
HANG_LIMIT_VALID=yes
if HANG_LIMIT_SECS="$(normalize_decimal "$HANG_LIMIT_SECS")"; then :; else HANG_LIMIT_VALID=no; fi
if [ "$HANG_LIMIT_VALID" = yes ] \
   && { [ "${#HANG_LIMIT_SECS}" -gt 5 ] || [ "$HANG_LIMIT_SECS" -lt 1 ] || [ "$HANG_LIMIT_SECS" -gt 87300 ]; }; then
  HANG_LIMIT_VALID=no
fi
if [ "$AI_TIMEOUT_VALID" != yes ] || [ "$HANG_LIMIT_VALID" != yes ]; then
  [ "$AI_TIMEOUT_VALID" = yes ] \
    || log "⚠️ SLEEP_WELL_AI_TIMEOUT 超出 1–86400 秒；本夜未开工"
  [ "$HANG_LIMIT_VALID" = yes ] \
    || log "⚠️ SLEEP_WELL_HANG_LIMIT 超出 1–87300 秒；本夜未开工"
  if [ -f "$STOP_FILE" ]; then
    # STOP is the emergency brake. Use bounded defaults only for its cleanup
    # path so an invalid plist value cannot strand an active run or hook.
    AI_TIMEOUT_SECS=1800
    HANG_LIMIT_SECS=2700
    log "STOP 已存在；仅为收尾采用安全超时默认值"
  else
    CONFIG_STATUS_LINE='- 状态: 未开工（没有活动运行）'
    CONFIG_ACTIVE_LINE='- 活动状态: 无'
    if [ -s "$STATE_DIR/current-run.json" ]; then
      CONFIG_STATUS_LINE='- 状态: 本跳未开工（配置错误）；本夜已有活动运行'
      CONFIG_ACTIVE_LINE='- 活动状态: 已保留；修复配置后下一跳继续，届时早报会重新渲染完整任务表'
    fi
    HOOK_HINT=""
    HOOK_REPORT_LINE=""
    if [ -f "$SW_RUNTIME_HOME/hook-recovery.json" ]; then
      HOOK_HINT='；另有 pre-push hook 待恢复，修复前 git push 可能被阻断'
      HOOK_REPORT_LINE='- 待处理: 存在未完成的 pre-push hook 恢复；修复配置前 git push 可能被阻断'
    fi
    CONFIG_REPORT_TMP="$SW_RUNTIME_HOME/morning-report.md.tmp.$$"
    { printf '# sleep-well-codex 早报\n\n';
      printf '%s\n' "$CONFIG_STATUS_LINE";
      printf -- '- 原因: SLEEP_WELL_AI_TIMEOUT/HANG_LIMIT 配置非法\n';
      printf '%s\n' "$CONFIG_ACTIVE_LINE";
      [ -z "$HOOK_REPORT_LINE" ] || printf '%s\n' "$HOOK_REPORT_LINE";
      printf -- '- 时间: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; } \
      >"$CONFIG_REPORT_TMP" 2>/dev/null \
      && chmod 600 "$CONFIG_REPORT_TMP" 2>/dev/null \
      && mv -f "$CONFIG_REPORT_TMP" "$SW_RUNTIME_HOME/morning-report.md" 2>/dev/null \
      || { rm -f "$CONFIG_REPORT_TMP" 2>/dev/null; log "⚠️ 配置错误早报写入失败"; }
    run_startup_bounded "非法超时告警" push_once invalid-timeout \
      "⚠️ 夜班未开工" \
      "SLEEP_WELL_AI_TIMEOUT/HANG_LIMIT 配置非法；本夜未开工${HOOK_HINT}" \
      || log "⚠️ 非法超时告警未在启动时限内完成"
    FINISHED=yes
    exit 1
  fi
else
  # A repaired configuration must be able to warn again if it later regresses.
  clear_push_once invalid-timeout
fi
# 不静默改写运维显式设的合法 AI 超时（原来 <60 一律抬到 60，于是 e2e
# 里设 5 实际跑的是 60，而那条「超时生效」断言仍会绿）。小于 60 只告警。
# 看门狗的两个新参数同样要校验（Codex R12 #5）: 非数值/0/负值会让 `sleep` 持续失败
# 变成烧 CPU 的空转循环，或让宽限期归零、TERM 刚发出就升级 KILL（EXIT trap 来不及跑）。
if WATCHDOG_POLL_SECS="$(normalize_decimal "$WATCHDOG_POLL_SECS")" \
   && [ "${#WATCHDOG_POLL_SECS}" -le 18 ]; then :; else
  log "⚠️ WATCHDOG_POLL 非法，回落 30"; WATCHDOG_POLL_SECS=30
fi
[ "$WATCHDOG_POLL_SECS" -lt 1 ] \
  && { log "⚠️ 看门狗轮询 ${WATCHDOG_POLL_SECS}s 过小，抬到 1"; WATCHDOG_POLL_SECS=1; }
[ "$WATCHDOG_POLL_SECS" -gt 300 ] \
  && { log "⚠️ 看门狗轮询 ${WATCHDOG_POLL_SECS}s 过大，压到 300"; WATCHDOG_POLL_SECS=300; }
if WATCHDOG_GRACE_SECS="$(normalize_decimal "$WATCHDOG_GRACE_SECS")" \
   && [ "${#WATCHDOG_GRACE_SECS}" -le 18 ]; then :; else
  log "⚠️ WATCHDOG_GRACE 非法，回落 30"; WATCHDOG_GRACE_SECS=30
fi
[ "$WATCHDOG_GRACE_SECS" -lt 3 ] && { log "⚠️ 看门狗宽限期 ${WATCHDOG_GRACE_SECS}s 过短，抬到 3"; WATCHDOG_GRACE_SECS=3; }
[ "$WATCHDOG_GRACE_SECS" -gt 300 ] \
  && { log "⚠️ 看门狗宽限期 ${WATCHDOG_GRACE_SECS}s 过大，压到 300"; WATCHDOG_GRACE_SECS=300; }
[ "$AI_TIMEOUT_SECS" -lt 60 ] && log "注意: AI 超时设为 ${AI_TIMEOUT_SECS}s，偏小"
if [ "$HANG_LIMIT_SECS" -le "$AI_TIMEOUT_SECS" ]; then
  HANG_LIMIT_SECS=$((AI_TIMEOUT_SECS + 900))
  log "⚠️ 挂起阈值须大于 AI 超时，已抬到 ${HANG_LIMIT_SECS}s"
fi
# 残留的 active-pgid 只可能来自已死的上一次运行——留着会让看门狗对已复用的号发信号
rm -f "$ACTIVE_PGID_FILE" 2>/dev/null
beat
start_watchdog
# A node-specific pause marker must survive repeated unavailable ticks, but it
# must not silence a different hook-conflict or terminal alert after node heals.
if command -v node >/dev/null 2>&1 \
   && node -e 'process.exit(0)' >/dev/null 2>&1; then
  clear_push_once node-paused
fi
# 恢复失败**必须中止本跳**（Codex R8 #7）: 原来只记日志就继续，后续 guard_install
# 会写新的阻断 hook 并覆盖恢复记录，把仍然存在的旧备份变成永久孤儿。
# 状态文件保留着，下一跳会再试；人工修好后它自然通过。
HOOK_RECOVERY_RC=0
recover_pending_hook || HOOK_RECOVERY_RC=$?
case "$HOOK_RECOVERY_RC" in
  0) ;;
  2)
    if [ -f "$STOP_FILE" ]; then
      if [ -s "$STATE_DIR/current-run.json" ]; then
        finish_without_run "STOP 已生效；缺少依赖: node，恢复材料未处理" \
          "STOP 存在且 node 不可用；hook 恢复材料与活动状态原样保留" \
          "⚠️ 需要手动处理" 1 \
          "STOP 已生效；活动状态与 hook 恢复材料未处理，请检查本机状态与目标仓库"
      fi
      finish_without_run \
        "STOP 已生效；缺少依赖: node，没有活动运行；hook 恢复材料未处理" \
        "STOP 存在且 node 不可用；没有活动运行，hook 恢复材料原样保留" \
        "⚠️ 需要手动处理" 1 \
        "STOP 已生效；hook 恢复材料未处理，本夜不会自动重试；修复后请 terminal-clear 并重新 load"
    fi
    if [ -s "$STATE_DIR/current-run.json" ]; then
      finish_without_run "缺少依赖: node" \
        "node 不可用，无法解析 hook 恢复元数据；恢复材料已保留" \
        "⚠️ 夜班暂停" 1 \
        "缺少依赖: node；活动状态与 pre-push hook 恢复材料已保留，下一跳重试" \
        yes node-paused
    fi
    finish_without_run \
      "缺少依赖: node；pre-push hook 恢复材料已保留；本夜不会自动重试，修复后请 terminal-clear 并重新 load" \
      "node 不可用且没有活动运行；恢复材料原样保留，本夜终止" \
      "⚠️ 夜班未开工" 1 \
      "缺少依赖: node；pre-push hook 恢复材料已保留，本夜不会自动重试；修复后请 terminal-clear 并重新 load" ;;
  *)
    finish_without_run "pre-push hook 待人工恢复" \
      "hook 恢复未完成——本夜停止，保留恢复材料待人工处理" \
      "⚠️ 需要手动处理" 1 "pre-push hook 未恢复；详情见本机日志" ;;
esac
# 依赖预检: 缺什么就说缺什么，不要等到某个子步骤失败后报一个指错方向的原因
# >>>TESTABLE:preflight>>>
PREFLIGHT_DETAIL=""
PREFLIGHT_PUBLIC_MISSING=""
preflight_deps() {
  local missing="" public_missing=""
  local user_codex_home="${SW_USER_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}"
  if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(0)' >/dev/null 2>&1; then
    missing="${missing} node"
    public_missing="${public_missing} node"
  fi
  for b in git realpath shasum xargs ps link; do
    if ! command -v "$b" >/dev/null 2>&1; then
      missing="${missing} ${b}"
      public_missing="${public_missing} ${b}"
    fi
  done
  if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
    missing="${missing} codex(${CODEX_BIN})"
    public_missing="${public_missing} codex"
  fi
  if [ ! -r "$user_codex_home/auth.json" ]; then
    missing="${missing} codex-auth(${user_codex_home}/auth.json)"
    public_missing="${public_missing} codex-auth"
  fi
  if [ ! -x "$REVIEW_SH" ]; then
    missing="${missing} claude-handoff(${REVIEW_SH})"
    public_missing="${public_missing} claude-handoff"
  fi
  local prompt_rel
  for prompt_rel in prompts/implement.md prompts/fix.md; do
    if [ ! -r "$SKILL_DIR/$prompt_rel" ] || [ ! -s "$SKILL_DIR/$prompt_rel" ]; then
      missing="${missing} ${prompt_rel}"
      public_missing="${public_missing} skill-prompts"
    fi
  done
  if [ -n "$missing" ]; then
    PREFLIGHT_DETAIL="$missing"
    PREFLIGHT_PUBLIC_MISSING="$public_missing"
    log "⚠️ 缺少依赖:${missing}（PATH=${PATH}）"
    return 1
  fi
  return 0
}
# <<<TESTABLE:preflight<<<

# STOP is the user's emergency brake and must work even when a dependency is missing.
if [ -f "$STOP_FILE" ]; then
  if [ -s "$STATE_DIR/current-run.json" ]; then
    if command -v node >/dev/null 2>&1 \
       && node -e 'process.exit(0)' >/dev/null 2>&1; then
      finalize "见到 STOP 文件"
    fi
    # The activity exists even though node is unavailable. Preserve it and say
    # so; claiming "没有活动运行" would hide possible repository residue.
    finish_without_run "STOP 已生效；活动状态因缺少 node 未能归档" \
      "STOP 存在且检测到活动状态，但 node 不可用；状态原样保留待人工核对" \
      "⚠️ 需要手动处理" 1 \
      "STOP 已生效；活动状态未归档，请检查本机状态文件与目标仓库"
  fi
  finish_without_run "STOP 已生效；没有活动运行" "STOP 存在且没有可收尾的活动状态"
fi

# An existing run must still honor its morning cutoff before dependency checks.
if command -v node >/dev/null 2>&1 && [ -s "$STATE_DIR/current-run.json" ] \
   && [ "$(jq_get "$(cli_json cutoff-passed || echo '{}')" passed || echo false)" = true ]; then
  finalize "到达 cutoff"
fi

if ! preflight_deps; then
  case "$PREFLIGHT_PUBLIC_MISSING" in
    *node*)
      if [ -s "$STATE_DIR/current-run.json" ]; then
        finish_without_run \
          "缺少依赖:${PREFLIGHT_PUBLIC_MISSING}；本夜已有活动运行且未归档" \
          "缺少依赖:${PREFLIGHT_DETAIL}（PATH=${PATH}）；活动状态原样保留" \
          "⚠️ 夜班暂停" 1 \
          "缺少依赖:${PREFLIGHT_PUBLIC_MISSING}；活动状态未归档，请检查本机状态文件与目标仓库" \
          yes node-paused
      fi ;;
  esac
  finish_without_run "缺少依赖:${PREFLIGHT_PUBLIC_MISSING}" "缺少依赖:${PREFLIGHT_DETAIL}（PATH=${PATH}）"
fi
# Migrate/clear the older generic pause marker once all dependency probes pass.
clear_push_once finish-without-run
require_realpath \
  || finish_without_run "realpath 不可用" "realpath 能力检查失败"
log "=== 取得锁，开工（pid $$，AI 超时 ${AI_TIMEOUT_SECS}s / 挂起阈值 ${HANG_LIMIT_SECS}s）==="
HAD_ACTIVE_STATE=no
[ -s "$STATE_DIR/current-run.json" ] && HAD_ACTIVE_STATE=yes
INIT_ERR="$(node "$CLI" init 2>&1 >/dev/null)"; INIT_RC=$?
if [ $INIT_RC -ne 0 ]; then
  finish_without_run "队列或配置无效" "${INIT_ERR:-队列为空或不存在}"
fi

# Guard baselines live in the orchestrator process. If an earlier process died
# after an AI write but before its post-call verification, automatically
# resuming an in-flight task would absorb that unverified content as a new
# baseline. Quarantine only persisted in-flight tasks; pending work can proceed.
if [ "$HAD_ACTIVE_STATE" = yes ]; then
  QUARANTINE_JSON="$(cli_json quarantine-inflight)" \
    || finish_without_run "状态恢复不可验证" "无法隔离上一进程的在途任务"
  QUARANTINE_N="$(jq_get "$QUARANTINE_JSON" count)" \
    || finish_without_run "状态恢复不可验证" "无法读取在途任务隔离结果"
  QUARANTINE_GRACEFUL="$(jq_get "$QUARANTINE_JSON" graceful)" \
    || finish_without_run "状态恢复不可验证" "无法读取上一跳退出证明"
  if [ "$QUARANTINE_GRACEFUL" = true ]; then
    log "已验证上一进程为计划内跳退出；保留在途任务供本跳续跑"
  elif [ "$QUARANTINE_N" -gt 0 ]; then
    log "已隔离上一进程遗留的 ${QUARANTINE_N} 个在途任务 → needs_human（不重建护栏基线）"
    push "⚠️ 需要拍板" "上一进程中断；${QUARANTINE_N} 个在途任务未自动续跑，以免吸收未核验改动"
  fi
fi

# cutoff 必须在退避之前判（Codex R2 #14）: 否则退避期跨过早晨，夜班不会按时收工出早报。
if [ "$(jq_get "$(cli_json cutoff-passed || echo '{}')" passed || echo false)" = true ]; then
  finalize "到达 cutoff"
fi
# 隔离 CODEX_HOME 必须在任何 codex 调用之前备妥；备不出来就不开工
prepare_codex_home \
  || finish_without_run "隔离运行环境不可用" \
       "prepare_codex_home 失败（详见前序日志）" \
       "⚠️ 夜班未开工" 1 "隔离运行环境不可用；详情见本机日志"

# 退避未到点则本跳直接退出（Codex R1 #7: 原实现算了 hops 却不等，5 分钟后照常重试）
if [ "$(jq_get "$(cli_json retry-due || echo '{}')" due || echo true)" != true ]; then
  log "退避未到点，本跳退出"; graceful_hop_exit "退避未到点"
fi
# ⚠️ 顺序（Codex R2 #6）: 必须**先**按已持久化的可用性判一次 halt，再重置。
# 直接重置会把上一跳记录的 auth 抹掉，认证失效永远走不到 halt。
av0="$(cli_json availability-get || echo '{}')"
hop0="$(cli_json decide-hop "$(jq_get "$av0" claude || echo ok)" "$(jq_get "$av0" codex || echo ok)" || echo '{}')"
ACT0="$(jq_get "$hop0" action || echo work)"
if [ "$ACT0" = halt ]; then
  finalize "$(jq_get "$hop0" reason || echo '需人工介入')"
fi
# 只有「两侧都记为 ok」或「上一跳是 idle（等的就是恢复）」才重置。
# defer-review / fix-only 表示某一侧仍不可用且中继正在进行中——直接重置会把中继状态
# 抹掉，退避与挂起全部失效（Codex R3 #8）。
case "$ACT0" in
  work|idle) node "$CLI" availability-reset >/dev/null 2>&1 ;;
  *) log "保留中继状态（${ACT0}），不重置可用性" ;;
esac

CONSEC_UNAVAIL_ID=""; CONSEC_UNAVAIL_N=0
while :; do
  beat
  [ -f "$STOP_FILE" ] && finalize "见到 STOP 文件"
  [ "$(jq_get "$(cli_json cutoff-passed || echo '{}')" passed || echo false)" = true ] && finalize "到达 cutoff"

  av="$(cli_json availability-get)" || hop_fail "读可用性失败（状态可能损坏）"
  hop="$(cli_json decide-hop "$(jq_get "$av" claude || echo ok)" "$(jq_get "$av" codex || echo ok)")" \
    || hop_fail "中继判定失败"
  # ⚠️ 四个 action 必须都落到行为上（Codex R12 范围外提醒，我连着两轮点名让他查这条链）:
  #    原来 case 只处理 halt/idle，`defer-review` 与 `fix-only` 只存在于注释里——
  #    于是 SKILL.md 承诺的「Codex 额度耗尽 → 不取新任务」**根本没有实现**，
  #    主循环照样取新任务并去调那个已知不可用的一侧。额度中继是用户点名的三大功能之一。
  HOP_MODE=work
  case "$(jq_get "$hop" action)" in
    halt) finalize "$(jq_get "$hop" reason || echo '需人工介入')" ;;
    fix-only)     HOP_MODE=fix-only;     log "codex 不可用: 本跳不取新任务" ;;
    defer-review) HOP_MODE=defer-review; log "claude 不可用: 本跳跳过审查，挂起待重试" ;;
    idle)
      log "两侧均不可用: $(jq_get "$hop" reason || echo '')"
      bo="$(cli_json backoff-schedule)" || hop_fail "退避排期失败"
      [ "$(jq_get "$bo" giveUp || echo false)" = true ] && finalize "退避耗尽（约 3 小时重试无果）"
      log "排期 $(jq_get "$bo" hops) 跳后重试"; graceful_hop_exit "两侧不可用，等待退避" ;;
  esac

  nt="$(cli_json next-task)" || hop_fail "取任务失败（状态可能损坏）"
  tid="$(jq_get "$nt" taskId)" || hop_fail "无法读取 next-task.taskId（状态可能损坏）"
  # fix-only: 只把在途任务推完，绝不开新的（开了也只会去调不可用的 codex）
  if [ -n "$tid" ] && [ "$HOP_MODE" = fix-only ] \
     && [ "$(jq_get "$nt" task.status || echo pending)" = pending ]; then
    log "codex 不可用且下一个是新任务，本跳不开工"
    bo="$(cli_json backoff-schedule)" || hop_fail "退避排期失败"
    [ "$(jq_get "$bo" giveUp || echo false)" = true ] && finalize "退避耗尽（codex 长时间不可用）"
    graceful_hop_exit "Codex 不可用，不取新任务"
  fi
  if [ -z "$tid" ]; then
    if [ "$(jq_get "$nt" deferred || echo false)" = true ]; then
      # 退避已到点（能走到这里说明 retry-due 判过了），且上面的 availability-reset
      # 已清空 reviewDeferred——若仍为 true 说明 reset 没跑到（中继态被保留）。
      # 此时必须**主动解除**一次，否则挂起的审查永远等不到重试（Codex R4 #2）。
      log "存在挂起的审查，解除挂起以便下一跳重试"
      node "$CLI" availability-reset >/dev/null 2>&1
      bo="$(cli_json backoff-schedule)" || hop_fail "退避排期失败"
      [ "$(jq_get "$bo" giveUp || echo false)" = true ] && finalize "退避耗尽"
      graceful_hop_exit "挂起审查等待下一跳"
    fi
    if [ "$(jq_get "$nt" blockedBySameRepo || echo false)" = true ]; then
      log "同仓库串行阻塞，排退避后退出"
      bo="$(cli_json backoff-schedule)" || hop_fail "退避排期失败"
      [ "$(jq_get "$bo" giveUp || echo false)" = true ] && finalize "退避耗尽"
      graceful_hop_exit "同仓库串行阻塞"
    fi
    finalize "队列已清空"
  fi

  if ! task_repo="$(jq_get "$nt" task.repo)" || ! task_status="$(jq_get "$nt" task.status)"; then
    hop_fail "任务状态缺少 repo/status（状态可能损坏）"
  fi
  process_task "$tid" "$task_repo" "$task_status" \
               "$(jq_get "$nt" task.prompt || echo '')" "$(jq_get "$nt" task.title || echo "$tid")"
  rc=$?
  case $rc in
    2) # 「一跳一直工作到收工」意味着**单侧故障不该结束本跳**（Codex R13 符合性扫查）:
       # 原来 rc=2 直接退出，于是 claude 打一个嗝就白等 5 分钟——而 defer-review /
       # fix-only 补实现之后，下一轮迭代本来就能接管（claude 挂了继续实现别的任务，
       # codex 挂了只推在途的）。这里改为继续循环。
       # 但要防热转: 同一个任务连着两次因可用性中断，说明中继接管不了它，排退避退出。
       if [ "$tid" = "$CONSEC_UNAVAIL_ID" ]; then
         CONSEC_UNAVAIL_N=$((CONSEC_UNAVAIL_N + 1))
       else
         CONSEC_UNAVAIL_ID="$tid"; CONSEC_UNAVAIL_N=1
       fi
       # ⚠️ 退避档位只在**真正退出本跳**时推进（Codex R14 #2）: 原来每次 rc=2 都排一次，
       #    于是「失败→continue→再失败→退出」一跳就吃掉两档，约 3 小时的容错缩到约 110 分钟。
       if [ "$CONSEC_UNAVAIL_N" -ge 2 ]; then
         bo="$(cli_json backoff-schedule)" || hop_fail "退避排期失败"
         [ "$(jq_get "$bo" giveUp || echo false)" = true ] && finalize "退避耗尽（约 3 小时重试无果）"
         log "[$tid] 连续两次因可用性中断，排退避后退出本跳"
         graceful_hop_exit "连续可用性中断，等待退避"
       fi
       log "[$tid] 可用性中断，本跳继续（中继模式会接管）"
       continue ;;
    3) finalize "${GUARD_ABORT_REASON:-护栏不可得}，中止整夜" ;;
    4) hop_fail "任务状态无法可靠推进（状态读写失败）" ;;
    *) # 成功推进即清零连续失败计数（Codex R14 #4）: 原来只在任务 ID 变化时重置，
       # 于是「同一任务先中断一次、重试成功、再遇一次中断」会被误判成「连续两次」而结束本跳。
       CONSEC_UNAVAIL_ID=""; CONSEC_UNAVAIL_N=0
       node "$CLI" backoff-clear >/dev/null 2>&1 ;;
  esac
done
