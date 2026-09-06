#!/usr/bin/env bash
# hook-state.test.sh — pre-push hook 备份/恢复状态机的回归测试。
#
# 为什么必须有（Codex R8 #6-#11）:
#   R7 为了让恢复元数据跨进程而引入 hook-recovery.json，却**重新引入了 R2 #2**
#   ——「夜班跑一次就永久破坏你自己的 push 流程」——而且是在**完全正常的路径**上:
#     install 写状态 → uninstall 成功恢复但不清状态 → 下一跳 recover 拿陈旧记录
#     → 无条件删掉已归位的用户 hook → 备份已 mv 走故判定「无备份」→ 清状态 return 0
#   全程零告警。整条链上没有一个环节被测试覆盖过。
#
# 本文件按「用户的 pre-push 最终是什么」来断言，而不是按内部状态——
# 那才是这段代码唯一真正需要保证的事。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

# 按显式标记抽取 + 自检（同 prot-hash.test.sh 的理由: 行首 } 启发式会静默截断）
BLOCK="$TMPD/block.sh"
awk '/^# >>>TESTABLE:hook>>>/{f=1;next} /^# <<<TESTABLE:hook<<</{f=0} f' \
  "$ROOT/bin/orchestrator.sh" > "$BLOCK"
[ -s "$BLOCK" ] || { echo "抽取失败: 找不到 TESTABLE:hook 标记对"; exit 1; }
for need in 'guard_install() {' 'guard_uninstall() {' 'recover_pending_hook() {' '_write_hook_state' '_hook_is_ours'; do
  grep -qF -- "$need" "$BLOCK" || { echo "抽取自检失败: 区块里没有 [$need]"; exit 1; }
done

# jq_get 与 log/push 由 orchestrator 提供，这里给等价桩
mkfn() {   # $1=isolated runtime home
  { printf 'CODEX_HOME=%q\n' "$1"
    printf 'SW_RUNTIME_HOME=%q\n' "$1"
    cat <<'STUB'
log(){ printf '[log] %s\n' "$*" >>"$CODEX_HOME/log.txt"; }
push(){ printf '[push] %s | %s\n' "$1" "$2" >>"$CODEX_HOME/log.txt"; }
jq_get() {
  printf '%s' "$1" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let o; try{o=JSON.parse(s)}catch{process.exit(2)}
      let v=o; for(const k of process.argv[1].split("."))v=v?.[k];
      if(v===undefined||v===null){process.stdout.write("");process.exit(3)}
      process.stdout.write(String(v));
    })' "$2"
}
STUB
    cat "$BLOCK"
  }
}

# 每个场景一个干净的 repo + CODEX_HOME
scene() {   # $1=名字 → 回显 "repo|home|fn.sh"
  # ⚠️ 不能写成 `local n="$1" d="$TMPD/$n"`——同一条 local 里的参数在赋值生效**之前**
  #    就被展开，$n 那时还是未定义，set -u 下直接报 unbound variable。
  local n="$1"
  local d="$TMPD/$n"
  mkdir -p "$d/repo" "$d/home"
  git -C "$d/repo" init -q .
  mkfn "$d/home" > "$d/fn.sh"
  printf '%s|%s|%s\n' "$d/repo" "$d/home" "$d/fn.sh"
}
USERHOOK='#!/bin/sh
echo "USER-OWN-HOOK"'

run() {   # $1=fn.sh $2...=脚本体
  local f="$1"; shift
  { cat "$f"; printf '%s\n' "$*"; } > "${f}.run"
  bash "${f}.run"
}

echo "hook 状态机回归"

# ── 1. 正常路径: install → uninstall → 下一跳 recover，用户 hook 必须还在 ──
IFS='|' read -r R H F <<<"$(scene normal)"
printf '%s\n' "$USERHOOK" > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
run "$F" 'guard_install '"$R"' && guard_uninstall' >/dev/null 2>&1
if grep -q 'USER-OWN-HOOK' "$R/.git/hooks/pre-push" 2>/dev/null; then ok "install→uninstall 后用户 hook 归位"
else bad "install→uninstall 后用户 hook 未归位"; fi
[ -f "$H/hook-recovery.json" ] && bad "uninstall 成功后状态文件未清（R8 #6 直接成因）" \
                               || ok "uninstall 成功后状态文件已清"
run "$F" 'recover_pending_hook; echo rc=$?' >/dev/null 2>&1
if grep -q 'USER-OWN-HOOK' "$R/.git/hooks/pre-push" 2>/dev/null; then
  ok "下一跳 recover 不动已归位的用户 hook（R8 #6）"
else bad "下一跳 recover 销毁了用户 hook（R8 #6 回归）"; fi

