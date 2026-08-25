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

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SELF_DIR/.." && pwd)"
CLI="$SKILL_DIR/lib/cli.mjs"
REVIEW_SH="${SLEEP_WELL_CLAUDE_REVIEW:-$HOME/.codex/skills/claude-handoff/scripts/claude-code-review.sh}"

ROOT="${SLEEP_WELL_ROOT:-$HOME/sleep-well}"
CODEX_HOME="$ROOT/codex"
CODEX_HOME_OVERRIDE=""
STATE_DIR="$CODEX_HOME/state"
LOG_DIR="$CODEX_HOME/logs"
LOCK="$ROOT/NIGHT.lock"
STOP_FILE="$ROOT/STOP"
HEARTBEAT="$STATE_DIR/heartbeat"
CONFIG="$CODEX_HOME/config.json"
CODEX_BIN="${SLEEP_WELL_CODEX:-codex}"
PLIST_LABEL="com.user.sleepwell-codex"
# 心跳停滞多久算「持有者挂了」。必须大于单次 AI 调用超时，否则正常的长调用会被误判接管。
HANG_LIMIT_SECS="${SLEEP_WELL_HANG_LIMIT:-2700}"
# 看门狗轮询间隔与终止宽限期。参数化是为了**能被测试**——连续三轮的看门狗缺陷
# （R8 死代码 / R10 打错进程组 / R11 跳过编排器自己）没有一条被测试抓住，
# 根因就是没有一个测试真的让看门狗去杀一个卡死的编排器。
WATCHDOG_POLL_SECS="${SLEEP_WELL_WATCHDOG_POLL:-30}"
WATCHDOG_GRACE_SECS="${SLEEP_WELL_WATCHDOG_GRACE:-30}"

# ⚠️ launchd 下的 PATH 不能指望登录 shell（2026-08-16 实测: 这台机器上 `/bin/bash -lc`
#    的 PATH 里**没有** codex 也没有 claude——它们在 ~/.local/bin，而那个目录是交互式
#    rc 文件加的）。plist 的注释曾写着「-lc 走登录 shell，保证 PATH 里有 codex/claude/node」，
#    那个假设是假的: 真实后果是 `codex mcp list` 返回 127，整夜每 5 分钟一次「拒绝开工」。
#    这里显式补上常见位置，nvm 的当前版本也补上。
# ⚠️ **追加**而不是前置: 前置会盖过调用方 PATH 里的选择（实测直接把 e2e 的影子
#    二进制顶掉了；对真实用户就是「我明明指定了那个 codex，它却用了别的」）。
#    这些只是**缺失时的兜底**，既有 PATH 永远优先。
for _d in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin; do
  [ -d "$_d" ] && PATH="$PATH:$_d"
done
if [ -d "$HOME/.nvm/versions/node" ]; then
  for _nb in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$_nb" ] && PATH="$PATH:$_nb"; done
fi
export PATH

mkdir -p "$LOG_DIR" "$STATE_DIR" || exit 1
RUNLOG="$LOG_DIR/orchestrator-$(date '+%Y-%m-%d').log"
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$RUNLOG"; }

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
if [ -f "$CONFIG" ]; then NTFY_TOPIC="$(jq_get "$(cat "$CONFIG")" ntfy_topic || true)"; fi
push() {
  log "PUSH[$1] $2"
  [ -z "$NTFY_TOPIC" ] && return 0
  # topic 未校验就拼进 URL 会静默改变端点（`a/../../evil`、`a?priority=5`）——
  # 来源是用户自己的 config.json，所以是配置错误而非攻击面，但错了会推到别处而无人知晓。
  case "$NTFY_TOPIC" in
    *[!A-Za-z0-9_-]*|'') log "⚠️ ntfy_topic 含非法字符（只允许 A-Za-z0-9_-），本次不推送"; return 0 ;;
  esac
  # 只推任务标题与状态——绝不推代码片段、路径、findings 正文（ntfy 是公开服务）
  # spec 写明「每条 ≤200 字符」，但代码里一直没有截断（R13 符合性扫查）。
  # 任务标题来自 queue.md，长标题会让推送正文远超这个上限。
  curl -fsS --max-time 10 -H "Title: $(printf '%.60s' "$1")" -d "$(printf '%.200s' "$2")" \
    "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 \
    || log "PUSH 失败（已忽略）"
}

# ── 锁 ────────────────────────────────────────────────────────────────
HAVE_LOCK=no
_write_owner() { printf '%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | tr -s ' ')" >"$LOCK/owner"; }
acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    _write_owner; HAVE_LOCK=yes; return 0
  fi
  local pid started
  pid="$(sed -n 1p "$LOCK/owner" 2>/dev/null)"
  started="$(sed -n 2p "$LOCK/owner" 2>/dev/null)"
  # PID 会被复用（重启后尤其常见）——只判 kill -0 会把无关的长寿进程当成锁持有者，
  # 于是每次启动都退出、永远不开工且无告警（Codex R4 #15）。加进程启动时间比对。
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
     && [ "$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ')" = "$started" ]; then
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
    rm -rf "$stale"
    log "已移除陈旧锁（原持有者 pid ${pid:-未知} 不存在）"
    if mkdir "$LOCK" 2>/dev/null; then
      _write_owner; HAVE_LOCK=yes; return 0
    fi
  fi
  log "陈旧锁接管竞争失败，本跳退出"; return 1
}
release_lock() { [ "$HAVE_LOCK" = yes ] && rm -rf "$LOCK"; }

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
#     但 R13 改了顺序之后 sweep 已无生产调用者，那句话与实际行为矛盾）。
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
_kill_tree() {
  local p="$1" sig="$2" skip="${3:-}"
  [ -n "$p" ] || return 0
  [ "$p" = "$skip" ] && return 0
  _kill_descendants "$p" "$skip"
  kill -"$sig" "$p" 2>/dev/null
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
      #    所以这一条是**已知残留**，写进 SKILL.md 而不是假装解决了。
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
  #    而 launchd 把 stderr 写进 /tmp/sleepwell-codex.err。刚修完误导性诊断，
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
  push "⚠️ 夜班异常退出" "$1"
  FINISHED=yes
  exit 1
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
  stop_watchdog
  rm -f "$ACTIVE_PGID_FILE" 2>/dev/null
  release_lock
}
trap on_exit EXIT

