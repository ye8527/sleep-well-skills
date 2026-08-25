#!/usr/bin/env bash
# prot-hash.test.sh — _prot_hash 的**性质**回归测试。
#
# 为什么是性质而不是用例（Codex R8 收尾 / 自查 F-G）:
#   _prot_hash 到 R8 为止改了五版，**每版都有缺陷**，而 test/ 下十个 .mjs 没有一个碰它。
#     R2 只看已跟踪 → R3 加未跟踪 → R6 展开 ignored（破了性能）
#       → R7 加 -name 预筛（破了覆盖）→ R8 预筛与权威判定发散，5 份漏 4 份
#   每一版都只手工验证了「这轮刚修的那个 case」，所以每次修复都打破上一版的性质。
#
# 这里断言的不变量只有一条，但它同时覆盖上面全部四次回归:
#
#     摘要覆盖的路径集合  ⊇  cli.mjs protected-in 判定为受保护的集合
#
# 即: 权威判定说受保护的，必须在快照里留下痕迹（内容哈希 / LINK / TARGET 行）。
# 新增受保护模式时不需要改本测试——它自动跟随 guardrails.mjs。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLI="$ROOT/lib/cli.mjs"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

# 从 orchestrator.sh 里抽出真函数——不复制实现，避免测试与被测代码发散
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT
# 按显式标记抽取，并**自检抽到的东西是不是想要的**。
# 原来按「PROT_MAX_ENTRIES 到下一个行首 }」抽——R9 #13 就预警过这个脆弱性，
# 而我在同一轮里加了个含行首 } 的小函数，抽取范围当场静默截断，10 项测试挂了 9 项，
# 而被测函数本身完全正常。**抽取失败必须是响亮的失败，不能变成「测了别的东西还通过」。**
awk '/^# >>>TESTABLE:prot-hash>>>/{f=1;next} /^# <<<TESTABLE:prot-hash<<</{f=0} f' \
  "$ROOT/bin/orchestrator.sh" > "$TMPD/block.sh"
[ -s "$TMPD/block.sh" ] || { echo "抽取失败: 找不到 TESTABLE:prot-hash 标记对"; exit 1; }
for need in '_prot_hash() {' 'PROT_MAX_ENTRIES=' 'protected-in' 'realpath'; do
  grep -qF -- "$need" "$TMPD/block.sh" || { echo "抽取自检失败: 区块里没有 [$need]"; exit 1; }
done
{ printf 'CLI=%q\n' "$CLI"
  echo 'log(){ :; }'; echo 'push(){ :; }'
  cat "$TMPD/block.sh"
  echo '_prot_hash "$1"'
} > "$TMPD/fn.sh"
bash -n "$TMPD/fn.sh" || { echo "抽取的函数语法错误"; exit 1; }

mkrepo() {   # $1=名字 → 回显仓库路径
  local r="$TMPD/$1"; mkdir -p "$r"
  git -C "$r" init -q . && git -C "$r" config user.email t@t && git -C "$r" config user.name t
  printf 'x\n' > "$r/README.md"
  printf '%s\n' "$r"
}