# ── 2. 崩溃后恢复: 状态在、我们的 hook 在、备份在 ──
IFS='|' read -r R H F <<<"$(scene crash)"
printf '%s\n' "$USERHOOK" > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
run "$F" 'guard_install '"$R"'' >/dev/null 2>&1     # 装完就"崩溃"，不 uninstall
run "$F" 'recover_pending_hook; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
if grep -q 'USER-OWN-HOOK' "$R/.git/hooks/pre-push" 2>/dev/null; then ok "崩溃后下一跳恢复用户 hook"
else bad "崩溃后未能恢复用户 hook"; fi
grep -q 'rc=0' "$H/rc" && ok "恢复成功返回 0" || bad "恢复成功却返回非零"

# ── 3. 用户在崩溃后自己换了 hook: 冲突，两份都保留，返回非零（R8 #10）──
IFS='|' read -r R H F <<<"$(scene conflict)"
printf '%s\n' "$USERHOOK" > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
run "$F" 'guard_install '"$R"'' >/dev/null 2>&1
printf '#!/bin/sh\necho "USER-NEW-HOOK"\n' > "$R/.git/hooks/pre-push"   # 用户手动换了
run "$F" 'recover_pending_hook; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
grep -q 'USER-NEW-HOOK' "$R/.git/hooks/pre-push" && ok "冲突时不覆盖用户新 hook（R8 #10）" \
                                                 || bad "冲突时覆盖了用户新 hook"
ls "$R"/.git/hooks/pre-push.sleepwell-bak.* >/dev/null 2>&1 && ok "冲突时备份仍保留" || bad "冲突时备份丢失"
grep -q 'rc=0' "$H/rc" && bad "冲突却返回 0" || ok "冲突返回非零（调用方会中止本跳）"

# ── 4. 元数据损坏: 保留原文件、告警、返回非零（R8 #9）──
IFS='|' read -r R H F <<<"$(scene corrupt)"
printf '%s\n' "$USERHOOK" > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
printf '{"hook":"/a/b","backup' > "$H/hook-recovery.json"       # 截断的 JSON
run "$F" 'recover_pending_hook; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
grep -q 'rc=0' "$H/rc" && bad "元数据损坏却返回 0（R8 #9 回归）" || ok "元数据损坏返回非零"
[ -f "$H/hook-recovery.json" ] && ok "元数据损坏时保留原文件待人工" || bad "元数据损坏时把唯一线索删了"
grep -q 'USER-OWN-HOOK' "$R/.git/hooks/pre-push" && ok "元数据损坏时不碰任何 hook 文件" \
                                                  || bad "元数据损坏时动了 hook 文件"

# ── 5. 记录了备份但文件不存在: 不动文件、不清状态、返回非零（R8 #12）──
IFS='|' read -r R H F <<<"$(scene lostbak)"
printf '%s\n' "$USERHOOK" > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({hook:process.argv[2],backup:process.argv[2]+".gone"}))' \
  "$H/hook-recovery.json" "$R/.git/hooks/pre-push"
run "$F" 'recover_pending_hook; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
grep -q 'rc=0' "$H/rc" && bad "备份缺失却返回 0（会静默销毁用户 hook）" || ok "备份缺失返回非零"
grep -q 'USER-OWN-HOEK\|USER-OWN-HOOK' "$R/.git/hooks/pre-push" && ok "备份缺失时用户 hook 未被删" \
                                                                 || bad "备份缺失时用户 hook 被删（R8 #6/#12 回归）"

# ── 6. 原本没有用户 hook: 崩溃后 recover 只撤掉我们自己的 ──
IFS='|' read -r R H F <<<"$(scene nohook)"
run "$F" 'guard_install '"$R"'' >/dev/null 2>&1
run "$F" 'recover_pending_hook; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
[ -e "$R/.git/hooks/pre-push" ] && bad "原本无 hook，恢复后却留下了文件" || ok "原本无 hook 时恢复后干净"
grep -q 'rc=0' "$H/rc" && ok "该场景返回 0" || bad "该场景返回非零"
[ -f "$H/hook-recovery.json" ] && bad "该场景状态未清" || ok "该场景状态已清"

# ── 7. 路径含双引号: 元数据必须是合法 JSON（R8 #8）──
IFS='|' read -r R H F <<<"$(scene 'quote')"
QR="$TMPD/we\"ird"; mkdir -p "$QR"; git -C "$QR" init -q .
printf '%s\n' "$USERHOOK" > "$QR/.git/hooks/pre-push"; chmod +x "$QR/.git/hooks/pre-push"
# ⚠️ 路径里有 " ——必须用 printf %q 生成脚本体，直接拼字符串会破坏 shell 引用，
#    让 guard_install 收到一个被截断的路径，于是"测试失败"其实是脚手架失败。
run "$F" "guard_install $(printf '%q' "$QR")" >/dev/null 2>&1
if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$H/hook-recovery.json" 2>/dev/null; then
  ok "路径含双引号时元数据仍是合法 JSON（R8 #8）"