# ── 收工 ──────────────────────────────────────────────────────────────
# 顺序很重要（Codex R1 #2/#18）: 先把终止状态写进 state 让早报看到「已收工」而不是
# 「运行中」，再出早报，再落 TERMINATED 标记 + 卸载 launchd，最后归档。
finalize() {
  local why="$1"
  log "收工: ${why}"
  # 持久化失败必须可见（Codex R3 #11）: 静默失败会让早报与 TERMINATED 状态互相矛盾
  node "$CLI" mark-terminal-in-state "$why" >/dev/null 2>&1 \
    || { log "⚠️ 终止状态写入失败"; push "⚠️ 夜班收工异常" "终止状态未能写入，请查看日志"; }
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
    push "☀️ 夜班早报" "共 ${total} 任务，完成 ${done_n}${nh:+；待拍板 ${nh}}。收工原因: ${why}"
  else
    push "⚠️ 早报生成失败" "夜班已收工（${why}），但早报未能生成，请查看 logs/ 与各仓库 git log"
  fi
  # 顺序: 归档 → 落终止标记 → 最后才自卸载（Codex R2 #13: 先卸载可能打断归档）
  # 归档失败就不落 TERMINATED、不卸载（Codex R4 #14）: 否则状态既没归档又被标终止，
  # 下一夜 init 会看到残留的活动状态而行为不明。留着让下一跳重试收工。
  if ! node "$CLI" archive >/dev/null 2>&1; then
    log "⚠️ 归档失败——不落终止标记，下一跳重试收工"
    push "⚠️ 夜班收工异常" "归档失败，将在下次触发重试"
    guard_uninstall 2>/dev/null || true
    FINISHED=yes; exit 1
  fi
  node "$CLI" terminal-set "${why}" >/dev/null 2>&1 \
    || { log "⚠️ TERMINATED 标记写入失败——下一跳可能重跑整夜"; push "⚠️ 夜班收工异常" "终止标记未写入"; }
  if ! guard_uninstall; then
    # hook 还没还回去就卸载 = 永远没有下一跳来重试（Codex R6 #4）
    log "⚠️ hook 未恢复，不卸载 launchd，留待下一跳重试"
    push "⚠️ 需要注意" "你的 pre-push hook 尚未恢复，夜班保持挂载以便重试"
    FINISHED=yes; exit 1
  fi
  launchctl unload "$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist" 2>/dev/null \
    && log "已自卸载 launchd" || log "launchd 卸载跳过（可能未安装）"
  FINISHED=yes
  exit 0
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
HOOK_STATE="$CODEX_HOME/hook-recovery.json"

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
  raw="$(cat "$HOOK_STATE" 2>/dev/null)" || {
    log "⚠️ hook 恢复元数据不可读，拒绝继续"; push "⚠️ 需要手动处理" "hook 恢复元数据不可读"; return 1; }
  # 解析失败**不等于**无需恢复（R8 #9）: 原实现把 jq_get 的失败折叠成空串然后删掉记录，
  # 于是既留下了阻断 hook，又丢掉了定位用户备份的唯一线索。
  hp="$(jq_get "$raw" hook)" || hp=""
  bk="$(jq_get "$raw" backup)" || bk=""
  tok="$(jq_get "$raw" token)" || tok=""
  if [ -z "$hp" ]; then
    log "⚠️ hook 恢复元数据损坏（保留原文件待人工处理）: $(printf '%.120s' "$raw")"
    push "⚠️ 需要手动处理" "hook 恢复元数据损坏，夜班拒绝继续"
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
      push "⚠️ 需要手动处理" "pre-push hook 仍未恢复，备份见日志"
      return 1
    fi
    # 用户在崩溃后自己换了 hook——两份都留着，交人工（R8 #10）
    log "⚠️ 当前 pre-push 不是夜班装的，且备份仍在: 冲突，两份都保留待人工"
    push "⚠️ 需要手动处理" "pre-push 冲突: 现有文件与夜班备份并存，未做任何覆盖"
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
        log "⚠️ 无法移除遗留的夜班 hook: ${hp}"; push "⚠️ 需要手动处理" "遗留的夜班 hook 未能移除"; return 1; }
    elif [ -e "$hp" ]; then
      # 无 token 的旧记录（R9 → R10 升级）: 用旧版哨兵体做一次性识别，认出来就清掉。
      if [ -z "$tok" ] && _hook_is_legacy_ours "$hp"; then
        log "识别出 R9 时代的夜班 hook（无 token 记录），已移除"
        rm -f "$hp" 2>/dev/null || {
          log "⚠️ 无法移除遗留的夜班 hook: ${hp}"; push "⚠️ 需要手动处理" "遗留的夜班 hook 未能移除"; return 1; }
      else
        # 既不是本版的、也不是旧版的 —— 不认识就不动，更不能清掉唯一的记录
        log "⚠️ ${hp} 存在但无法确认归属，保留文件与恢复记录待人工"
        push "⚠️ 需要手动处理" "pre-push 归属不明，夜班未做任何改动"
        return 1
      fi
    fi
    _clear_hook_state; return 0
  fi

  # 记录过备份却找不到文件——绝不当成成功（R8 #12）。此时不动任何文件。
  log "⚠️ 恢复元数据记录了备份 ${bk} 但文件不存在，保留状态并中止"
  push "⚠️ 需要手动处理" "pre-push 备份文件缺失，夜班拒绝继续"
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