# ── 核心性质: 快照 ⊇ 权威判定 ─────────────────────────────────────────
# ⚠️ 判据必须是「**改动能被检出**」，不是「路径字符串出现在快照里」（Codex R9 #13）。
#    子串命中太弱: 缺失的 `foo.env` 会被 `foo.env.backup` 的哈希行误命中；符号链接光凭
#    恒定的 LINK 行就能"通过"，哪怕目标内容压根没进摘要。所以这里对**每一个**权威判定为
#    受保护的对象，逐个做「改它 → 快照必须变 → 改回」的前后对比。
assert_covers() {
  local repo="$1" label="$2"
  local snap lst prot missing=""
  snap="$(bash "$TMPD/fn.sh" "$repo" 2>/dev/null)" || { bad "$label: _prot_hash 返回非零"; return; }
  lst="$TMPD/lst.$$"
  # BSD sed 没有 -z，不去 `./` 前缀——权威判定与后续 "$repo/$p" 拼接都不受影响
  ( cd "$repo" && find . \( -type f -o -type l \) -not -path './.git/*' -print0 ) > "$lst"
  prot="$(node "$CLI" protected-in --null "$lst" 2>/dev/null)" || { bad "$label: protected-in 失败"; return; }
  local pf="$TMPD/pf.$$"
  printf '%s' "$prot" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{(JSON.parse(s).protected||[]).forEach(x=>process.stdout.write(x+"\0"))}catch{process.exit(1)}})' > "$pf"
  [ -s "$pf" ] || { bad "$label: 权威判定认为没有受保护文件，测试用例本身失效"; return; }
  local p before after saved
  while IFS= read -r -d '' p; do
    [ -z "$p" ] && continue
    [ -L "$repo/$p" ] && continue                      # 链接由下面的专项断言覆盖；
                                                       # 在这里写它会穿到仓库外（曾试图写 /etc/hosts）
    [ -f "$repo/$p" ] || continue                      # 目录/悬空链接另有断言
    before="$(bash "$TMPD/fn.sh" "$repo" 2>/dev/null)" || { missing="${missing}${p} (快照失败)"$'\n'; continue; }
    saved="$(cat "$repo/$p" 2>/dev/null)"
    printf 'PROBE-%s\n' "$$" > "$repo/$p" 2>/dev/null || continue
    after="$(bash "$TMPD/fn.sh" "$repo" 2>/dev/null)" || after=""
    printf '%s\n' "$saved" > "$repo/$p" 2>/dev/null
    [ "$before" = "$after" ] && missing="${missing}${p}"$'\n'
  done <"$pf"
  rm -f "$pf" "$lst"
  if [ -n "$missing" ]; then
    bad "$label: 权威判定受保护，但改动**检不出**:"; printf '%s' "$missing" | sed 's/^/       /'
  else
    ok "$label"
  fi
}

# 改动任一受保护文件后，快照必须变化（正对照，防「测试本身失效」）
assert_detects() {
  local repo="$1" target="$2" label="$3"
  local a b
  a="$(bash "$TMPD/fn.sh" "$repo" 2>/dev/null)" || { bad "$label: 首次快照失败"; return; }
  printf 'TAMPERED-%s\n' "$$" > "$repo/$target"
  b="$(bash "$TMPD/fn.sh" "$repo" 2>/dev/null)" || { bad "$label: 二次快照失败"; return; }
  [ "$a" != "$b" ] && ok "$label" || bad "$label: 改动 $target 后快照不变"
}

echo "prot-hash 性质回归"

# 1) 被忽略目录下的各类受保护文件（R6/R7/R8 全部回归点）
R="$(mkrepo ignored)"
printf 'tmp/\n' > "$R/.gitignore"
mkdir -p "$R/tmp/legal" "$R/tmp/契約" "$R/tmp/.ssh"
printf 'a\n' > "$R/tmp/.env"
printf 'b\n' > "$R/tmp/合同-2026.docx"
printf 'c\n' > "$R/tmp/契約/条項.txt"
printf 'd\n' > "$R/tmp/legal/notes.txt"
printf 'e\n' > "$R/tmp/serviceaccount.json"
printf 'f\n' > "$R/tmp/.ssh/id_ed25519"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm base >/dev/null 2>&1
assert_covers "$R" "被忽略目录下的受保护文件（CJK 词 / 目录名 / 无分隔符 / .ssh）"
assert_detects "$R" "tmp/合同-2026.docx" "改 CJK 合同文件被检出"
assert_detects "$R" "tmp/legal/notes.txt" "改 legal/ 目录下普通文件名被检出"

# 2) 大型普通被忽略目录不得导致失败关闭（R7 #2 回归点）
R2="$(mkrepo bigignored)"
printf 'node_modules/\n' > "$R2/.gitignore"
mkdir -p "$R2/node_modules/pkg"
i=0; while [ $i -lt 600 ]; do printf 'x' > "$R2/node_modules/pkg/f$i.js"; i=$((i+1)); done
printf 'k\n' > "$R2/node_modules/pkg/.env"
git -C "$R2" add -A >/dev/null 2>&1; git -C "$R2" commit -qm base >/dev/null 2>&1
if bash "$TMPD/fn.sh" "$R2" >/dev/null 2>&1; then ok "含 600 个普通文件的 node_modules 不导致失败关闭"
else bad "含 600 个普通文件的 node_modules 让 _prot_hash 失败（R7 #2 回归）"; fi
assert_covers "$R2" "大型忽略目录内的 .env 仍被覆盖"