else bad "路径含双引号时元数据非法 JSON"; fi
run "$F" 'recover_pending_hook' >/dev/null 2>&1
grep -q 'USER-OWN-HOOK' "$QR/.git/hooks/pre-push" 2>/dev/null && ok "含引号路径也能正确恢复" \
                                                              || bad "含引号路径恢复失败"

# ── 8. 存在待恢复状态时拒绝装新 hook（R8 #7）──
IFS='|' read -r R H F <<<"$(scene pending)"
printf '{"hook":"/nonexistent/pre-push","backup":"/nonexistent/bak"}' > "$H/hook-recovery.json"
run "$F" 'guard_install '"$R"'; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
grep -q 'rc=0' "$H/rc" && bad "有待恢复状态却仍装新 hook（会把旧备份变孤儿，R8 #7）" \
                       || ok "有待恢复状态时拒绝装新 hook（R8 #7）"
grep -q '/nonexistent/pre-push' "$H/hook-recovery.json" && ok "旧状态未被覆盖" || bad "旧状态被覆盖"

# ── 9. 写 hook 失败要回滚（R8 #11）──
# ⚠️ 把 hooks 目录改成 500 是**错的注入点**（Codex R9 #14）: 那样 `mv pre-push bak` 先失败，
#    guard_install 在写新 hook 之前就返回了，标称验证的「写入/chmod 失败回滚」分支根本没执行。
#    正确做法是让备份成功、只让**写入**失败——把目标路径预先做成一个不可写的目录。
IFS='|' read -r R H F <<<"$(scene wfail)"
printf '%s\n' "$USERHOOK" > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
run "$F" "_wf(){ mkdir -p \"\$1/.git/hooks\"; }; guard_install $(printf '%q' "$R")" >/dev/null 2>&1 || true
# 上面那次已把状态写脏，重来: 用一个「备份能成功、写入必失败」的构造
IFS='|' read -r R H F <<<"$(scene wfail2)"
printf '%s\n' "$USERHOOK" > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
cat > "$F.inject" <<INJ
$(cat "$F")
# 覆写 _hook_body 让写入必然失败（模拟磁盘满/权限异常），但备份 mv 已经成功
_hook_body(){ return 1; }
guard_install $(printf '%q' "$R"); echo "rc=\$?" > "$H/rc"
INJ
bash "$F.inject" >/dev/null 2>&1
grep -q 'rc=0' "$H/rc" && bad "写 hook 失败却返回 0（任务会在无纵深 hook 下继续，R8 #11）" \
                       || ok "写 hook 失败返回非零，且确实走到了写入失败分支（R9 #14）"
grep -q 'USER-OWN-HOOK' "$R/.git/hooks/pre-push" 2>/dev/null && ok "写失败后回滚了用户 hook" \
                                                              || bad "写失败后用户 hook 未回滚"
[ -f "$H/hook-recovery.json" ] && bad "回滚成功后仍留有状态" || ok "回滚成功后状态已清"

# ── 10. 哨兵串碰撞: 用户 hook 恰好含哨兵串也不能被当成我们的（R9 #9）──
IFS='|' read -r R H F <<<"$(scene collide)"
printf '#!/bin/sh\n# 我从夜班的 hook 改来的，保留了 sleep-well-codex-guard-hook-v1 这行\necho "USER-DERIVED"\n' \
  > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({hook:process.argv[2],backup:""}))' \
  "$H/hook-recovery.json" "$R/.git/hooks/pre-push"
run "$F" 'recover_pending_hook; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
grep -q 'USER-DERIVED' "$R/.git/hooks/pre-push" 2>/dev/null \
  && ok "含哨兵串但内容不同的用户 hook 未被删（R9 #9）" \
  || bad "含哨兵串的用户 hook 被误删（R9 #9 回归）"

# ── 11. 尾随空行不得被当成「还是我们的」（Codex R10 #4）──
IFS='|' read -r R H F <<<"$(scene trailnl)"
run "$F" "guard_install $(printf '%q' "$R")" >/dev/null 2>&1
printf '\n\n' >> "$R/.git/hooks/pre-push"          # 外部只加了两个空行
cat > "$F.tn" <<INJ
$(cat "$F")
tok="\$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.token||"")' "$H/hook-recovery.json")"
_hook_is_ours "$R/.git/hooks/pre-push" "\$tok"; echo "is_ours=\$?" > "$H/rc"
INJ
bash "$F.tn" >/dev/null 2>&1
grep -q 'is_ours=0' "$H/rc" && bad "只多了尾随空行仍被判为我们的（R10 #4 回归）" \
                            || ok "尾随空行使身份判定失败（逐字节比对，R10 #4）"