# 列出受保护文件（已跟踪 **+ 未跟踪未忽略**——Codex R2 #5: 原实现只看已跟踪，
# 新增的合同/凭据类文件漏检）。失败返回非零，调用方失败关闭（Codex R2 #4）。
#
# 「什么算受保护」**只有一处定义**: lib/guardrails.mjs 的 isProtectedPath，
# 经 `cli.mjs protected-in` 调用。本函数只负责枚举候选与摘要内容，不做任何模式判断。
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
  local d="$1" real_repo="$2" vis="$3" cnt="$4" out="" e rp n lst sub one id
  # ⚠️ visited 身份用 **dev:inode**，不用路径（Codex R11 #3）:
  #    路径写进按行分隔的文件，含换行的目录名会裂成多条——比如某个链接指向 `z\nfoo`，
  #    留下的 `/repo/z` 那行会让后来真实的 `/repo/z` 目录被误判成环而整个跳过，
  #    改它底下的文件护栏毫无反应。这是 R9 #3 那个「行协议」缺陷在我新写的代码里复发。
  #    dev:inode 天然无换行，还能识破硬链接与经不同路径到达的同一目录（实测 a 与 alink/ 同号）。
  id="$(stat -f '%d:%i' "$d" 2>/dev/null)" || return 1
  [ -n "$id" ] || return 1
  grep -qxF -- "$id" "$vis" 2>/dev/null && { printf 'CYCLE %s\n' "$id"; return 0; }
  printf '%s\n' "$id" >>"$vis" || return 1
  lst="$(mktemp)" || return 1
  find "$d" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | LC_ALL=C sort -z >"$lst" || { rm -f "$lst"; return 1; }
  while IFS= read -r -d '' e; do
    n="$(cat "$cnt" 2>/dev/null)" || { rm -f "$lst"; return 1; }
    n=$((n + 1)); printf '%s\n' "$n" >"$cnt"
    if [ "$n" -gt "$PROT_MAX_DIR_ENTRIES" ]; then
      log "护栏: 受保护目录展开超过 ${PROT_MAX_DIR_ENTRIES} 条，失败关闭"
      rm -f "$lst"; return 1
    fi
    if [ -L "$e" ]; then
      out="${out}L $(readlink "$e" 2>/dev/null) ${e}"$'\n'
      if rp="$(realpath "$e" 2>/dev/null)"; then
        case "$rp" in
          "$real_repo"|"$real_repo"/*)
            if [ -d "$rp" ]; then
              sub="$(_dir_digest "$rp" "$real_repo" "$vis" "$cnt")" || { rm -f "$lst"; return 1; }
              out="${out}${sub}"
            elif [ -f "$rp" ]; then
              one="$(shasum -a 256 "$rp" 2>/dev/null)" || { rm -f "$lst"; return 1; }
              out="${out}${one}"$'\n'
            else
              out="${out}NOT-A-REGULAR-FILE ${e}"$'\n'
            fi ;;
          *) out="${out}OUTSIDE-REPO ${e}"$'\n' ;;
        esac
      else
        out="${out}UNRESOLVABLE ${e}"$'\n'
      fi
    elif [ -d "$e" ]; then
      sub="$(_dir_digest "$e" "$real_repo" "$vis" "$cnt")" || { rm -f "$lst"; return 1; }
      out="${out}${sub}"
    elif [ -f "$e" ]; then
      one="$(shasum -a 256 "$e" 2>/dev/null)" || { rm -f "$lst"; return 1; }
      out="${out}${one}"$'\n'
    else
      out="${out}SPECIAL ${e}"$'\n'
    fi
  done <"$lst"
  rm -f "$lst"
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
  git -C "$repo" ls-files -z >"$lst" 2>/dev/null || { rm -f "$lst" "$exp"; return 1; }
  git -C "$repo" ls-files -z --others --exclude-standard >>"$lst" 2>/dev/null || { rm -f "$lst" "$exp"; return 1; }
  # ignored 用 --directory 折叠（性能: 不展开 node_modules 的十万个文件）
  git -C "$repo" ls-files -z --others --ignored --exclude-standard --directory >>"$lst" 2>/dev/null \
    || { rm -f "$lst" "$exp"; return 1; }

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
  #   20 万文件 find 全展开 0.20s + 20 万条过 protected-in 0.05s，整函数 0.33s。
  # 全展开不构成性能问题，所以正解是**删掉第二处模式集**，而不是给它补四条模式。
  # ⚠️ 整条管线必须是 **NUL 分隔**（Codex R9 #3，已实测）: git 允许文件名含换行，
  #    原来 `tr '\0' '\n'` 一上来就把 NUL 换成换行，`legal\nnotes.txt` 被拆成两条，
  #    权威判定看到的是并不存在的 `legal`，真实文件从头到尾没进过摘要——改它护栏毫无反应。
  #    所以: ls-files -z → find -print0 → protected-in --null → read -d ''，全程不落行协议。
  # ⚠️ 初始化与每一次追加都要检查（Codex R20 #1 报的是 `plain`，我复现时发现 `exp`
  #    上有同一个缺陷、而且从 R8 起就在）: 磁盘满/配额/只读时这些写入静默失败，
  #    随后的计数是从**这个空文件**算出来的——自洽但错误，结果是
  #    「退出码 0、stdout 零字节」的静默漏检（正常应为 185 字节）。实测复现过。
  : >"$exp" || { log "护栏: 无法初始化枚举列表（磁盘/配额？）"; rm -f "$lst" "$exp"; return 1; }
  local e exp_n=0
  while IFS= read -r -d '' e; do
    [ -z "$e" ] && continue
    if [ -d "$repo/$e" ]; then
      (cd "$repo" && find "$e" \( -type f -o -type l \) -print0 2>/dev/null) >>"$exp" || {
        log "护栏: 展开被忽略目录失败"; rm -f "$lst" "$exp"; return 1; }
      exp_n=$(( exp_n + $(tr -dc '\0' <"$exp" | wc -c | tr -d ' ') - exp_n ))
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

  local prot; prot="$(node "$CLI" protected-in --null "$exp" 2>/dev/null)" || { rm -f "$exp"; return 1; }
  rm -f "$exp"
  local pf; pf="$(mktemp)" || return 1
  printf '%s' "$prot" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{(JSON.parse(s).protected||[]).forEach(p=>process.stdout.write(p+"\0"))}catch{process.exit(1)}})' >"$pf" || { rm -f "$pf"; return 1; }

  # 可选: 把解析后的受保护清单导出给调用方（备份用）。NUL 分隔。
  [ -n "${PROT_LIST_OUT:-}" ] && cp "$pf" "$PROT_LIST_OUT" 2>/dev/null
  local real_repo; real_repo="$(cd "$repo" && pwd -P)" || return 1
  local plain plain_n=0
  plain="$(mktemp)" || return 1
  : >"$plain" || { rm -f "$plain"; return 1; }
  local f
  while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    if [ -L "$repo/$f" ]; then
      # 链接文本入摘要（R6 #5: 改指向即可绕过内容哈希）**并且**摘要它所指的内容
      # （R7 #3: `tmpstuff/.env -> payload` 时改 payload 不改链接文本，凭据修改绕过护栏）。
      local lt; lt="$(readlink "$repo/$f" 2>/dev/null)" || return 1
      h="${h}LINK ${lt} ${f}"$'\n'
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
              local tc; tc="$(shasum -a 256 "$real_tgt" 2>/dev/null)" || return 1
              h="${h}TARGET ${f} ${tc}"$'\n'
            elif [ -d "$real_tgt" ]; then
              # 指向目录时也要摘要目录内容（R8 #4），且必须**递归跟随内部的目录链接**
              # （R10 #2）——否则 `.env.dir -> data`、`data/nested -> ../target` 时
              # 改 target/ 里的文件毫无痕迹。_dir_digest 带 visited 防环、计数有界、
              # 任何读取失败即失败关闭（不再用 UNREADABLE 常量占位）。
              local vf cf dtc
              vf="$(mktemp)" || return 1
              cf="$(mktemp)" || { rm -f "$vf"; return 1; }
              printf '0\n' >"$cf"
              dtc="$(_dir_digest "$real_tgt" "$real_repo" "$vf" "$cf")" || { rm -f "$vf" "$cf"; return 1; }
              local dn; dn="$(cat "$cf" 2>/dev/null)" || dn="?"
              rm -f "$vf" "$cf"
              dtc="$(printf '%s' "$dtc" | shasum -a 256)" || return 1
              h="${h}TARGETDIR ${f} ${dn} ${dtc}"$'\n'
            else
              h="${h}TARGET ${f} NOT-A-REGULAR-FILE"$'\n'
            fi ;;
          *) h="${h}TARGET ${f} OUTSIDE-REPO"$'\n' ;;
        esac
      else
        # 悬空 / 成环: **记录状态**而不是静默跳过——夜里它变成有效文件时摘要必须变化
        h="${h}TARGET ${f} UNRESOLVABLE"$'\n'
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
    fi
  done <"$pf"
  rm -f "$pf"
  # ⚠️ 批量哈希（R19 自查）: R10 我为了「避免 xargs 分批影响结果」改成逐个 shasum，
  #    **没测过代价**。分批的顺序问题用 `sort` 就解决了，而逐个哈希的代价是每文件一次
  #    进程创建——一个 contracts/ 放了 1 万份文件的仓库，每次 guard_snapshot 要 81 秒，
  #    而 snapshot 与 verify 每个任务各跑一次。
  #    xargs 任一批失败返回 123/124/125，`|| return 1` 即失败关闭，不会静默少查。
  if [ -s "$plain" ]; then
    local bulk
    bulk="$(xargs -0 shasum -a 256 <"$plain" 2>/dev/null | LC_ALL=C sort)" || { rm -f "$plain"; return 1; }
    # 条数必须对得上，否则说明有文件被跳过（xargs 遇错会继续处理其余批次）
    # want 取自**计数器**而非文件——文件被截断时它自己数自己永远相符（R20 #1）
    local want got
    want="$plain_n"
    got="$(printf '%s\n' "$bulk" | grep -c . )" || got=0
    if [ "$want" != "$got" ]; then
      log "护栏: 批量哈希条数不符（期望 ${want} 实得 ${got}），失败关闭"
      rm -f "$plain"; return 1
    fi
    h="${h}${bulk}"$'\n'
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
  local repo="$1" abs="$2" root="$3" day="$4" rel sz
  rel="${abs#"$repo"/}"
  git -C "$repo" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && return 1
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
  local repo="$1" listf="$2" p sz n=0
  BACKUP_SKIPPED_N=0; BACKUP_FAILED_N=0
  local root="$CODEX_HOME/backups" day; day="$(date '+%Y-%m-%d')"
  # 上限值本身要校验（Codex R12 #9）: 非数值时整数比较失败、超大文件反而照备；
  # 负值则每个文件都跳过。两种都让「有界」这个承诺落空且无人知晓。
  case "$PROT_BACKUP_MAX_BYTES" in
    ''|*[!0-9]*) log "⚠️ SLEEP_WELL_BACKUP_MAX_BYTES 非法，回落 10485760"; PROT_BACKUP_MAX_BYTES=10485760 ;;
  esac
  [ "$PROT_BACKUP_MAX_BYTES" -lt 1024 ] && PROT_BACKUP_MAX_BYTES=1024

  local tgt real_repo
  real_repo="$(cd "$repo" && pwd -P)" || return 0
  while IFS= read -r -d '' p; do
    [ -z "$p" ] && continue
    if [ -L "$repo/$p" ]; then
      # ⚠️ 不能一律跳过链接（Codex R12 #3）: `.env -> config/runtime` 时护栏会跟随并
      #    保护 target，但 target 自身的路径不受保护、也进不了这个清单——
      #    于是 Codex 通过链接写入时，护栏检出了改动却**没有任何副本可还原**，
      #    正好是这次接线要解决的那个问题换了条路径。改为备份**解析后的仓库内目标**。
      tgt="$(realpath "$repo/$p" 2>/dev/null)" || continue
      case "$tgt" in "$real_repo"|"$real_repo"/*) : ;; *) continue ;; esac   # 仓库外不碰
      [ -f "$tgt" ] || continue
      _backup_one "$repo" "$tgt" "$root" "$day" && n=$((n+1))
      continue
    fi
    [ -f "$repo/$p" ] || continue
    _backup_one "$repo" "$repo/$p" "$root" "$day" && n=$((n+1))
  done <"$listf"
  [ "$n" -gt 0 ] && log "已备份 ${n} 份未跟踪的受保护文件"
  # 聚合成一条推送（Codex R16 #4）: 逐文件 push 会 N×10 秒 + 刷屏。
  if [ "$BACKUP_FAILED_N" -gt 0 ] || [ "$BACKUP_SKIPPED_N" -gt 0 ]; then
    push "⚠️ 部分受保护文件无备份" \
         "失败 ${BACKUP_FAILED_N} 份、超限跳过 ${BACKUP_SKIPPED_N} 份；护栏报警时这些文件无副本可还原（明细见日志）"
  fi
  return 0
}

guard_snapshot() {
  local repo="$1"
  GUARD_HEAD="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || { log "护栏快照失败: rev-parse"; return 1; }
  # 所有本地分支的位置——squash/ff merge 不产生提交，但会动 ref 或暂存区
  GUARD_REFS="$(git -C "$repo" for-each-ref refs/heads 2>/dev/null)" || { log "护栏快照失败: for-each-ref"; return 1; }
  local plist; plist="$(mktemp)" || { log "护栏快照失败: mktemp"; return 1; }
  GUARD_PROT="$(PROT_LIST_OUT="$plist" _prot_hash "$repo")" || {
    rm -f "$plist"; log "护栏快照失败: 受保护路径哈希"; return 1; }
  _backup_untracked_protected "$repo" "$plist"
  rm -f "$plist"
  return 0
}

guard_verify() {
  local repo="$1"
  # ① Codex 回合内不得有新提交（覆盖普通 merge 与野生 commit）
  # rev-list 失败（坏 sha、仓库损坏）会让 wc -l 得到 0 → 被当成「没有新提交」而放行。
  # 必须先判命令本身成功（Codex R3 #6）。
  local rl; rl="$(git -C "$repo" rev-list "${GUARD_HEAD}..HEAD" 2>>"$RUNLOG")" || {
    log "护栏核验失败: rev-list 出错"; push "🚨 护栏核验失败" "无法核验提交，夜班已中止"; return 1; }
  local n; n="$(printf '%s' "$rl" | grep -c . || true)"
  if [ "${n:-0}" -gt 0 ]; then
    log "护栏违规: Codex 回合内出现 ${n} 个新提交"; push "🚨 护栏违规" "检出未授权提交，夜班已中止"; return 1
  fi
  # ② squash / ff merge 不产生提交（Codex R2 #3，我已复现: --squash 后新提交数为 0
  #    而暂存区已被改，编排器随后的 add -A 会把 merge 内容当成任务产出提交）。
  #    靠三个残留标记 + 本地 ref 位置比对来抓。
  local gd; gd="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)" || { log "护栏核验失败: 无法解析 git-dir"; return 1; }
  case "$gd" in /*) : ;; *) gd="$repo/$gd" ;; esac
  for m in SQUASH_MSG MERGE_HEAD MERGE_MSG; do
    if [ -e "$gd/$m" ]; then
      log "护栏违规: 检出 .git/${m}（squash 或未完成的 merge）"
      push "🚨 护栏违规" "检出 merge 痕迹，夜班已中止"; return 1
    fi
  done
  local br_now; br_now="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$repo" rev-parse HEAD 2>/dev/null)"
  if [ "$br_now" != "$GUARD_BRANCH" ]; then
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
    log "护栏违规: 本地分支引用发生变化（ff-merge / reset / 建删分支）"
    push "🚨 护栏违规" "检出分支引用变动，夜班已中止"; return 1
  fi
  # ③ 受保护路径内容
  local prot_now; prot_now="$(_prot_hash "$repo")" || { log "护栏核验失败: 受保护路径哈希不可得"; push "🚨 护栏核验失败" "无法核验受保护文件，夜班已中止"; return 1; }
  if [ "$prot_now" != "$GUARD_PROT" ]; then
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
# 这很重要: 用户的 node_repl 与 github（带 PAT）两个 MCP 是 enabled 状态，
# 无人值守时它们就是现成的外带与 push 通道。
SW_CODEX_HOME="$CODEX_HOME_OVERRIDE"
prepare_codex_home() {
  SW_CODEX_HOME="$CODEX_HOME/codex-home"
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
  ln -sfn "$HOME/.codex/auth.json" "$SW_CODEX_HOME/auth.json" || return 1
  # 自检: 确认该 home 下确实没有 MCP。**探测本身失败也要拒绝开工**（Codex R5 #7）——
  # 原写法只看 grep 结果，探测命令出错时输出为空，反而被当成「没有 MCP」放行。
  # ⚠️ 诊断必须说实话（2026-08-16 实测教训）: 这条原来无论什么原因失败都报
  #    「MCP 隔离自检执行失败」。真实情况是 `codex` 根本不在 PATH 里（127），
  #    而日志把人指向「MCP 未能清空」——整夜八小时的日志指错了方向。
  #    先分开判「命令在不在」与「输出对不对」。
  if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
    log "⚠️ 找不到 codex 可执行文件（PATH=${PATH}），拒绝开工"
    push "⚠️ 夜班未开工" "找不到 codex 命令，请检查 PATH"
    return 1
  fi
  local probe probe_rc
  probe="$(CODEX_HOME="$SW_CODEX_HOME" "$CODEX_BIN" mcp list 2>&1)"; probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    log "⚠️ codex mcp list 退出码 ${probe_rc}，拒绝开工: $(printf '%.200s' "$probe")"
    push "⚠️ 夜班未开工" "MCP 自检命令失败（退出码 ${probe_rc}）"
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
  ( cd "$repo" && CODEX_HOME="$SW_CODEX_HOME" "$CODEX_BIN" exec --skip-git-repo-check \
      -s workspace-write -c sandbox_workspace_write.network_access=false \
      "$body" ) </dev/null >"$outfile" 2>&1
}

# 统一的「调用 codex 并处置结果」（Codex R14 #1 推荐）: 三个调用点各写一遍的结果是
# 我 R13 只修了两处、**又漏掉普通修复路径**，护栏洞在同一轮里没修干净。
# 约定: 返回 0=成功（已写恢复证据、已过护栏核验）; 2=该侧不可用; 3=护栏违规。
codex_step() {
  local repo="$1" body="$2" outfile="$3" id="$4" what="$5"
  run_codex "$repo" "$body" "$outfile"
  local rc=$? kind
  kind="$(jq_get "$(node "$CLI" classify "$outfile" "$rc" codex)" kind || echo other)"
  if [ "$kind" != ok ]; then
    log "[$id] ${what}codex 不可用: ${kind}"
    # ⚠️ 失败也要核验（R13 符合性扫查）: codex 可能在失败前已经动过受保护文件，
    #    那份改动没人检出，下一跳 guard_snapshot 会把它当成新基线，从此再也发现不了。
    if ! guard_verify "$repo"; then
      node "$CLI" availability-set codex "$kind" >/dev/null 2>&1
      return 3
    fi
    node "$CLI" availability-set codex "$kind" >/dev/null 2>&1
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
  #   -c mcp_servers={} -c plugins={}  → 无人值守时清空用户的 MCP 与插件（Codex R3 #1）。
  #   否则夜班会带着 figma/notion/computer-use/node_repl 等一起跑，副作用面远大于仓库。
  # ⚠️ **读取边界未受约束**（Codex R3 #2，已实测）: workspace-write 挡写不挡读，
  #   Codex 能 cat 仓库外任意可读文件并经输出通道带出。已列入 SKILL.md 已知限制。
  run_with_timeout "$AI_TIMEOUT_SECS" _run_codex_inner "$repo" "$body" "$outfile"
  local rc=$?
  [ "$rc" -eq 124 ] && log "[codex] 超时 ${AI_TIMEOUT_SECS}s，已终止"
  return $rc
}

# ── 单个任务 ──────────────────────────────────────────────────────────
# 返回 0=本任务告一段落  2=可用性问题（主循环按 decideHop 处置）  3=护栏违规（中止整夜）
# 包装: 保证任何退出路径都恢复用户原有的 pre-push hook
process_task() {
  local rc
  _process_task_inner "$@"; rc=$?
  # hook 清理失败一律中止整夜（Codex R6 #3）: 保留 rc=2 会让下一跳继续跑并覆盖
  # 恢复状态，用户原有的 hook 就永久丢了。
  guard_uninstall || { log "⚠️ hook 恢复失败——升级为护栏中止"; rc=3; }
  return $rc
}
_process_task_inner() {
  local id="$1" repo="$2" status="$3" prompt="$4" title="$5"
  local ts; ts="$(date '+%H%M%S')"
  # id 保留原样（可能是中文或含空格——queue.md 是用户手写且与 Claude 侧共享的），
  # 只对**派生的文件名**做编码（Codex R16 #2 推荐的方案）。
  # 加 8 位哈希后缀防止 `a b` 与 `a-b` 编码后撞名。
  # ⚠️ `pending -> needs_human` 是 state.mjs 明令禁止的转移（Codex R18 #2）:
  #    原来直接这么转、错误又被 `2>/dev/null` 吞掉，任务会**留在 pending 被反复重试**，
  #    而日志声称已转人工。先走合法的中间态 implementing 再转。
  local sid
  if ! sid="$(safe_id "$id")"; then
    log "[$id] 无法派生安全文件名（shasum 不可用），转人工"
    [ "$status" = pending ] && node "$CLI" advance "$id" implementing >/dev/null 2>&1
    node "$CLI" advance "$id" needs_human >/dev/null 2>&1 \
      || log "[$id] ⚠️ 转人工失败，任务状态可能不一致"
    push "⚠️ 需要拍板" "${title}: 无法派生安全文件名"
    return 2
  fi
  local co="$LOG_DIR/${sid}-${ts}.codex.out" ro="$LOG_DIR/${sid}-${ts}.review.out" re="$LOG_DIR/${sid}-${ts}.review.err"

  # .git 可以是**文件**（git worktree / submodule 的 gitlink）——只判目录会拒掉合法工作树
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # pending → needs_human 是非法转换（state.mjs 的 LEGAL 只允许 pending→implementing|skipped）；
    # 原实现直接跳，CLI 报错被吞、函数还返回 0，同一任务被主循环反复选中（Codex R1 #16）。
    log "[$id] repo 不是 git 仓库: ${repo}"
    [ "$status" = pending ] && node "$CLI" advance "$id" implementing >/dev/null 2>&1
    node "$CLI" advance "$id" needs_human >/dev/null 2>&1 || {
      log "[$id] 无法标 needs_human，改标 skipped 以免死循环"
      node "$CLI" advance "$id" skipped >/dev/null 2>&1; }
    push "⚠️ 需要拍板" "${title}: repo 不是 git 仓库"
    return 0
  fi

  # 干净基线要求（Codex R2 #10）: 仓库若已有用户自己的未提交改动，
  # 本任务结束时的 `git add -A` 会把它们一并提交进 checkpoint。开工前即拒绝。
  # 只在**开工那一刻**要求；任务自身产生的 dirty 由 nextTask 的同仓库串行保证不混。
  if [ "$status" = pending ]; then
    local base_st; base_st="$(git -C "$repo" status --porcelain 2>>"$RUNLOG")" || {
      log "[$id] 无法读取基线状态 → 转人工（不猜）"; 
      node "$CLI" advance "$id" implementing >/dev/null 2>&1
      node "$CLI" advance "$id" needs_human >/dev/null 2>&1
      push "⚠️ 需要拍板" "${title}: 无法读取仓库状态"; return 0; }
    if [ -n "$base_st" ]; then
      log "[$id] 仓库有既存未提交改动，拒绝开工（避免把你的工作混进 checkpoint）:"
      printf '%s\n' "$base_st" | head -10 | sed 's/^/    | /' >>"$RUNLOG"
      node "$CLI" advance "$id" implementing >/dev/null 2>&1
      node "$CLI" advance "$id" needs_human >/dev/null 2>&1
      push "⚠️ 需要拍板" "${title}: 仓库有既存未提交改动，未开工"
      return 0
    fi
  fi

  # 记录原始分支（Codex R4 #4）: Codex 若切了分支，后续 checkpoint 会提交到错误分支上
  GUARD_BRANCH="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$repo" rev-parse HEAD 2>/dev/null)"
  guard_install "$repo" || { log "[$id] 护栏安装失败"; return 3; }
  guard_snapshot "$repo" || { guard_uninstall; log "[$id] 护栏快照失败"; return 3; }

  # 1. 实现——只在 pending/implementing 时做。
  #    fixing 与 reviewing 都**不能**重跑 implement prompt（Codex R1 #9: 原实现在
  #    fixing 状态下会用原任务提示词再实现一遍，每个非零 findings 轮都发生）。
  if [ "$status" = pending ] || [ "$status" = implementing ]; then
    [ "$status" = pending ] && node "$CLI" advance "$id" implementing >/dev/null
    log "[$id] 实现开始"
    codex_step "$repo" "$(printf '%s\n\n%s\n' "$prompt" "$(cat "$SKILL_DIR/prompts/implement.md")")" \
               "$co" "$id" ""
    local crc=$?; [ "$crc" -ne 0 ] && return "$crc"
    node "$CLI" advance "$id" reviewing >/dev/null
  elif [ "$status" = fixing ]; then
    # 从 fixing 恢复 = 上一跳的修复轮因可用性问题中断，修复**没做完**。
    # 直接转 reviewing 会拿未修的 diff 再审一轮，findings 数不降 → decideNext 判 stall
    # → 把一次临时故障升级成 needs_human（Codex R3 #9）。故重跑修复提示。
    log "[$id] 从中断的修复轮恢复，重跑修复"
    local lastff; lastff="$(node "$CLI" get-field "$id" lastFindingsFile 2>/dev/null || echo '')"
    codex_step "$repo" "$(printf '继续修复上一轮审查发现的问题（上次修复被中断）。%s\n\n%s\n' \
                          "${lastff:+ findings 详见 ${lastff} 的「Findings」节。}" \
                          "$(cat "$SKILL_DIR/prompts/fix.md")")" "$co" "$id" "恢复修复时 "
    local crc2=$?; [ "$crc2" -ne 0 ] && return "$crc2"
    node "$CLI" advance "$id" reviewing >/dev/null
  fi

  # 2. 审查（**不 commit**——审查必须看未提交的 diff）
  # 状态写不进去就不能继续（Codex R5 #9）: 否则崩溃后从旧状态恢复会重跑实现
  node "$CLI" advance "$id" reviewing >/dev/null 2>&1 || {
    if [ "$(jq_get "$(node "$CLI" next-task)" task.status || echo '')" != reviewing ]; then
      log "[$id] 无法转入 reviewing，停止本任务"; return 2
    fi
  }
  # defer-review: claude 已知不可用，不必再打一次注定失败的调用——直接挂起
  if [ "${HOP_MODE:-work}" = defer-review ]; then
    log "[$id] claude 不可用，跳过本轮审查并挂起（下一跳重试）"
    node "$CLI" set-field "$id" reviewDeferred true >/dev/null 2>&1 \
      || { log "[$id] 挂起标记写入失败"; return 2; }
    return 0
  fi
  log "[$id] 审查开始"
  _run_review_inner() { "$REVIEW_SH" -C "$1" --uncommitted -t decision </dev/null >"$2" 2>"$3"; }
  run_with_timeout "$AI_TIMEOUT_SECS" _run_review_inner "$repo" "$ro" "$re"
  local rcode=$?
  # 超时按「不可用/原因不明」处理，绝不当成零 findings 通过（失败关闭契约）
  [ "$rcode" -eq 124 ] && log "[$id] 审查超时 ${AI_TIMEOUT_SECS}s，已终止"
  local parsed; parsed="$(cli_json parse-review "$ro" "$re" "$rcode")" || return 2
  if [ "$(jq_get "$parsed" ok || echo false)" != true ]; then
    local un; un="$(jq_get "$parsed" unavailable || echo '')"
    if [ -n "$un" ]; then
      log "[$id] claude 不可用: ${un}"
      node "$CLI" availability-set claude "$un" >/dev/null
      node "$CLI" set-field "$id" reviewDeferred true >/dev/null
      return 2
    fi
    log "[$id] 审查未产出可信 findings: $(jq_get "$parsed" reason || echo '')"
    node "$CLI" advance "$id" needs_human >/dev/null 2>&1
    push "⚠️ 需要拍板" "${title}: 审查未产出可信结果"
    return 0
  fi

  # 审查成功 = claude 已恢复（同 R13 #1 的理由: 以实际成功为恢复证据，
  # 而不是等「两侧都 ok」才 availability-reset——那在单侧故障时永远等不到）
  node "$CLI" availability-set claude ok >/dev/null 2>&1
  local ff n; ff="$(jq_get "$parsed" findingsFile)"; n="$(jq_get "$parsed" count)"
  log "[$id] findings ${n} 条"
  # 路径可能含引号/反斜杠，手工拼 JSON 会炸——交给 node 转义（Codex R5 #8）
  node "$CLI" set-field-str "$id" lastFindingsFile "$ff" >/dev/null 2>>"$RUNLOG" || {
    # 写不进去 → 中断恢复时会拿陈旧的 findings 路径去修（Codex R6 #7）
    log "[$id] findings 路径持久化失败，停止本任务"; return 2; }
  # 完整性断言失败 = 审查失败（Codex R1 #4: 原实现只记日志继续，声明 0 条就照样提交）
  if ! node "$CLI" record-findings "$ff" "$id" "$repo" >/dev/null 2>>"$RUNLOG"; then
    log "[$id] findings 完整性断言失败——按审查失败处置"
    node "$CLI" advance "$id" needs_human >/dev/null 2>&1
    push "⚠️ 需要拍板" "${title}: findings 文件完整性可疑"
    return 0
  fi

  # 3. 判定
  local d action; d="$(cli_json push-findings-count "$id" "$n")" || return 2
  action="$(jq_get "$d" action)"
  log "[$id] decideNext → ${action}（$(jq_get "$d" reason || echo '')）"
  case "$action" in
    done)
      # 提交失败绝不标 done（Codex R1 #11: 未提交改动会污染下一任务，早报却说已完成）
      if ! ( cd "$repo" && git add -A && git commit -q -m "sleep-well-codex: ${id} done" ) 2>>"$RUNLOG"; then
        log "[$id] checkpoint 提交失败 → needs_human"
        node "$CLI" advance "$id" needs_human >/dev/null 2>&1
        push "⚠️ 需要拍板" "${title}: 审查通过但提交失败"; return 0
      fi
      # 状态持久化失败就不能宣告完成（Codex R4 #13）: 否则推送说完成、
      # 磁盘上任务仍是 reviewing，下一跳会重做一遍。
      if ! node "$CLI" advance "$id" done >/dev/null 2>>"$RUNLOG"; then
        log "[$id] 已 checkpoint 但状态写入失败"
        push "⚠️ 状态异常" "${title}: 已提交但状态未落盘，请查看日志"; return 0
      fi
      push "✓ 任务完成" "$title"
      ;;
    continue)
      # 高严重度不得自动修（Codex R2 #8）: extractFindings 已把「高」映射成
      # needs-human，但原实现并未据此设门，仍会让 Codex 去改。
      # high 取自元信息头；与 record-findings 实际抽取到的高危条数交叉校验，
      # 任一说有高危就按有高危处理（Codex R3 #10: 只信元信息头，头被改坏就漏拦）。
      local hi hi2
      hi="$(jq_get "$parsed" high || echo 0)"
      hi2="$(grep -c '^### #[0-9]* \[高\]' "$ff" 2>/dev/null || echo 0)"
      [ "${hi2:-0}" -gt "${hi:-0}" ] && hi="$hi2"
      if [ "${hi:-0}" -gt 0 ]; then
        log "[$id] 含 ${hi} 条高严重度 findings → 不自动修复，转人工"
        ( cd "$repo" && git add -A && git commit -q -m "sleep-well-codex: ${id} WIP 高危待人工" ) 2>>"$RUNLOG"
        node "$CLI" advance "$id" needs_human >/dev/null 2>&1
        [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ] \
          && node "$CLI" set-field "$id" dirtyResidue true >/dev/null 2>&1
        push "⚠️ 需要拍板" "${title}: ${hi} 条高严重度，未自动修改"
        return 0
      fi
      node "$CLI" advance "$id" fixing >/dev/null
      log "[$id] 修复轮"
      codex_step "$repo" "$(printf '审查发现 %s 条问题，详见 %s 的「Findings」节。\n\n%s\n' \
                             "$n" "$ff" "$(cat "$SKILL_DIR/prompts/fix.md")")" "$co" "$id" "修复轮 "
      local frc=$?; [ "$frc" -ne 0 ] && return "$frc"
      # 修复成功后显式转 reviewing（Codex R4 #3）: 留在 fixing 会让下一轮
      # 走「从中断的修复轮恢复」分支再修一遍，同一份 findings 被重复修改。
      node "$CLI" advance "$id" reviewing >/dev/null
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
      if ! ( cd "$repo" && git add -A && git commit -q -m "sleep-well-codex: ${id} WIP needs-human" ) 2>>"$RUNLOG"; then
        log "[$id] WIP 提交失败（工作仍在工作区）"
      fi
      node "$CLI" advance "$id" needs_human >/dev/null
      # 若工作区仍有残留，持久化 dirtyResidue 以继续阻塞同仓库后续任务（Codex R3 #14）
      [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ] \
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
      node "$CLI" advance "$id" needs_human >/dev/null 2>&1
      push "⚠️ 需要拍板" "${title}: 审修循环判定异常"
      return 2 ;;
  esac
  return 0
}

# ── 主流程 ────────────────────────────────────────────────────────────
# 终止标记必须在抢锁之前检（否则收工后每 5 分钟仍会重跑一夜）
# 终止后仍要处理遗留的 hook 恢复（否则用户的 hook 永远回不来）
if [ -f "$CODEX_HOME/TERMINATED" ]; then
  [ -f "$CODEX_HOME/hook-recovery.json" ] && { HOOK_STATE="$CODEX_HOME/hook-recovery.json"; recover_pending_hook || true; }
  exit 0
fi
acquire_lock || exit 0
# 恢复失败**必须中止本跳**（Codex R8 #7）: 原来只记日志就继续，后续 guard_install
# 会写新的阻断 hook 并覆盖恢复记录，把仍然存在的旧备份变成永久孤儿。
# 状态文件保留着，下一跳会再试；人工修好后它自然通过。
recover_pending_hook || {
  log "hook 恢复未完成——本跳不开工，待人工处理或下跳重试"
  FINISHED=yes; exit 0          # 锁由 on_exit trap 释放
}
beat
# 环境变量必须校验（Codex R9 #6）: 两个阈值的关系弄反会让看门狗杀掉正常运行的调用。
case "$AI_TIMEOUT_SECS" in *[!0-9]*|'') log "⚠️ SLEEP_WELL_AI_TIMEOUT 非法，回落 1800"; AI_TIMEOUT_SECS=1800 ;; esac
case "$HANG_LIMIT_SECS" in *[!0-9]*|'') log "⚠️ SLEEP_WELL_HANG_LIMIT 非法，回落 2700"; HANG_LIMIT_SECS=2700 ;; esac
# 只在明显是垃圾值时才兜底，**不静默改写运维显式设的数**（原来 <60 一律抬到 60，
# 于是 e2e 里设 5 实际跑的是 60，而那条「超时生效」的断言还是绿的——测试分不清 5 和 60，
# 就不算在测这个参数）。小于 60 只告警，小于 5 才认为是笔误。
# 看门狗的两个新参数同样要校验（Codex R12 #5）: 非数值/0/负值会让 `sleep` 持续失败
# 变成烧 CPU 的空转循环，或让宽限期归零、TERM 刚发出就升级 KILL（EXIT trap 来不及跑）。
case "$WATCHDOG_POLL_SECS" in ''|*[!0-9]*) log "⚠️ WATCHDOG_POLL 非法，回落 30"; WATCHDOG_POLL_SECS=30 ;; esac
[ "$WATCHDOG_POLL_SECS" -lt 1 ] && WATCHDOG_POLL_SECS=1
case "$WATCHDOG_GRACE_SECS" in ''|*[!0-9]*) log "⚠️ WATCHDOG_GRACE 非法，回落 30"; WATCHDOG_GRACE_SECS=30 ;; esac
[ "$WATCHDOG_GRACE_SECS" -lt 3 ] && { log "⚠️ 看门狗宽限期 ${WATCHDOG_GRACE_SECS}s 过短，抬到 3"; WATCHDOG_GRACE_SECS=3; }
[ "$AI_TIMEOUT_SECS" -lt 60 ] && log "注意: AI 超时设为 ${AI_TIMEOUT_SECS}s，偏小"
[ "$AI_TIMEOUT_SECS" -lt 5 ] && { log "⚠️ AI 超时 ${AI_TIMEOUT_SECS}s 不合理，抬到 5"; AI_TIMEOUT_SECS=5; }
if [ "$HANG_LIMIT_SECS" -le "$AI_TIMEOUT_SECS" ]; then
  HANG_LIMIT_SECS=$((AI_TIMEOUT_SECS + 300))
  log "⚠️ 挂起阈值须大于 AI 超时，已抬到 ${HANG_LIMIT_SECS}s"
fi
# 依赖预检: 缺什么就说缺什么，不要等到某个子步骤失败后报一个指错方向的原因
preflight_deps() {
  local missing=""
  for b in codex node git realpath shasum xargs; do
    command -v "$b" >/dev/null 2>&1 || missing="${missing} ${b}"
  done
  [ -x "$REVIEW_SH" ] || missing="${missing} claude-handoff(${REVIEW_SH})"
  if [ -n "$missing" ]; then
    log "⚠️ 缺少依赖:${missing}（PATH=${PATH}）"
    push "⚠️ 夜班未开工" "缺少依赖:${missing}"
    return 1
  fi
  return 0
}
preflight_deps || { FINISHED=yes; exit 0; }
require_realpath || { FINISHED=yes; exit 0; }
# 残留的 active-pgid 只可能来自已死的上一次运行——留着会让看门狗对已复用的号发信号
rm -f "$ACTIVE_PGID_FILE" 2>/dev/null
start_watchdog
log "=== 取得锁，开工（pid $$，AI 超时 ${AI_TIMEOUT_SECS}s / 挂起阈值 ${HANG_LIMIT_SECS}s）==="

[ -f "$STOP_FILE" ] && { node "$CLI" init >/dev/null 2>&1; finalize "见到 STOP 文件"; }
INIT_ERR="$(node "$CLI" init 2>&1 >/dev/null)"; INIT_RC=$?
if [ $INIT_RC -ne 0 ]; then
  log "init 失败: ${INIT_ERR}"
  # 队列为空/缺失也要走正常收工: 否则 launchd 每 5 分钟静默重试到天亮，
  # 用户既没有早报也没有推送，不知道夜班根本没开工（Codex R3 #17）。
  node "$SKILL_DIR/bin/report.mjs" >/dev/null 2>&1 || log "早报生成失败（未开工路径）"
  push "⚠️ 夜班未开工" "$(printf '%.150s' "未开工: ${INIT_ERR:-队列为空或不存在}")"
  node "$CLI" terminal-set "队列为空" >/dev/null 2>&1
  launchctl unload "$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist" 2>/dev/null
  FINISHED=yes; exit 0
fi

# cutoff 必须在退避之前判（Codex R2 #14）: 否则退避期跨过早晨，夜班不会按时收工出早报。
if [ "$(jq_get "$(cli_json cutoff-passed || echo '{}')" passed || echo false)" = true ]; then
  finalize "到达 cutoff"
fi
# 隔离 CODEX_HOME 必须在任何 codex 调用之前备妥；备不出来就不开工
if ! prepare_codex_home; then
  log "无法准备隔离的 CODEX_HOME，拒绝开工"
  push "⚠️ 夜班未开工" "无法准备隔离运行环境（MCP 未能清空）"
  FINISHED=yes; exit 1
fi

# 退避未到点则本跳直接退出（Codex R1 #7: 原实现算了 hops 却不等，5 分钟后照常重试）
if [ "$(jq_get "$(cli_json retry-due || echo '{}')" due || echo true)" != true ]; then
  log "退避未到点，本跳退出"; FINISHED=yes; exit 0
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
      log "排期 $(jq_get "$bo" hops) 跳后重试"; FINISHED=yes; exit 0 ;;
  esac

  nt="$(cli_json next-task)" || hop_fail "取任务失败（状态可能损坏）"
  tid="$(jq_get "$nt" task.id || echo '')"
  # fix-only: 只把在途任务推完，绝不开新的（开了也只会去调不可用的 codex）
  if [ -n "$tid" ] && [ "$HOP_MODE" = fix-only ] \
     && [ "$(jq_get "$nt" task.status || echo pending)" = pending ]; then
    log "codex 不可用且下一个是新任务，本跳不开工"
    bo="$(cli_json backoff-schedule)" || hop_fail "退避排期失败"
    [ "$(jq_get "$bo" giveUp || echo false)" = true ] && finalize "退避耗尽（codex 长时间不可用）"
    FINISHED=yes; exit 0
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
      FINISHED=yes; exit 0
    fi
    if [ "$(jq_get "$nt" blockedBySameRepo || echo false)" = true ]; then
      log "同仓库串行阻塞，排退避后退出"
      bo="$(cli_json backoff-schedule)" || hop_fail "退避排期失败"
      [ "$(jq_get "$bo" giveUp || echo false)" = true ] && finalize "退避耗尽"
      FINISHED=yes; exit 0
    fi
    finalize "队列已清空"
  fi

  process_task "$tid" "$(jq_get "$nt" task.repo)" "$(jq_get "$nt" task.status)" \
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
         FINISHED=yes; exit 0
       fi
       log "[$tid] 可用性中断，本跳继续（中继模式会接管）"
       continue ;;
    3) finalize "护栏违规，中止整夜" ;;
    *) # 成功推进即清零连续失败计数（Codex R14 #4）: 原来只在任务 ID 变化时重置，
       # 于是「同一任务先中断一次、重试成功、再遇一次中断」会被误判成「连续两次」而结束本跳。
       CONSEC_UNAVAIL_ID=""; CONSEC_UNAVAIL_N=0
       node "$CLI" backoff-clear >/dev/null 2>&1 ;;
  esac
done
