#!/usr/bin/env bash
# watchdog.test.sh — 看门狗**真的会杀掉卡死的编排器**吗。
#
# 为什么必须有这个文件（Codex R11 决策建议原话:「111 项测试虽全绿，但没有覆盖真实看门狗信号」）:
# 挂起兜底连着三轮「看着对、测试绿、其实根本没生效」——
#   R8  接管写在 acquire_lock 里 → launchd 在 job 运行时丢弃触发，是死代码
#   R10 `kill -TERM -$ppid`      → 编排器不是进程组组长（pgid != $$），打空或打到无关组
#   R11 `_kill_tree ... "$wd_self"` → bash 3.2 子 shell 的 $$ 仍是父进程 PID，
#                                     于是「跳过自己」跳过的其实是**编排器本身**
# 三次的共同点不是逻辑难，是**没有任何测试让看门狗真的开一枪**。
# 所以这里不测内部状态，只测一件事: 卡死的父进程有没有死、后代有没有清干净。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

TMPD="$(mktemp -d)" || exit 1
# 进程标记按**本次运行**唯一: 用固定标记时，上一次运行（尤其是失败/被打断的那次）
# 留下的孤儿会被下一次当成自己的残留——测试之间互相污染，报出与本次无关的失败。
RUNTAG="$$"
cleanup_all() { pkill -9 -f "swtest-orphan-${RUNTAG}" 2>/dev/null; pkill -9 -f "swtest-hb-${RUNTAG}" 2>/dev/null; rm -rf "$TMPD"; }
trap cleanup_all EXIT

BLOCK="$TMPD/block.sh"
awk '/^# >>>TESTABLE:watchdog>>>/{f=1;next} /^# <<<TESTABLE:watchdog<<</{f=0} f' \
  "$ROOT/bin/orchestrator.sh" > "$BLOCK"
[ -s "$BLOCK" ] || { echo "抽取失败: 找不到 TESTABLE:watchdog 标记对"; exit 1; }
# 自检项要绑**契约符号**，别绑某一版修复的实现细节（否则拿旧代码验证检出能力时
# 会卡在抽取自检上，反而测不成——我第一版写的是 'PPID' 和 '_kill_tree_sweep()'，正是这个毛病）。
for need in '_kill_tree()' 'start_watchdog()' 'stop_watchdog()' 'wd_self' 'HANG_LIMIT_SECS'; do
  grep -qF -- "$need" "$BLOCK" || { echo "抽取自检失败: 区块里没有 [$need]"; exit 1; }
done

# 造一个「假编排器」: 起看门狗 → 写一个已经过期的心跳 → 然后卡死。
# 心跳过期意味着看门狗必须开枪；父进程什么都不做，所以它死不死完全取决于看门狗。
mkparent() {   # $1=场景目录 $2=心跳有多旧（秒） $3=父进程要不要一直 fork $4=标记
  local d="$1" age="$2" forky="$3"
  local TAG="${4:-none}"
  mkdir -p "$d/state"
  {
    printf 'HEARTBEAT=%q\n' "$d/state/heartbeat"
    printf 'RUNLOG=%q\n' "$d/run.log"
    printf 'ACTIVE_PGID_FILE=%q\n' "$d/state/active-pgid"
    echo 'HANG_LIMIT_SECS=5'
    echo 'WATCHDOG_POLL_SECS=2'
    echo 'WATCHDOG_GRACE_SECS=3'
    cat "$BLOCK"
    echo 'trap "echo TRAP-RAN >>\"$RUNLOG\"" EXIT'
    printf 'date -u -v-%ldS "+%%Y-%%m-%%dT%%H:%%M:%%SZ" > "$HEARTBEAT"\n' "$age"
    echo 'start_watchdog'
    echo 'echo $$ > "$1"'
    if [ "$forky" = yes ]; then
      # 对抗测试（Codex R11 #5）: 持续派生子进程，检验快照竞态下有没有漏网的
      # 给派生的进程打上可辨识的标记: 父进程一死，后代就被 reparent 到 init，
      # `pgrep -P $parent` 必然为空——用它断言「无残留」是**假绿**（Codex R12 #6）。
      echo '( while :; do ( exec -a swtest-orphan-'"$TAG"' sleep 300 ) & sleep 0.3; done ) &'
    fi
    if [ "$age" = 0 ]; then
      # 「健康的编排器」必须**持续刷新心跳**——真实编排器在主循环与 run_with_timeout
      # 轮询里都会 beat。只写一次就不管，那它本来就该被杀（这曾是我这个测试自己的 bug）。
      # 刷新器也要能被清理: 父进程被 kill -9 时 EXIT trap 不跑，它会成为孤儿
      # 不断派生 sleep（Codex R12 #7）。打标记，收尾时按标记清。
      echo '( exec -a swtest-hb-'"$TAG"' bash -c '"'"'while :; do date -u "+%Y-%m-%dT%H:%M:%SZ" > "$1"; sleep 1; done'"'"' _ "$HEARTBEAT" ) &'
    fi
    # ⚠️ 挂起必须发生在**进程内部、且没有子进程可杀**。这一条我写错过两次:
    #    · `sleep 600` —— sleep 是子进程，看门狗即使跳过父进程、只杀掉 sleep，
    #      sleep 一返回脚本也就结束了，看着像「父进程被终止」，其实是间接死的；
    #    · `read < fifo` —— 阻塞会被打断，父进程照样自然退出（日志里能看到 READ-RETURNED）。
    #    两种写法都让测试**通过了带缺陷的旧代码**。
    #    纯 shell 忙等没有子进程、也不会被打断后自然返回，只有信号能结束它——
    #    实测: R10 版（wd_self=$$）父进程存活，当前版被终止，这才叫能区分。
    echo 'i=0; while [ $i -lt 200000000 ]; do i=$((i+1)); done'
    echo 'echo LOOP-FINISHED >> "$RUNLOG"'
  } > "$d/parent.sh"
  printf '%s\n' "$d/parent.sh"
}