# ── 12. token 是每次安装随机的，不是代码里的固定串 ──
IFS='|' read -r R H F <<<"$(scene tok1)"
run "$F" "guard_install $(printf '%q' "$R")" >/dev/null 2>&1
t1="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.token||"")' "$H/hook-recovery.json" 2>/dev/null)"
IFS='|' read -r R2 H2 F2 <<<"$(scene tok2)"
run "$F2" "guard_install $(printf '%q' "$R2")" >/dev/null 2>&1
t2="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.token||"")' "$H2/hook-recovery.json" 2>/dev/null)"
[ -n "$t1" ] && [ -n "$t2" ] && [ "$t1" != "$t2" ] && ok "每次安装的 token 不同（不可预测，无碰撞）" \
                                                   || bad "token 缺失或两次安装相同: [$t1] [$t2]"
grep -qF "$t1" "$R/.git/hooks/pre-push" 2>/dev/null && ok "token 写进了 hook 文件" || bad "hook 里没有 token"

# ── 13. R9 时代的无 token 记录必须被识别并清理（Codex R11 #2）──
# 原实现在无 token 时 `_hook_is_ours` 必然 false，却照样清状态并报告成功——
# 阻断 hook 永久留下，用户的 git push 从此一直被拦，且再无记录可循。
IFS='|' read -r R H F <<<"$(scene legacy)"
printf '#!/bin/sh\n# sleep-well-codex-guard-hook-v1\necho "sleep-well-codex: push 被夜班护栏阻断（纵深防御层）" >&2\nexit 1\n' \
  > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({hook:process.argv[2],backup:""}))' \
  "$H/hook-recovery.json" "$R/.git/hooks/pre-push"
run "$F" 'recover_pending_hook; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
[ -e "$R/.git/hooks/pre-push" ] && bad "R9 时代的阻断 hook 未被移除（用户 push 会一直被拦，R11 #2）" \
                                || ok "R9 时代的无 token 阻断 hook 被识别并移除（R11 #2）"
grep -q 'rc=0' "$H/rc" && ok "迁移路径返回 0" || bad "迁移路径返回非零"

# ── 14. 无 token 且内容不认识 → 失败关闭，不得清状态 ──
IFS='|' read -r R H F <<<"$(scene legacy_unknown)"
printf '#!/bin/sh\necho "某个陌生的 hook"\n' > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({hook:process.argv[2],backup:""}))' \
  "$H/hook-recovery.json" "$R/.git/hooks/pre-push"
run "$F" 'recover_pending_hook; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
grep -q 'rc=0' "$H/rc" && bad "归属不明却返回 0" || ok "归属不明时失败关闭"
[ -f "$H/hook-recovery.json" ] && ok "归属不明时保留恢复记录" || bad "归属不明却清掉了唯一记录"
grep -q '陌生的 hook' "$R/.git/hooks/pre-push" && ok "归属不明时不动用户文件" || bad "动了归属不明的文件"

# ── 15. R9 无 token 记录 **且带用户备份** 的迁移（Codex R12 #4）──
# 我 R11 只把 legacy 识别接在「无备份」那一支上，带备份的升级场景会进另一支，
# _hook_is_ours 因 token 为空必然拒绝 → 阻断 hook 留着、用户 hook 困在备份名下、
# 此后每一夜都拒绝开工。
IFS='|' read -r R H F <<<"$(scene legacy_bak)"
printf '#!/bin/sh\n# sleep-well-codex-guard-hook-v1\necho "sleep-well-codex: push 被夜班护栏阻断（纵深防御层）" >&2\nexit 1\n' \
  > "$R/.git/hooks/pre-push"; chmod +x "$R/.git/hooks/pre-push"
printf '%s\n' "$USERHOOK" > "$R/.git/hooks/pre-push.sleepwell-bak.9999"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({hook:process.argv[2],backup:process.argv[2]+".sleepwell-bak.9999"}))' \
  "$H/hook-recovery.json" "$R/.git/hooks/pre-push"
run "$F" 'recover_pending_hook; echo "rc=$?" >'"$H"'/rc' >/dev/null 2>&1
grep -q 'USER-OWN-HOOK' "$R/.git/hooks/pre-push" 2>/dev/null \
  && ok "带备份的 R9 无 token 记录也能迁移，用户 hook 归位（R12 #4）" \
  || bad "带备份的 R9 记录未能迁移，用户 hook 仍困在备份名下（R12 #4 回归）"
grep -q 'rc=0' "$H/rc" && ok "该迁移路径返回 0" || bad "该迁移路径返回非零（此后每夜都拒绝开工）"

printf '\nhook-state: pass %d / fail %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