# 3) 符号链接四形态（R6 #5 / R7 #3 / R8 #4 回归点）
R3="$(mkrepo links)"
mkdir -p "$R3/data" "$R3/tmp" "$R3/realdir"
printf 'tmp/\n' > "$R3/.gitignore"
printf 'orig\n' > "$R3/data/blob.txt"
printf 'inner\n' > "$R3/realdir/a"
ln -s ../data/blob.txt "$R3/tmp/.env"          # 链接文本带路径（R8 #4 的核心用例）
ln -s /etc/hosts       "$R3/tmp/.env.outside"
ln -s ../nonexistent/x "$R3/tmp/.env.dangling"
ln -s ../realdir       "$R3/tmp/.env.dir"
git -C "$R3" add -A >/dev/null 2>&1; git -C "$R3" commit -qm base >/dev/null 2>&1
assert_covers "$R3" "四种符号链接形态都进快照"
snapA="$(bash "$TMPD/fn.sh" "$R3" 2>/dev/null)"
printf 'CHANGED\n' > "$R3/data/blob.txt"
snapB="$(bash "$TMPD/fn.sh" "$R3" 2>/dev/null)"
[ "$snapA" != "$snapB" ] && ok "改带路径链接所指的内容被检出（R7 #3 只覆盖了同目录裸文件名）" \
                          || bad "改 data/blob.txt 未被检出"
printf 'CHANGED\n' > "$R3/realdir/a"
snapC="$(bash "$TMPD/fn.sh" "$R3" 2>/dev/null)"
[ "$snapB" != "$snapC" ] && ok "改指向目录的链接内的文件被检出" || bad "改 realdir/a 未被检出"
printf '%s' "$snapC" | grep -q 'OUTSIDE-REPO' && ok "仓库外链接记 OUTSIDE-REPO 且不跟随" \
                                              || bad "仓库外链接未记 OUTSIDE-REPO"

# 3b) 受保护链接指向仓库根（R9 #4 回归点）
R3b="$(mkrepo rootlink)"
mkdir -p "$R3b/tmp"; printf 'tmp/\n' > "$R3b/.gitignore"; printf 'PLAIN\n' > "$R3b/plain.txt"
ln -s .. "$R3b/tmp/.env.dir"
git -C "$R3b" add -A >/dev/null 2>&1; git -C "$R3b" commit -qm base >/dev/null 2>&1
rl1="$(bash "$TMPD/fn.sh" "$R3b" 2>/dev/null)"
printf '%s' "$rl1" | grep -q 'OUTSIDE-REPO' && bad "指向仓库根的链接被误记 OUTSIDE-REPO（R9 #4 回归）" \
                                            || ok "指向仓库根的链接判为仓库内"
printf 'CHANGED\n' > "$R3b/plain.txt"
rl2="$(bash "$TMPD/fn.sh" "$R3b" 2>/dev/null)"
[ "$rl1" != "$rl2" ] && ok "经仓库根链接改动仓库内文件被检出" || bad "改 plain.txt 未被检出（R9 #4 回归）"

# 3c) 文件名含换行（R9 #3 回归点）——整条管线必须是 NUL 协议
R3c="$(mkrepo newline)"
NLNAME="$(printf 'legal\nnotes.txt')"
printf 'SECRET\n' > "$R3c/$NLNAME"
git -C "$R3c" add -A >/dev/null 2>&1; git -C "$R3c" commit -qm base >/dev/null 2>&1
nl1="$(bash "$TMPD/fn.sh" "$R3c" 2>/dev/null)"
if [ -z "$nl1" ]; then
  bad "含换行的受保护文件名: 快照为空（R9 #3 回归）"
else
  printf 'TAMPERED\n' > "$R3c/$NLNAME"
  nl2="$(bash "$TMPD/fn.sh" "$R3c" 2>/dev/null)"
  [ "$nl1" != "$nl2" ] && ok "含换行的受保护文件名改动被检出（R9 #3）" \
                       || bad "含换行的受保护文件名改动未检出（R9 #3 回归）"
fi