run_scene() {   # $1=场景名 $2=心跳年龄 $3=forky $4=标记 → 回显 "父pid 包装pid"
  local d="$TMPD/$1"
  local sh_file; sh_file="$(mkparent "$d" "$2" "$3" "${4:-none}")"
  bash "$sh_file" "$d/pid" >/dev/null 2>&1 &
  local wrapper=$!
  local n=0
  while [ ! -s "$d/pid" ] && [ $n -lt 50 ]; do sleep 0.2; n=$((n+1)); done
  local pid; pid="$(cat "$d/pid" 2>/dev/null)"
  printf '%s %s\n' "$pid" "$wrapper"
}

echo "看门狗"

# ── 1. 心跳过期 → 卡死的父进程必须被杀掉 ────────────────────────────
read -r P1 W1 <<<"$(run_scene hang 600 no)"
if [ -z "$P1" ]; then bad "场景启动失败（拿不到父 pid）"; else
  n=0; while kill -0 "$P1" 2>/dev/null && [ $n -lt 40 ]; do sleep 1; n=$((n+1)); done
  if kill -0 "$P1" 2>/dev/null; then
    bad "心跳过期 ${n}s 后卡死的编排器**仍然活着**——看门狗没开枪（三轮复发的那个缺陷）"
    kill -9 "$P1" 2>/dev/null
  else ok "心跳过期后卡死的编排器被终止（${n}s）"; fi
  grep -q 'TRAP-RAN' "$TMPD/hang/run.log" 2>/dev/null \
    && ok "EXIT trap 跑到了（锁与 hook 才能被清理）" \
    || bad "EXIT trap 没跑到——TERM 前就被 KILL 了？"
fi
kill -9 "$W1" 2>/dev/null

# ── 2. 心跳新鲜 → 绝不能杀（误杀正常夜班比不看门更糟）──────────────
read -r P2 W2 <<<"$(run_scene fresh 0 no "fresh-${RUNTAG}")"
if [ -z "$P2" ]; then bad "场景启动失败"; else
  sleep 12
  if kill -0 "$P2" 2>/dev/null; then ok "心跳新鲜时不误杀"; else bad "心跳新鲜却被杀（误杀正常夜班）"; fi
  kill -9 "$P2" 2>/dev/null
fi
kill -9 "$W2" 2>/dev/null
pkill -9 -f "swtest-hb-fresh-${RUNTAG}" 2>/dev/null      # 父被 KILL 时 trap 不跑，刷新器要手工清
sleep 1
[ -z "$(pgrep -f "swtest-hb-fresh-${RUNTAG}" 2>/dev/null)" ] && ok "测试自身不泄漏心跳刷新进程" \
                                                    || bad "心跳刷新进程泄漏（R12 #7）"

# ── 3. 对抗: 父进程持续 fork，杀完不得有残留（Codex R11 #5）─────────
read -r P3 W3 <<<"$(run_scene forky 600 yes "forky-${RUNTAG}")"
if [ -z "$P3" ]; then bad "场景启动失败"; else
  n=0; while kill -0 "$P3" 2>/dev/null && [ $n -lt 40 ]; do sleep 1; n=$((n+1)); done
  kill -0 "$P3" 2>/dev/null && { bad "持续 fork 时父进程未被杀"; kill -9 "$P3" 2>/dev/null; } \
                            || ok "持续 fork 时父进程仍被终止"
  sleep 2
  # 按标记查，不用 pgrep -P（父死后后代被 reparent，那个查询必然为空 = 假绿）
  leftover="$(pgrep -f "swtest-orphan-forky-${RUNTAG}" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$leftover" = "0" ] && ok "杀完无残留（按标记查，非 pgrep -P 的假绿）" \
                        || { bad "杀完仍有 ${leftover} 个被 reparent 的孤儿"; pkill -9 -f "swtest-orphan-forky-${RUNTAG}" 2>/dev/null; }
fi
kill -9 "$W3" 2>/dev/null

# ── 4. active-pgid 的 owner 不是本进程时必须忽略（陈旧值防误杀）─────
d="$TMPD/stale"; sh_file="$(mkparent "$d" 600 no)"
printf '999999 999998\n' > "$d/state/active-pgid"     # 冒充别的 owner
bash "$sh_file" "$d/pid" >/dev/null 2>&1 &
W4=$!
n=0; while [ ! -s "$d/pid" ] && [ $n -lt 50 ]; do sleep 0.2; n=$((n+1)); done
P4="$(cat "$d/pid" 2>/dev/null)"
n=0; while kill -0 "$P4" 2>/dev/null && [ $n -lt 40 ]; do sleep 1; n=$((n+1)); done
kill -9 "$P4" 2>/dev/null
if grep -q '看门狗: 已向 AI 子进程组' "$d/run.log" 2>/dev/null; then
  bad "owner 不匹配的陈旧 active-pgid 仍被采信（会打到无关进程组）"
else ok "owner 不匹配的陈旧 active-pgid 被忽略"; fi
kill -9 "$W4" 2>/dev/null

# ── 5. 杀完不得留下**永久 stopped** 的进程（自查，已实测该危害）──
# _kill_tree 用 SIGSTOP 冻住后代以防它们在被杀前再 fork。但若在 STOP 与 CONT 之间
# 杀手自己死掉，目标会永久停在状态 T——不退出、不占 CPU、极难发现，比孤儿运行更糟。
# 现在后代走 STOP→KILL（KILL 对 stopped 进程直接生效，无需 CONT），窗口根本不存在。
read -r P5 W5 <<<"$(run_scene nostopped 600 yes "nostop-${RUNTAG}")"
if [ -z "$P5" ]; then bad "场景启动失败"; else
  n=0; while kill -0 "$P5" 2>/dev/null && [ $n -lt 40 ]; do sleep 1; n=$((n+1)); done
  # ⚠️ 先看根**自己**是不是被永久 stopped 了，再收尾（Codex R13 #5）:
  #    原来直接 kill -9 "$P5" 会把证据毁掉——若回归让编排器停在状态 T，
  #    kill -0 一直为真、循环跑满超时，然后这一刀把它杀掉，扫描就什么也发现不了。
  rootstat="$(ps -o stat= -p "$P5" 2>/dev/null | tr -d ' ')"
  case "$rootstat" in
    *T*) bad "编排器自身被永久 stopped（状态 ${rootstat}）——锁永不释放" ;;
    *)   ok "编排器未被留在 stopped 状态" ;;
  esac
  kill -9 "$P5" 2>/dev/null
  sleep 2
  stopped="$(ps -o pid=,stat= -ax 2>/dev/null | awk '$2 ~ /T/ {print $1}' | while read -r q; do
      [ "$(ps -o command= -p "$q" 2>/dev/null | grep -c 'sleep 300')" -gt 0 ] && echo "$q"; done | wc -l | tr -d ' ')"
  [ "${stopped:-0}" = "0" ] && ok "杀完没有残留的永久 stopped 进程" \
                            || bad "残留 ${stopped} 个永久 stopped 进程（状态 T，永不退出）"
fi
kill -9 "$W5" 2>/dev/null

printf '\nwatchdog: pass %d / fail %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