# 3d) 受保护目录里的**嵌套目录链接**（R10 #2 回归点）
# `.env.dir -> data`、`data/nested -> ../target`，改 target/plain.txt 必须被检出。
# R9 那版只做一层 find|shasum，遇到嵌套链接时 shasum 失败被 `|| UNREADABLE` 兜底成常量——
# 兜底成常量比不摘要更糟，它让漏检看起来像已覆盖。
R3d="$(mkrepo nested)"
mkdir -p "$R3d/data" "$R3d/target" "$R3d/tmp"
printf 'tmp/\n' > "$R3d/.gitignore"; printf 'ORIG\n' > "$R3d/target/plain.txt"
ln -s ../target "$R3d/data/nested"
ln -s ../data   "$R3d/tmp/.env.dir"
git -C "$R3d" add -A >/dev/null 2>&1; git -C "$R3d" commit -qm base >/dev/null 2>&1
nd1="$(bash "$TMPD/fn.sh" "$R3d" 2>/dev/null)"
printf 'TAMPERED\n' > "$R3d/target/plain.txt"
nd2="$(bash "$TMPD/fn.sh" "$R3d" 2>/dev/null)"
[ "$nd1" != "$nd2" ] && ok "经嵌套目录链接的改动被检出（R10 #2）" \
                     || bad "经嵌套目录链接的改动未检出（R10 #2 回归）"

# 3e) 目录链接成环不得死循环
ln -sfn ../data "$R3d/data/loop"
ln -sfn ../target "$R3d/target/back"
( bash "$TMPD/fn.sh" "$R3d" >/dev/null 2>&1 ) & cyc=$!
cn=0; while kill -0 $cyc 2>/dev/null && [ $cn -lt 30 ]; do sleep 1; cn=$((cn+1)); done
if kill -0 $cyc 2>/dev/null; then kill -9 $cyc 2>/dev/null; bad "目录链接成环导致死循环（>30s）"
else wait $cyc 2>/dev/null; ok "目录链接成环时正常终止（visited 防环）"; fi

# 3f) 目录内不可读的文件必须失败关闭，而不是记一个常量
R3f="$(mkrepo unreadable)"
mkdir -p "$R3f/data" "$R3f/tmp"; printf 'tmp/\n' > "$R3f/.gitignore"
printf 'S\n' > "$R3f/data/secret.bin"; chmod 000 "$R3f/data/secret.bin"
ln -s ../data "$R3f/tmp/.env.dir"
git -C "$R3f" add -A >/dev/null 2>&1; git -C "$R3f" commit -qm base >/dev/null 2>&1
if bash "$TMPD/fn.sh" "$R3f" >/dev/null 2>&1; then
  bad "目录内有不可读文件时仍返回成功（应失败关闭）"
else ok "目录内有不可读文件时失败关闭"; fi
chmod 644 "$R3f/data/secret.bin" 2>/dev/null

# 3g) 含换行的目录名不得欺骗 visited 集（Codex R11 #3 回归点）
# 路径写进按行分隔的 visited 文件时，目录名 `z\nfoo` 会裂成两条，
# 留下的 `/repo/.../z` 那行会让后来真实的 `z` 目录被误判成环而整个跳过。
# 现在 visited 存的是 dev:inode，天然无换行。
R3g="$(mkrepo nlvisited)"
mkdir -p "$R3g/data" "$R3g/tmp"
printf 'tmp/\n' > "$R3g/.gitignore"
NLDIR="$(printf 'z\nfoo')"
mkdir -p "$R3g/data/$NLDIR" "$R3g/data/z"
printf 'A\n' > "$R3g/data/$NLDIR/a.txt"
printf 'B\n' > "$R3g/data/z/b.txt"
ln -s ../data "$R3g/tmp/.env.dir"
git -C "$R3g" add -A >/dev/null 2>&1; git -C "$R3g" commit -qm base >/dev/null 2>&1
v1="$(bash "$TMPD/fn.sh" "$R3g" 2>/dev/null)"
printf 'CHANGED\n' > "$R3g/data/z/b.txt"
v2="$(bash "$TMPD/fn.sh" "$R3g" 2>/dev/null)"
[ "$v1" != "$v2" ] && ok "含换行的兄弟目录不影响真实目录的检出（R11 #3）" \
                   || bad "真实目录被误判成环，改动漏检（R11 #3 回归）"

# 3h) 批量哈希与逐个哈希必须等价（R19 自查）
# R10 我为「避免 xargs 分批影响结果」改成逐个 shasum，没测代价——1 万个受保护文件
# 要 81 秒（每文件一次进程创建），而 snapshot 与 verify 每个任务各跑一次。
# 改回批量 + sort（分批的顺序问题 sort 就解决了）后 0.27 秒。这里断言两点:
# 内容正确（改任一文件都检出）+ 条数对得上（xargs 遇错会继续处理其余批次）。
R3h="$(mkrepo bulk)"
mkdir -p "$R3h/contracts"
i=0; while [ $i -lt 60 ]; do printf 'c%s\n' "$i" > "$R3h/contracts/doc$i.txt"; i=$((i+1)); done
git -C "$R3h" add -A >/dev/null 2>&1; git -C "$R3h" commit -qm base >/dev/null 2>&1
bk1="$(bash "$TMPD/fn.sh" "$R3h" 2>/dev/null)"
lines="$(printf '%s\n' "$bk1" | grep -c . )"
[ "$lines" -ge 60 ] && ok "批量哈希覆盖全部 ${lines} 个受保护文件" \
                    || bad "批量哈希只覆盖了 ${lines} 个（应 ≥60）"
printf 'TAMPERED\n' > "$R3h/contracts/doc37.txt"
bk2="$(bash "$TMPD/fn.sh" "$R3h" 2>/dev/null)"
[ "$bk1" != "$bk2" ] && ok "批量哈希下改任一受保护文件仍被检出" || bad "批量哈希漏检了改动"

# 3i) 临时文件不可写时必须失败关闭（Codex R20 #1 + 自查扩展）
# 磁盘满/配额/只读时 `: >` 与 `>>` 静默失败，而计数又是从那个空文件算出来的——
# 自洽但错误。实测过「退出码 0、stdout 零字节」的静默漏检（正常 185 字节）。
# Codex 报的是 plain（新写的），复现时发现 exp 上同一缺陷从 R8 起就在。
RO="$TMPD/readonly"; mkdir -p "$RO"; chmod 555 "$RO"
R3i="$(mkrepo tmpfail)"
mkdir -p "$R3i/contracts"; printf 'S\n' > "$R3i/contracts/a.pdf"
git -C "$R3i" add -A >/dev/null 2>&1; git -C "$R3i" commit -qm base >/dev/null 2>&1
CNTF="$TMPD/mkcnt"
cat > "$TMPD/fn_ro.sh" <<INJ
$(cat "$TMPD/fn.sh" | head -n -1)
INJ
# 在抽取的函数前插入会「产出不可写路径」的 mktemp 桩（计数必须落盘: \$(mktemp) 在子 shell 里跑）
{ printf 'CLI=%q\n' "$CLI"; echo 'log(){ :; }'; echo 'push(){ :; }'
  printf 'mktemp() { n=$(( $(cat %q) + 1 )); echo "$n" > %q; ' "$CNTF" "$CNTF"
  printf 'if [ "$n" = "$FAIL_AT" ]; then printf %%s "%s/nope.$$"; return 0; fi; command mktemp; }\n' "$RO"
  cat "$TMPD/block.sh"
  echo '_prot_hash "$1"'
} > "$TMPD/fn_ro.sh"
ro_fail=0
for k in 1 2 3 4; do
  echo 0 > "$CNTF"
  if FAIL_AT=$k bash "$TMPD/fn_ro.sh" "$R3i" >/dev/null 2>&1; then ro_fail=$((ro_fail+1)); fi
done
chmod 755 "$RO"
[ "$ro_fail" = 0 ] && ok "四个临时文件任一不可写都失败关闭" \
                   || bad "有 ${ro_fail} 个临时文件不可写时仍返回成功（静默漏检）"

# 4) 上限必须失败关闭而非静默少查（R6 #6 回归点，R7 重写时被删过）
sed 's/^PROT_MAX_ENTRIES=.*/PROT_MAX_ENTRIES=3/' "$TMPD/fn.sh" > "$TMPD/fn_low.sh"
if bash "$TMPD/fn_low.sh" "$R2" >/dev/null 2>&1; then
  bad "超过总条目上限时未失败关闭"
else ok "超过总条目上限时失败关闭"; fi

printf '\nprot-hash: pass %d / fail %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
