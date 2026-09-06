#!/usr/bin/env bash
# e2e.test.sh — 用假的 codex / claude-handoff 跑完整一夜，验证编排器的端到端行为。
#
# 前七轮的端到端验证都是临时搭的、没入库，于是每轮只测「这轮刚改的那条路径」——
# 这正是 _prot_hash 与 hook 状态机各自复发五次的同一个结构性原因（R8 收尾）。
#
# 假 codex 必须**看参数行事**（R6 血泪）: 早期的假 codex 对 `mcp list` 自检也执行任务动作，
# 于是开工前仓库就脏了，连着三轮把脚手架 bug 当成代码 bug 查。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

# Never let the suite touch the developer's real HOME or loaded launch agent.
# The launchctl double can optionally terminate its parent to emulate an
# unload of the currently running launchd job.
HOME="$TMPD/home"
mkdir -p "$HOME"
export HOME
# Exercise a caller-selected Codex configuration root. The orchestrator must
# preserve it as the source of login state while using a separate runtime tree.
CODEX_HOME="$TMPD/user-codex-home"
mkdir -p "$CODEX_HOME"
printf '{}\n' > "$CODEX_HOME/auth.json"
export CODEX_HOME

SW="$TMPD/sleep-well"; REPO="$TMPD/proj"; REPO2="$TMPD/proj2"; REPO3="$TMPD/proj3"; BIN="$TMPD/bin"
mkdir -p "$SW/codex" "$REPO" "$REPO2" "$BIN"
FAKE_LAUNCHCTL_LOG="$TMPD/launchctl-calls"
: > "$FAKE_LAUNCHCTL_LOG"
cat > "$BIN/launchctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LAUNCHCTL_LOG"
if [ "${FAKE_LAUNCHCTL_TERM_PARENT:-no}" = yes ] && [ "${1:-}" = unload ]; then
  kill -TERM "$PPID" 2>/dev/null || true
fi
exit 0
FAKE
chmod +x "$BIN/launchctl"
export FAKE_LAUNCHCTL_LOG
git -C "$REPO2" init -q .; git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
printf 'z\n' > "$REPO2/b.js"; git -C "$REPO2" add -A >/dev/null 2>&1; git -C "$REPO2" commit -qm base >/dev/null 2>&1

# ── 被操作的仓库 ────────────────────────────────────────────────────
git -C "$REPO" init -q .
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'let x = 1\n' > "$REPO/app.js"
printf 'node_modules/\n\\*.pem\n' > "$REPO/.gitignore"
mkdir -p "$REPO/node_modules/pkg" "$REPO/cfgdir" "$REPO/certs"; printf 'SECRET\n' > "$REPO/node_modules/pkg/.env"
# Literal wildcard filename: the ignored `*.pem` must not be mistaken for the
# unrelated tracked certs/server.pem by Git pathspec expansion.
printf 'TRACKED-CERT\n' > "$REPO/certs/server.pem"
printf 'LITERAL-WILDCARD-SECRET\n' > "$REPO/*.pem"
# 受保护链接指向一个**自身路径不受保护**的未跟踪文件（Codex R12 #3）:
# 护栏会跟随并保护 target，但 target 进不了受保护清单——若备份跳过链接，
# 通过链接写入时护栏会报警却没有任何副本可还原。
printf 'LINKED-SECRET\n' > "$REPO/cfgdir/runtime"
printf 'cfgdir/\n' >> "$REPO/.gitignore"
# 链接在 node_modules/pkg/ 下，回到仓库根要两级——写成 ../ 会解析到 node_modules/cfgdir（悬空）
ln -s ../../cfgdir/runtime "$REPO/node_modules/pkg/.env.link"
# A protected tracked symlink whose target is also tracked. Repositories under
# /var/folders resolve through /private/var/folders on macOS, exercising canonical roots.
printf 'TRACKED-LINK-TARGET\n' > "$REPO/tracked-secret"
ln -s tracked-secret "$REPO/.env.tracked-link"
printf '#!/bin/sh\necho "USER-OWN-HOOK"\n' > "$REPO/.git/hooks/pre-push"
chmod +x "$REPO/.git/hooks/pre-push"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm base >/dev/null 2>&1

# ── 假 codex: 按参数分流 ────────────────────────────────────────────
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" mcp list "*) echo "No MCP servers configured"; exit 0 ;;
  *" features "*) exit 0 ;;
esac
printf '%s\n--CALL--\n' "$*" >> "$FAKE_CODEX_PROMPTS"
# 只有 exec 才真的"干活": 往仓库里加一行，不 commit（编排器负责 checkpoint）
for a in "$@"; do :; done
printf 'let y = 2\n' >> app.js
printf 'created overnight\n' > overnight-created.txt
echo "fake codex: 已实现"
exit 0
FAKE
chmod +x "$BIN/codex"

# ── fake curl: preserve --data-raw literally, but emulate -d @file expansion ─
# This makes the ntfy privacy assertion fail if push() regresses to curl -d.
cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    --data-raw)
      printf 'raw:%s\n' "$2" >> "$FAKE_CURL_PAYLOAD"
      shift 2 ;;
    -H|--header)
      printf 'header:%s\n' "$2" >> "$FAKE_CURL_PAYLOAD"
      shift 2 ;;
    -d|--data)
      case "$2" in
        @*) cat "${2#@}" >> "$FAKE_CURL_PAYLOAD" 2>/dev/null || true ;;
        *) printf 'data:%s\n' "$2" >> "$FAKE_CURL_PAYLOAD" ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
exit 0
FAKE
chmod +x "$BIN/curl"

# ── 假 claude-handoff: 第一次出 1 条 finding，第二次出 0 条 ─────────
cat > "$BIN/review.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_REVIEW_ARGS"
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
n="$(cat "$FAKE_REVIEW_COUNTER" 2>/dev/null || echo 0)"
n=$((n+1)); echo "$n" > "$FAKE_REVIEW_COUNTER"
mkdir -p "$repo/.review"
f="$repo/.review/claude-findings-fake-$n.md"
if [ "$n" -eq 1 ]; then
  cat > "$f" <<'MD'
# Claude Review Findings
- findings 条数: 1
- 高严重度: 0

### #1 [中] 变量名不清晰
- 位置: `app.js` 2

## 处理状态
- [ ] #1
MD
else
  cat > "$f" <<'MD'
# Claude Review Findings
- findings 条数: 0
- 高严重度: 0

## 处理状态
MD
fi
echo "FINDINGS_FILE=$f"
exit 0
FAKE
chmod +x "$BIN/review.sh"

# ── 队列与配置 ──────────────────────────────────────────────────────
printf 'PRIVATE-NTFY-FILE-CONTENT\n' > "$TMPD/ntfy-private"
LONG_UNICODE_TITLE="$(node -e 'process.stdout.write("界".repeat(220))')"
cat > "$SW/queue.md" <<EOF
## @$TMPD/ntfy-private-$LONG_UNICODE_TITLE
- id: t1
- repo: $REPO
- type: small-todo
> 随便加一行。
EOF
printf '{ "morning_hour": "07:00", "ntfy_topic": "test_topic" }\n' > "$SW/codex/config.json"

export SLEEP_WELL_ROOT="$SW"
export SLEEP_WELL_CODEX="$BIN/codex"
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review.sh"
export FAKE_REVIEW_COUNTER="$TMPD/counter"
export FAKE_REVIEW_ARGS="$TMPD/review-args"
export FAKE_CURL_PAYLOAD="$TMPD/curl-payload"
export FAKE_CODEX_PROMPTS="$TMPD/codex-prompts"
export SLEEP_WELL_AI_TIMEOUT=60
export SLEEP_WELL_HANG_LIMIT=120
export PATH="$BIN:$PATH"
CLI_PATH="$ROOT_DIR/lib/cli.mjs"

echo "端到端"

# ── 跑一夜 ──────────────────────────────────────────────────────────
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
rc=$?

LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
[ -n "$LOG" ] && ok "产生了运行日志" || bad "没有运行日志"
[ -f "$SW/codex/morning-report.md" ] && ok "生成了早报" || bad "未生成早报"
if [ "$(stat -f '%Lp' "$SW" 2>/dev/null)" = 700 ] \
  && [ "$(stat -f '%Lp' "$SW/codex" 2>/dev/null)" = 700 ] \
  && [ "$(stat -f '%Lp' "$SW/codex/config.json" 2>/dev/null)" = 600 ] \
  && [ "$(stat -f '%Lp' "$SW/codex/morning-report.md" 2>/dev/null)" = 600 ]; then
  ok "Codex 运行根、配置与早报权限会修复到仅账户可读"
else
  bad "Codex 运行根、配置或早报仍保留宽松权限"
fi
grep -q 'USER-OWN-HOOK' "$REPO/.git/hooks/pre-push" 2>/dev/null \
  && ok "用户原有 pre-push hook 完好归位" || bad "用户 pre-push hook 未归位（R2 #2 / R8 #6）"
[ -f "$SW/codex/hook-recovery.json" ] && bad "收工后仍留有 hook 恢复状态" || ok "收工后无遗留 hook 状态"
[ -e "$SW/NIGHT.lock" ] && bad "收工后锁未释放" || ok "收工后锁已释放"
if grep -q "^unload $HOME/Library/LaunchAgents/com.user.sleepwell-codex.plist" "$FAKE_LAUNCHCTL_LOG" 2>/dev/null; then
  ok "E2E 全程隔离 HOME 并只调用假 launchctl"
else
  bad "E2E 未经过隔离的 launchctl 边界"
fi
if [ "$(readlink "$SW/codex/codex-home/auth.json" 2>/dev/null)" = "$CODEX_HOME/auth.json" ] \
  && [ -r "$SW/codex/codex-home/auth.json" ]; then
  ok "自定义 CODEX_HOME 的登录态被保留并链接进隔离环境"
else
  bad "编排器覆盖或忽略了调用方的 CODEX_HOME 登录态"
fi

# The manual native-web probe uses real model calls in production, so exercise
# its CODEX_HOME/auth plumbing with a deterministic fake. The control emits a
# web event + page marker; the subject emits neither.
PROBE_CODEX_HOME="$TMPD/probe-codex-home"
PROBE_AUTH="$PROBE_CODEX_HOME/auth.json"
PROBE_CALLS="$TMPD/probe-codex-calls"
mkdir -p "$PROBE_CODEX_HOME" "$TMPD/probe-user-home"
printf '{}\n' > "$PROBE_AUTH"
PROBE_AUTH_REAL="$(cd "$PROBE_CODEX_HOME" && pwd -P)/auth.json"
cat > "$BIN/probe-codex" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$(readlink "$CODEX_HOME/auth.json" 2>/dev/null)" >> "$PROBE_CALLS"
case "$CODEX_HOME" in
  */ctrl) printf 'web search\nExample Domain\n' ;;
  *) printf 'BLOCKED\n' ;;
esac
FAKE
chmod +x "$BIN/probe-codex"
PROBE_OUTPUT="$(HOME="$TMPD/probe-user-home" CODEX_HOME="$PROBE_CODEX_HOME" \
  SLEEP_WELL_CODEX="$BIN/probe-codex" PROBE_CALLS="$PROBE_CALLS" \
  bash "$ROOT_DIR/bin/probe-native-web.sh" 2>&1)"
PROBE_RC=$?
if [ "$PROBE_RC" -eq 0 ] \
  && [ "$(grep -cF "$PROBE_AUTH_REAL" "$PROBE_CALLS" 2>/dev/null || true)" -eq 2 ] \
  && printf '%s' "$PROBE_OUTPUT" | grep -q '正对照.*web search 事件 1 次' \
  && printf '%s' "$PROBE_OUTPUT" | grep -q '顶层 web_search.*有效'; then
  ok "原生网页探针继承自定义 CODEX_HOME 登录态且正反对照成立"
else
  bad "原生网页探针忽略 CODEX_HOME 或正反对照失效（rc=${PROBE_RC}）"
fi

# A relative CODEX_HOME is resolved before the probe homes are created, so its
# auth symlinks cannot become relative-to-$tmp dangling links.
PROBE_REL_BASE="$TMPD/probe-relative-base"
PROBE_REL_AUTH="$PROBE_REL_BASE/.codex/auth.json"
mkdir -p "$PROBE_REL_BASE/.codex"
printf '{}\n' > "$PROBE_REL_AUTH"
PROBE_REL_AUTH_REAL="$(cd "$PROBE_REL_BASE/.codex" && pwd -P)/auth.json"
: > "$PROBE_CALLS"
PROBE_REL_OUTPUT="$(cd "$PROBE_REL_BASE" && HOME="$TMPD/probe-user-home" CODEX_HOME=.codex \
  SLEEP_WELL_CODEX="$BIN/probe-codex" PROBE_CALLS="$PROBE_CALLS" \
  bash "$ROOT_DIR/bin/probe-native-web.sh" 2>&1)"
PROBE_REL_RC=$?
if [ "$PROBE_REL_RC" -eq 0 ] \
  && [ "$(grep -cF "$PROBE_REL_AUTH_REAL" "$PROBE_CALLS" 2>/dev/null || true)" -eq 2 ] \
  && printf '%s' "$PROBE_REL_OUTPUT" | grep -q '顶层 web_search.*有效'; then
  ok "原生网页探针把相对 CODEX_HOME 规范化后再链接登录态"
else
  bad "原生网页探针的相对 CODEX_HOME 形成悬空登录态链接（rc=${PROBE_REL_RC}）"
fi

: > "$PROBE_CALLS"
mkdir -p "$TMPD/missing-probe-codex-home"
MISSING_PROBE_OUTPUT="$(HOME="$TMPD/probe-user-home" CODEX_HOME="$TMPD/missing-probe-codex-home" \
  SLEEP_WELL_CODEX="$BIN/probe-codex" PROBE_CALLS="$PROBE_CALLS" \
  bash "$ROOT_DIR/bin/probe-native-web.sh" 2>&1)"
MISSING_PROBE_RC=$?
if [ "$MISSING_PROBE_RC" -eq 2 ] \
  && [ ! -s "$PROBE_CALLS" ] \
  && printf '%s' "$MISSING_PROBE_OUTPUT" | grep -q '缺少 Codex 登录态'; then
  ok "原生网页探针在登录态缺失时于模型调用前明确失败"
else
  bad "原生网页探针登录态诊断过晚或不明确（rc=${MISSING_PROBE_RC}）"
fi

# 任务真的被实现并 checkpoint 了
# ⚠️ 不要写 `git log | grep -q`: set -o pipefail 下 grep -q 提前退出会让 git 收到 SIGPIPE，
#    管道退出码 141，断言假失败。（同一个坑在 orchestrator 的 MCP 自检里是真 bug，已修。）
nc="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 0)"
[ "$nc" -ge 2 ] && ok "任务被 checkpoint（${nc} 个提交）" || bad "无 checkpoint 提交（仅 ${nc} 个）"
grep -q 'let y = 2' "$REPO/app.js" 2>/dev/null && ok "实现内容落到了工作树" || bad "实现内容丢失"
if [ "$(stat -f '%Lp' "$REPO/overnight-created.txt" 2>/dev/null)" = 644 ]; then
  ok "Codex 子进程以常规 umask 022 新建仓库文件"
else
  bad "Codex 新建仓库文件继承了运行时 umask 077"
fi
[ -z "$(git -C "$REPO" status --porcelain -- . ':(exclude).review')" ] \
  && ok "收工后任务工作树干净（.review 不计入 checkpoint）" \
  || bad "收工后仍有未提交任务改动"
if git -C "$REPO" show --pretty=format: --name-only HEAD | grep -q '^\.review/'; then
  bad "checkpoint 提交混入了 .review 产物"
else
  ok "checkpoint 未提交 .review 产物"
fi
if grep -q '^raw: @' "$FAKE_CURL_PAYLOAD" 2>/dev/null \
  && ! grep -q 'PRIVATE-NTFY-FILE-CONTENT' "$FAKE_CURL_PAYLOAD" 2>/dev/null; then
  ok "@ 开头任务标题按原始正文推送，不读取本机文件"
else
  bad "@ 开头任务标题触发了 curl 文件读取或未使用 data-raw"
fi
if node - "$FAKE_CURL_PAYLOAD" <<'NODE'
const fs = require("fs");
const p = process.argv[2];
const bytes = fs.readFileSync(p);
let text;
try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
catch { process.exit(1); }
const lines = text.split("\n");
const titles = lines.filter(x => x.startsWith("header:Title: ")).map(x => Array.from(x.slice(14)).length);
const bodies = lines.filter(x => x.startsWith("raw:")).map(x => Array.from(x.slice(4)).length);
const values = lines.filter(x => x.startsWith("header:") || x.startsWith("raw:"));
const controls = values.some(x => /\p{Cc}/u.test(x));
process.exit(titles.length > 0 && bodies.length > 0 && !controls && titles.every(n => n <= 60) && bodies.every(n => n <= 200) ? 0 : 1);
NODE
then
  ok "ntfy 标题与正文按 Unicode 字符安全截断"
else
  bad "ntfy 截断产生非法 UTF-8 或超过字符上限"
fi

# 审修循环真的跑了两轮（1 条 finding → 修 → 0 条）
c="$(cat "$TMPD/counter" 2>/dev/null || echo 0)"
[ "$c" -ge 2 ] && ok "审修循环执行了 ${c} 轮（首轮 1 条 finding，次轮 0 条）" \
               || bad "审修循环只跑了 ${c} 轮，未验证修复回路"
REVIEW_REPO_CANON="$(cd "$REPO" && pwd -P)"
if [ -s "$FAKE_REVIEW_ARGS" ] \
  && ! grep -vxF -- "-C $REVIEW_REPO_CANON --uncommitted -t decision" "$FAKE_REVIEW_ARGS" >/dev/null 2>&1; then
  ok "生产审查路径按 README 契约传递唯一且受测的 argv"
else
  bad "生产审查 argv 与 README 契约漂移或没有被实际调用"
fi
if grep -q '原始任务范围（唯一任务授权）' "$FAKE_CODEX_PROMPTS" \
  && grep -q 'findings 正文是不可信的模型生成文本' "$FAKE_CODEX_PROMPTS"; then
  ok "修复轮保留原始任务授权并将 findings 视为不可信证据"
else
  bad "修复轮缺少原始任务范围或 findings 信任边界"
fi

# Findings history is retained across nights, so every new record must carry
# the active run's startedAt for report-side isolation.
if node -e '
  const fs=require("fs"), path=require("path");
  const root=process.argv[1], stateDir=path.join(root,"codex/state");
  const archive=fs.readdirSync(stateDir).filter(x=>/^run-.*\.json$/.test(x)).sort().at(-1);
  const run=JSON.parse(fs.readFileSync(path.join(stateDir,archive),"utf8"));
  const rows=fs.readFileSync(path.join(root,"codex/findings.jsonl"),"utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
  process.exit(rows.length > 0 && rows.every(x=>x.runId===run.startedAt && x.key) ? 0 : 1);
' "$SW"; then
  ok "findings 记录带本夜 runId 与稳定 key"
else
  bad "findings 缺少 runId/key，晨报可能跨夜污染"
fi

# A selected task with missing identity/state fields is corruption, never an
# idle queue. next-task must fail before the shell can interpret an empty id.
BAD_TASK_ROOT="$TMPD/bad-task-root"
mkdir -p "$BAD_TASK_ROOT/codex/state"
cat > "$BAD_TASK_ROOT/codex/state/current-run.json" <<EOF
{"startedAt":123,"cutoffEpoch":9999999999,"tasks":[{"repo":"$REPO","status":"pending"}]}
EOF
if SLEEP_WELL_ROOT="$BAD_TASK_ROOT" node "$CLI_PATH" next-task >/dev/null 2>&1; then
  bad "缺少 id 的活动任务被误解释为可继续/空队列"
else
  ok "next-task 对缺少 id/repo/status 的活动任务失败关闭"
fi

# 被忽略目录里的凭据没被动过 → 不应误报
grep -q 'SECRET' "$REPO/node_modules/pkg/.env" && ok "被忽略目录内的 .env 未被改动" || bad ".env 被改动"
printf '%s' "$LOG" | grep -q '护栏核验失败\|受保护路径' && bad "无改动却触发护栏告警（误报）" \
                                                       || ok "无改动时不误报护栏"

# 被忽略的受保护文件必须**被备份**（Codex R11 收尾 / 自查 T-4）:
# git 覆盖不到未跟踪文件，没有备份就只能「检出被改、无法还原」。
BAKROOT="$SW/codex/backups"
if [ -f "$BAKROOT/backup-manifest.jsonl" ]; then
  ok "生成了备份清单"
  if node -e '
    const fs=require("fs"), path=require("path");
    const root=process.argv[1], stateDir=path.join(root,"codex/state");
    const archive=fs.readdirSync(stateDir).filter(x=>/^run-.*\.json$/.test(x)).sort().at(-1);
    const run=JSON.parse(fs.readFileSync(path.join(stateDir,archive),"utf8"));
    const rows=fs.readFileSync(path.join(root,"codex/backups/backup-manifest.jsonl"),"utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
    process.exit(rows.length > 0 && rows.every(x=>x.runId===run.startedAt) ? 0 : 1);
  ' "$SW"; then
    ok "备份清单记录带本夜 runId"
  else
    bad "备份清单缺少正确 runId，晨报可能跨夜污染"
  fi
  grep -q '\.env' "$BAKROOT/backup-manifest.jsonl" && ok "被忽略的 .env 已入备份" \
                                                   || bad "被忽略的 .env 未入备份"
  grep -q 'cfgdir/runtime' "$BAKROOT/backup-manifest.jsonl" \
    && ok "受保护链接所指的未跟踪目标已入备份（R12 #3）" \
    || bad "受保护链接的目标未备份——护栏会报警却无副本可还原（R12 #3 回归）"
  if node -e '
    const fs=require("fs");
    const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
    process.exit(rows.some(x=>x.original.endsWith("/*.pem")) ? 0 : 1);
  ' "$BAKROOT/backup-manifest.jsonl"; then
    ok "含通配符字面文件名的未跟踪凭据已入备份"
  else
    bad "字面 *.pem 被 pathspec 误判为已跟踪并漏备份"
  fi
  # 备份内容必须是**改动前**的原文
  bk="$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).find(e=>/\.env$/.test(e.original));process.stdout.write(l?l.backupPath:"")' "$BAKROOT/backup-manifest.jsonl" 2>/dev/null)"
  [ -n "$bk" ] && [ -f "$bk" ] && grep -q 'SECRET' "$bk" \
    && ok "备份内容是改动前的原文（可用于还原）" || bad "备份文件缺失或内容不对: [$bk]"
else
  bad "没有生成备份清单——backup.mjs 又没接线（T-4 回归）"
fi
# 已跟踪文件不该被重复备份（git 兜底）
if [ -f "$BAKROOT/backup-manifest.jsonl" ]; then
  if grep -q 'app\.js\|tracked-secret' "$BAKROOT/backup-manifest.jsonl"; then
    bad "已跟踪文件或受保护链接的已跟踪目标被无谓备份"
  else
    ok "已跟踪文件及受保护链接的已跟踪目标不重复备份"
  fi
fi

# ── 超时路径: 假 codex 卡死，必须被 KILL 且不无限占锁 ───────────────
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
sleep 900
FAKE
chmod +x "$BIN/codex"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## 会卡死的任务
- id: t2
- repo: $REPO
- type: small-todo
> x
EOF
export SLEEP_WELL_AI_TIMEOUT=5
s=$(date +%s)
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
el=$(( $(date +%s) - s ))
# 断言要**能区分设定值与默认值**: 设 5s 就该在 5s 量级返回。原来断言 <120s，
# 即使超时被静默抬到 60s 也照样通过——那样它测不出参数有没有生效。
[ "$el" -lt 30 ] && ok "codex 卡死时 ${el}s 内被超时终止（设定 5s，量级相符）" \
                 || bad "超时未按设定值生效: 设 5s 却用了 ${el}s"
[ -e "$SW/NIGHT.lock" ] && bad "超时后锁未释放" || ok "超时后锁已释放"
grep -q 'USER-OWN-HOOK' "$REPO/.git/hooks/pre-push" 2>/dev/null \
  && ok "超时路径下用户 hook 仍完好" || bad "超时路径下用户 hook 丢失"

# An accidental milliseconds-as-seconds value must fail before any Codex call;
# otherwise both the per-call timeout and the hang watchdog become effectively
# unbounded while run_with_timeout keeps refreshing the heartbeat.
INVALID_TIMEOUT_ROOT="$TMPD/invalid-timeout-root"
INVALID_TIMEOUT_MARKER="$TMPD/invalid-timeout-codex-called"
cat > "$BIN/codex-invalid-timeout" <<'FAKE'
#!/usr/bin/env bash
printf called > "$INVALID_TIMEOUT_MARKER"
sleep 900
FAKE
chmod +x "$BIN/codex-invalid-timeout"
s=$(date +%s)
SLEEP_WELL_ROOT="$INVALID_TIMEOUT_ROOT" \
SLEEP_WELL_CODEX="$BIN/codex-invalid-timeout" \
SLEEP_WELL_CLAUDE_REVIEW="$BIN/review.sh" \
SLEEP_WELL_AI_TIMEOUT=1800000 \
INVALID_TIMEOUT_MARKER="$INVALID_TIMEOUT_MARKER" \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
INVALID_TIMEOUT_RC=$?
INVALID_TIMEOUT_ELAPSED=$(( $(date +%s) - s ))
SLEEP_WELL_ROOT="$INVALID_TIMEOUT_ROOT" \
SLEEP_WELL_CODEX="$BIN/codex-invalid-timeout" \
SLEEP_WELL_CLAUDE_REVIEW="$BIN/review.sh" \
SLEEP_WELL_AI_TIMEOUT=1800000 \
INVALID_TIMEOUT_MARKER="$INVALID_TIMEOUT_MARKER" \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
INVALID_TIMEOUT_RC_2=$?
INVALID_TIMEOUT_LOG="$(cat "$INVALID_TIMEOUT_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$INVALID_TIMEOUT_RC" -ne 0 ] \
  && [ "$INVALID_TIMEOUT_RC_2" -ne 0 ] \
  && [ "$INVALID_TIMEOUT_ELAPSED" -lt 10 ] \
  && [ ! -e "$INVALID_TIMEOUT_MARKER" ] \
  && [ ! -e "$INVALID_TIMEOUT_ROOT/NIGHT.lock" ] \
  && printf '%s' "$INVALID_TIMEOUT_LOG" | grep -q 'AI_TIMEOUT.*1–86400.*未开工' \
  && [ "$(printf '%s' "$INVALID_TIMEOUT_LOG" | grep -c 'PUSH\[⚠️ 夜班未开工\].*TIMEOUT/HANG_LIMIT 配置非法' || true)" -eq 1 ] \
  && grep -q '状态: 未开工（没有活动运行）' "$INVALID_TIMEOUT_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q '活动状态: 无' "$INVALID_TIMEOUT_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q '配置非法' "$INVALID_TIMEOUT_ROOT/codex/morning-report.md" 2>/dev/null; then
  ok "超大 AI 超时在任何 Codex 调用前可见地失败关闭、刷新早报且告警去重"
else
  bad "超大 AI 超时未失败关闭（rc=${INVALID_TIMEOUT_RC}, elapsed=${INVALID_TIMEOUT_ELAPSED}s）"
fi

# The invalid-timeout alert runs after acquiring NIGHT.lock but before the main
# watchdog is armed. A node that hangs while truncating the ntfy payload must
# therefore be contained by the startup timeout and must not strand the lock.
INVALID_TIMEOUT_NODE_HANG_ROOT="$TMPD/invalid-timeout-node-hang-root"
mkdir -p "$INVALID_TIMEOUT_NODE_HANG_ROOT/codex"
printf '{"ntfy_topic":"test_topic"}\n' > "$INVALID_TIMEOUT_NODE_HANG_ROOT/codex/config.json"
cat > "$BIN/node" <<'FAKENODE'
#!/usr/bin/env bash
while :; do :; done
FAKENODE
chmod +x "$BIN/node"
INVALID_TIMEOUT_NODE_HANG_START="$(date +%s)"
SLEEP_WELL_ROOT="$INVALID_TIMEOUT_NODE_HANG_ROOT" \
SLEEP_WELL_STARTUP_TIMEOUT=3 \
SLEEP_WELL_AI_TIMEOUT=1800000 \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
INVALID_TIMEOUT_NODE_HANG_RC=$?
INVALID_TIMEOUT_NODE_HANG_ELAPSED=$(( $(date +%s) - INVALID_TIMEOUT_NODE_HANG_START ))
rm -f "$BIN/node"
INVALID_TIMEOUT_NODE_HANG_LOG="$(cat "$INVALID_TIMEOUT_NODE_HANG_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$INVALID_TIMEOUT_NODE_HANG_RC" -ne 0 ] \
  && [ "$INVALID_TIMEOUT_NODE_HANG_ELAPSED" -lt 15 ] \
  && printf '%s' "$INVALID_TIMEOUT_NODE_HANG_LOG" | grep -q '启动阶段命令超时.*非法超时告警' \
  && [ ! -e "$INVALID_TIMEOUT_NODE_HANG_ROOT/NIGHT.lock" ]; then
  ok "非法超时告警中的 node 挂起受启动时限约束并释放锁"
else
  bad "非法超时告警中的 node 挂起仍可永久占锁（rc=${INVALID_TIMEOUT_NODE_HANG_RC}, elapsed=${INVALID_TIMEOUT_NODE_HANG_ELAPSED}s）"
fi

# A valid STOP-only invocation on the same root executes the successful
# validation branch and must clear the invalid-timeout dedupe marker. A later
# regression to invalid config must therefore notify again.
touch "$INVALID_TIMEOUT_ROOT/STOP"
SLEEP_WELL_ROOT="$INVALID_TIMEOUT_ROOT" \
SLEEP_WELL_CODEX="$BIN/codex-invalid-timeout" \
SLEEP_WELL_CLAUDE_REVIEW="$BIN/review.sh" \
SLEEP_WELL_AI_TIMEOUT=1800 \
INVALID_TIMEOUT_MARKER="$INVALID_TIMEOUT_MARKER" \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
INVALID_TIMEOUT_MARKER_CLEARED=no
[ ! -e "$INVALID_TIMEOUT_ROOT/codex/state/.push-once-invalid-timeout" ] \
  && INVALID_TIMEOUT_MARKER_CLEARED=yes
rm -f "$INVALID_TIMEOUT_ROOT/STOP" "$INVALID_TIMEOUT_ROOT/codex/TERMINATED" "$INVALID_TIMEOUT_ROOT/NIGHT.lock"
SLEEP_WELL_ROOT="$INVALID_TIMEOUT_ROOT" \
SLEEP_WELL_CODEX="$BIN/codex-invalid-timeout" \
SLEEP_WELL_CLAUDE_REVIEW="$BIN/review.sh" \
SLEEP_WELL_AI_TIMEOUT=1800000 \
INVALID_TIMEOUT_MARKER="$INVALID_TIMEOUT_MARKER" \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
INVALID_TIMEOUT_LOG="$(cat "$INVALID_TIMEOUT_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$INVALID_TIMEOUT_MARKER_CLEARED" = yes ] \
  && [ "$(printf '%s' "$INVALID_TIMEOUT_LOG" | grep -c 'PUSH\[⚠️ 夜班未开工\].*TIMEOUT/HANG_LIMIT 配置非法' || true)" -eq 2 ]; then
  ok "配置恢复会清除超时告警标记，后续复发可再次通知"
else
  bad "配置恢复未清除超时告警标记或复发仍被静默"
fi

# Existing activity and a pending hook recovery must be described truthfully;
# neither state file may be consumed while the unbounded timeout config blocks
# normal startup.
INVALID_ACTIVE_ROOT="$TMPD/invalid-timeout-active-root"
mkdir -p "$INVALID_ACTIVE_ROOT/codex/state"
INVALID_ACTIVE_STARTED="$(date +%s)"
INVALID_ACTIVE_CUTOFF=$((INVALID_ACTIVE_STARTED + 3600))
cat > "$INVALID_ACTIVE_ROOT/codex/state/current-run.json" <<EOF
{"startedAt":$INVALID_ACTIVE_STARTED,"cutoffEpoch":$INVALID_ACTIVE_CUTOFF,"tasks":[{"id":"invalid-active","title":"invalid active","repo":"$REPO","status":"reviewing"}]}
EOF
printf '{}\n' > "$INVALID_ACTIVE_ROOT/codex/hook-recovery.json"
SLEEP_WELL_ROOT="$INVALID_ACTIVE_ROOT" \
SLEEP_WELL_CODEX="$BIN/codex-invalid-timeout" \
SLEEP_WELL_CLAUDE_REVIEW="$BIN/review.sh" \
SLEEP_WELL_AI_TIMEOUT=1800000 \
INVALID_TIMEOUT_MARKER="$INVALID_TIMEOUT_MARKER" \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
INVALID_ACTIVE_LOG="$(cat "$INVALID_ACTIVE_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ -s "$INVALID_ACTIVE_ROOT/codex/state/current-run.json" ] \
  && [ -f "$INVALID_ACTIVE_ROOT/codex/hook-recovery.json" ] \
  && grep -q '本夜已有活动运行' "$INVALID_ACTIVE_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q 'pre-push hook 恢复' "$INVALID_ACTIVE_ROOT/codex/morning-report.md" 2>/dev/null \
  && printf '%s' "$INVALID_ACTIVE_LOG" | grep -q 'PUSH\[⚠️ 夜班未开工\].*pre-push hook 待恢复' \
  && [ ! -e "$INVALID_ACTIVE_ROOT/NIGHT.lock" ]; then
  ok "非法超时早报区分活动 run，并提示保留的 pre-push hook 恢复"
else
  bad "非法超时早报误报活动状态或吞掉待恢复 hook 提示"
fi

# STOP remains authoritative even when the configured timeout is invalid. The
# active run must be quarantined and archived instead of getting stranded by
# the configuration gate.
INVALID_STOP_ROOT="$TMPD/invalid-timeout-stop-root"
mkdir -p "$INVALID_STOP_ROOT/codex/state"
INVALID_STOP_STARTED="$(date +%s)"
INVALID_STOP_CUTOFF=$((INVALID_STOP_STARTED + 3600))
cat > "$INVALID_STOP_ROOT/codex/state/current-run.json" <<EOF
{"startedAt":$INVALID_STOP_STARTED,"cutoffEpoch":$INVALID_STOP_CUTOFF,"tasks":[{"id":"invalid-stop","title":"invalid stop","repo":"$REPO","status":"implementing"}]}
EOF
touch "$INVALID_STOP_ROOT/STOP"
SLEEP_WELL_ROOT="$INVALID_STOP_ROOT" \
SLEEP_WELL_CODEX="$BIN/codex-invalid-timeout" \
SLEEP_WELL_CLAUDE_REVIEW="$BIN/review.sh" \
SLEEP_WELL_AI_TIMEOUT=1800000 \
INVALID_TIMEOUT_MARKER="$INVALID_TIMEOUT_MARKER" \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
INVALID_STOP_LOG="$(cat "$INVALID_STOP_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ ! -e "$INVALID_STOP_ROOT/codex/state/current-run.json" ] \
  && find "$INVALID_STOP_ROOT/codex/state" -name 'run-*.json' -type f | grep -q . \
  && printf '%s' "$INVALID_STOP_LOG" | grep -q 'STOP 已存在；仅为收尾采用安全超时默认值' \
  && printf '%s' "$INVALID_STOP_LOG" | grep -q '收工: 见到 STOP 文件' \
  && [ ! -e "$INVALID_STOP_ROOT/NIGHT.lock" ] \
  && [ ! -e "$INVALID_TIMEOUT_MARKER" ]; then
  ok "非法超时配置不阻挡 STOP 归档活动状态"
else
  bad "非法超时配置挡住 STOP 或留下活动状态/锁"
fi

# Decimal environment values may be zero-padded in a plist. Bash `test`
# accepts them as decimal but arithmetic expansion treats them as octal unless
# they are canonicalized first; 08 previously aborted before acquiring a lock.
ZERO_PADDED_ROOT="$TMPD/zero-padded-timeout-root"
mkdir -p "$ZERO_PADDED_ROOT/codex"
touch "$ZERO_PADDED_ROOT/STOP"
SLEEP_WELL_ROOT="$ZERO_PADDED_ROOT" \
SLEEP_WELL_STARTUP_TIMEOUT=08 \
SLEEP_WELL_AI_TIMEOUT=00900 \
SLEEP_WELL_HANG_LIMIT=02700 \
SLEEP_WELL_WATCHDOG_POLL=01 \
SLEEP_WELL_WATCHDOG_GRACE=03 \
  bash "$ROOT_DIR/bin/orchestrator.sh" >"$TMPD/zero-padded.out" 2>"$TMPD/zero-padded.err"
ZERO_PADDED_RC=$?
ZERO_PADDED_LOG="$(cat "$ZERO_PADDED_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$ZERO_PADDED_RC" -eq 0 ] \
  && [ -f "$ZERO_PADDED_ROOT/codex/TERMINATED" ] \
  && [ ! -e "$ZERO_PADDED_ROOT/NIGHT.lock" ] \
  && printf '%s' "$ZERO_PADDED_LOG" | grep -q '未开工收工: STOP 存在且没有可收尾的活动状态' \
  && ! printf '%s' "$ZERO_PADDED_LOG" | grep -Eq \
       '非法，回落|SLEEP_WELL_AI_TIMEOUT 超出 1–86400|SLEEP_WELL_HANG_LIMIT 超出 1–87300|仅为收尾采用安全超时默认值' \
  && ! grep -Eq 'value too great for base|integer expression expected|unbound variable' \
       "$TMPD/zero-padded.out" "$TMPD/zero-padded.err"; then
  ok "带前导零的十进制超时配置可正常取锁并完成 STOP 收尾"
else
  bad "带前导零的超时配置仍触发八进制算术错误或遗留锁"
fi

# Polling and termination grace are part of the hang safety boundary. Oversize
# values must be visibly clamped instead of silently disabling the watchdog.
BOUNDED_WATCHDOG_ROOT="$TMPD/bounded-watchdog-root"
mkdir -p "$BOUNDED_WATCHDOG_ROOT/codex"
touch "$BOUNDED_WATCHDOG_ROOT/STOP"
SLEEP_WELL_ROOT="$BOUNDED_WATCHDOG_ROOT" \
SLEEP_WELL_WATCHDOG_POLL=999 \
SLEEP_WELL_WATCHDOG_GRACE=999 \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
BOUNDED_WATCHDOG_LOG="$(cat "$BOUNDED_WATCHDOG_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ -f "$BOUNDED_WATCHDOG_ROOT/codex/TERMINATED" ] \
  && [ ! -e "$BOUNDED_WATCHDOG_ROOT/NIGHT.lock" ] \
  && printf '%s' "$BOUNDED_WATCHDOG_LOG" | grep -q '看门狗轮询 999s 过大，压到 300' \
  && printf '%s' "$BOUNDED_WATCHDOG_LOG" | grep -q '看门狗宽限期 999s 过大，压到 300'; then
  ok "看门狗轮询与终止宽限的超大配置会可见地压到 300 秒"
else
  bad "看门狗轮询或终止宽限仍可被超大配置静默关闭"
fi

LOW_WATCHDOG_ROOT="$TMPD/low-watchdog-root"
mkdir -p "$LOW_WATCHDOG_ROOT/codex"
touch "$LOW_WATCHDOG_ROOT/STOP"
SLEEP_WELL_ROOT="$LOW_WATCHDOG_ROOT" \
SLEEP_WELL_WATCHDOG_POLL=0 \
SLEEP_WELL_WATCHDOG_GRACE=0 \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
LOW_WATCHDOG_LOG="$(cat "$LOW_WATCHDOG_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ -f "$LOW_WATCHDOG_ROOT/codex/TERMINATED" ] \
  && [ ! -e "$LOW_WATCHDOG_ROOT/NIGHT.lock" ] \
  && printf '%s' "$LOW_WATCHDOG_LOG" | grep -q '看门狗轮询 0s 过小，抬到 1' \
  && printf '%s' "$LOW_WATCHDOG_LOG" | grep -q '看门狗宽限期 0s 过短，抬到 3'; then
  ok "看门狗轮询与终止宽限的过小配置会可见地抬到下界"
else
  bad "看门狗轮询或终止宽限的下界钳制仍静默或未生效"
fi

# A STOP with persisted activity must never be described as "没有活动运行"
# merely because node vanished before the emergency-stop tick.
NODE_MISSING_STOP_ROOT="$TMPD/node-missing-stop-root"
NODE_MISSING_BIN="$TMPD/node-missing-bin"
mkdir -p "$NODE_MISSING_STOP_ROOT/codex/state" "$NODE_MISSING_BIN"
ln -s "$BIN/launchctl" "$NODE_MISSING_BIN/launchctl"
cat > "$NODE_MISSING_BIN/node" <<'FAKENODE'
#!/bin/sh
exit 127
FAKENODE
chmod +x "$NODE_MISSING_BIN/node"
printf '{"startedAt":1,"cutoffEpoch":2,"tasks":[{"id":"node-missing","status":"implementing"}]}\n' \
  > "$NODE_MISSING_STOP_ROOT/codex/state/current-run.json"
touch "$NODE_MISSING_STOP_ROOT/STOP"
PATH="$NODE_MISSING_BIN:/bin:/usr/bin" SLEEP_WELL_ROOT="$NODE_MISSING_STOP_ROOT" \
  /bin/bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
NODE_MISSING_STOP_RC=$?
NODE_MISSING_STOP_LOG="$(cat "$NODE_MISSING_STOP_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$NODE_MISSING_STOP_RC" -ne 0 ] \
  && [ -s "$NODE_MISSING_STOP_ROOT/codex/state/current-run.json" ] \
  && [ -f "$NODE_MISSING_STOP_ROOT/codex/TERMINATED" ] \
  && [ ! -e "$NODE_MISSING_STOP_ROOT/NIGHT.lock" ] \
  && grep -q '活动状态因缺少 node 未能归档' "$NODE_MISSING_STOP_ROOT/codex/morning-report.md" 2>/dev/null \
  && ! grep -q '没有活动运行' "$NODE_MISSING_STOP_ROOT/codex/morning-report.md" 2>/dev/null \
  && ! grep -q '由下一跳重试' "$NODE_MISSING_STOP_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q 'terminal-clear 并重新 load' "$NODE_MISSING_STOP_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q '归档或改名隔离 current-run.json' "$NODE_MISSING_STOP_ROOT/codex/morning-report.md" 2>/dev/null \
  && printf '%s' "$NODE_MISSING_STOP_LOG" | grep -q 'PUSH\[⚠️ 需要手动处理\].*归档或改名隔离 current-run.json' \
  && printf '%s' "$NODE_MISSING_STOP_LOG" | grep -q '状态原样保留待人工核对'; then
  ok "node 缺失时 STOP 如实披露并保留已有活动状态"
else
  bad "node 缺失时 STOP 仍把已有活动状态误报为没有活动运行"
fi

# Re-arming with that preserved run would inherit its stale cutoff and end the
# next night immediately. terminal-clear must fail closed without deleting the
# evidence or TERMINATED marker.
TERMINAL_CLEAR_BLOCKED_LOG="$TMPD/terminal-clear-blocked.log"
if SLEEP_WELL_ROOT="$NODE_MISSING_STOP_ROOT" node "$CLI_PATH" terminal-clear \
     >"$TERMINAL_CLEAR_BLOCKED_LOG" 2>&1; then
  bad "terminal-clear 仍允许未归档活动状态跨夜重新武装"
elif [ -s "$NODE_MISSING_STOP_ROOT/codex/state/current-run.json" ] \
  && [ -f "$NODE_MISSING_STOP_ROOT/codex/TERMINATED" ] \
  && grep -q '未归档的 current-run.json' "$TERMINAL_CLEAR_BLOCKED_LOG" \
  && grep -q '运行 archive.*改名隔离' "$TERMINAL_CLEAR_BLOCKED_LOG"; then
  ok "terminal-clear 拒绝带未归档活动状态的重新武装"
else
  bad "terminal-clear 拒绝重新武装时破坏证据或缺少处置说明"
fi

# Without an explicit STOP, a transient node failure must retain a live retry
# path instead of pairing TERMINATED with an unarchived active state.
NODE_MISSING_RETRY_ROOT="$TMPD/node-missing-retry-root"
mkdir -p "$NODE_MISSING_RETRY_ROOT/codex/state"
printf '{"startedAt":1,"cutoffEpoch":4102444800,"tasks":[{"id":"node-retry","title":"node retry","repo":"%s","status":"reviewing"}]}\n' "$REPO" \
  > "$NODE_MISSING_RETRY_ROOT/codex/state/current-run.json"
PATH="$NODE_MISSING_BIN:/bin:/usr/bin" SLEEP_WELL_ROOT="$NODE_MISSING_RETRY_ROOT" \
  /bin/bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
NODE_MISSING_RETRY_RC=$?
NODE_MISSING_RETRY_LOG="$(cat "$NODE_MISSING_RETRY_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$NODE_MISSING_RETRY_RC" -ne 0 ] \
  && [ -s "$NODE_MISSING_RETRY_ROOT/codex/state/current-run.json" ] \
  && [ ! -e "$NODE_MISSING_RETRY_ROOT/codex/TERMINATED" ] \
  && [ ! -e "$NODE_MISSING_RETRY_ROOT/NIGHT.lock" ] \
  && grep -q '本夜已有活动运行（未归档）' "$NODE_MISSING_RETRY_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q '由下一跳重试' "$NODE_MISSING_RETRY_ROOT/codex/morning-report.md" 2>/dev/null \
  && ! grep -q '状态: 未开工' "$NODE_MISSING_RETRY_ROOT/codex/morning-report.md" 2>/dev/null \
  && printf '%s' "$NODE_MISSING_RETRY_LOG" | grep -q '不落 TERMINATED、不卸载，留待依赖恢复后重试'; then
  ok "非 STOP 的 node 丢失如实披露活动状态并保持下一跳重试"
else
  bad "非 STOP 的 node 丢失仍误报未开工或终止未归档活动状态"
fi

# The hook-recovery path runs before preflight. It must use the same active-run
# retry contract when node cannot parse inherited recovery metadata.
NODE_MISSING_HOOK_ROOT="$TMPD/node-missing-hook-root"
mkdir -p "$NODE_MISSING_HOOK_ROOT/codex/state"
printf '{"startedAt":1,"cutoffEpoch":4102444800,"tasks":[{"id":"node-hook","title":"node hook","repo":"%s","status":"implementing"}]}\n' "$REPO" \
  > "$NODE_MISSING_HOOK_ROOT/codex/state/current-run.json"
printf '{}\n' > "$NODE_MISSING_HOOK_ROOT/codex/hook-recovery.json"
PATH="$NODE_MISSING_BIN:/bin:/usr/bin" SLEEP_WELL_ROOT="$NODE_MISSING_HOOK_ROOT" \
  /bin/bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
NODE_MISSING_HOOK_RC=$?
NODE_MISSING_HOOK_LOG="$(cat "$NODE_MISSING_HOOK_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$NODE_MISSING_HOOK_RC" -ne 0 ] \
  && [ -s "$NODE_MISSING_HOOK_ROOT/codex/state/current-run.json" ] \
  && [ -f "$NODE_MISSING_HOOK_ROOT/codex/hook-recovery.json" ] \
  && [ ! -e "$NODE_MISSING_HOOK_ROOT/codex/TERMINATED" ] \
  && [ ! -e "$NODE_MISSING_HOOK_ROOT/NIGHT.lock" ] \
  && printf '%s' "$NODE_MISSING_HOOK_LOG" | grep -q 'PUSH\[⚠️ 夜班暂停\]' \
  && printf '%s' "$NODE_MISSING_HOOK_LOG" | grep -q '不落 TERMINATED、不卸载，留待依赖恢复后重试'; then
  ok "node 缺失且有 hook 恢复材料时，活动 run 保持 loaded 重试"
else
  bad "hook 恢复前 node 缺失仍终止了未归档活动 run"
fi

# STOP must remain authoritative after the same hook-recovery path has already
# published a deduplicated pause. The terminal alert uses a different key and
# the report must explicitly require manual re-arming rather than promise retry.
touch "$NODE_MISSING_HOOK_ROOT/STOP"
PATH="$NODE_MISSING_BIN:/bin:/usr/bin" SLEEP_WELL_ROOT="$NODE_MISSING_HOOK_ROOT" \
  /bin/bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
NODE_MISSING_HOOK_STOP_RC=$?
NODE_MISSING_HOOK_STOP_LOG="$(cat "$NODE_MISSING_HOOK_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$NODE_MISSING_HOOK_STOP_RC" -ne 0 ] \
  && [ -s "$NODE_MISSING_HOOK_ROOT/codex/state/current-run.json" ] \
  && [ -f "$NODE_MISSING_HOOK_ROOT/codex/hook-recovery.json" ] \
  && [ -f "$NODE_MISSING_HOOK_ROOT/codex/TERMINATED" ] \
  && [ ! -e "$NODE_MISSING_HOOK_ROOT/NIGHT.lock" ] \
  && ! grep -q '由下一跳重试' "$NODE_MISSING_HOOK_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q 'terminal-clear 并重新 load' "$NODE_MISSING_HOOK_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q '归档或改名隔离 current-run.json' "$NODE_MISSING_HOOK_ROOT/codex/morning-report.md" 2>/dev/null \
  && printf '%s' "$NODE_MISSING_HOOK_STOP_LOG" | grep -q 'PUSH\[⚠️ 需要手动处理\]'; then
  ok "hook 恢复前 node 缺失时 STOP 仍终止并要求人工重新武装"
else
  bad "hook 恢复前 node 缺失时 STOP 被暂停重试路径忽略"
fi

# After node recovers, the pause dedupe slot must clear before a different
# terminal dependency failure, so the user receives the changed outcome.
NODE_RECOVERY_LOG_BEFORE="$(printf '%s' "$NODE_MISSING_RETRY_LOG" | grep -c 'PUSH\[' || true)"
SLEEP_WELL_ROOT="$NODE_MISSING_RETRY_ROOT" \
SLEEP_WELL_CLAUDE_REVIEW="$TMPD/missing-review-adapter" \
  /bin/bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
NODE_RECOVERY_LOG="$(cat "$NODE_MISSING_RETRY_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
NODE_RECOVERY_PUSHES="$(printf '%s' "$NODE_RECOVERY_LOG" | grep -c 'PUSH\[' || true)"
if [ -f "$NODE_MISSING_RETRY_ROOT/codex/TERMINATED" ] \
  && [ ! -e "$NODE_MISSING_RETRY_ROOT/codex/state/.push-once-node-paused" ] \
  && [ "$NODE_RECOVERY_PUSHES" -gt "$NODE_RECOVERY_LOG_BEFORE" ] \
  && printf '%s' "$NODE_RECOVERY_LOG" | grep -q 'PUSH\[⚠️ 夜班异常收工\]'; then
  ok "node 恢复会清除暂停去重槽，后续终止结果仍会通知"
else
  bad "node 暂停标记吞掉了恢复后的不同终止告警"
fi

# ── 额度中继: fix-only 时不得取新任务（Codex R12 范围外提醒）──────────
# 此前 decideHop 的 defer-review / fix-only 只存在于注释里，主循环照样取新任务
# 并去调那个已知不可用的一侧——SKILL.md 承诺的行为根本没实现。
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
echo "rate limit exceeded" >&2; exit 1
FAKE
chmod +x "$BIN/codex"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## 新任务甲
- id: q1
- repo: $REPO
- type: small-todo
> x

## 新任务乙
- id: q2
- repo: $REPO2
- type: small-todo
> y
EOF
export SLEEP_WELL_AI_TIMEOUT=60
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1      # 第一跳: codex 报额度耗尽
rm -f "$SW/codex/TERMINATED"; rm -rf "$SW/NIGHT.lock"
# ⚠️ 三处让这条断言曾经是**假绿**（Codex R13 #4）:
#   1. 第一跳排了 5 分钟退避，紧接着的第二跳在 retry-due 就退出了，**根本没进 fix-only 分支**
#   2. 日志是累加的，grep 能被第一跳的消息满足
#   3. `CALLED <= 1` 放行了一次不该有的调用
# 逐条堵掉: 清退避 / 清空日志 / 断言恰好 0 次。
node "$CLI_PATH" backoff-clear >/dev/null 2>&1 || true
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
# ⚠️ 要测的是「不取**新**任务」。在途任务的重试是**有意保留**的——它正是探测 codex
#    是否恢复的手段（Codex R13 #1 就靠它把可用性置回 ok）。所以先把在途的 q1 落地，
#    让 next-task 只剩一个 pending 的 q2，这时「0 次 exec」才是对 fix-only 的真断言。
node "$CLI_PATH" advance q1 needs_human >/dev/null 2>&1 || true
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
n="$(cat "$CALLS" 2>/dev/null || echo 0)"; echo $((n+1)) > "$CALLS"
echo "rate limit exceeded" >&2; exit 1
FAKE
chmod +x "$BIN/codex"
export CALLS="$TMPD/codex-calls"; echo 0 > "$CALLS"
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1      # 第二跳: 已知 codex 不可用
CALLED="$(cat "$CALLS" 2>/dev/null || echo 0)"
LOG2="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
printf '%s' "$LOG2" | grep -q '不取新任务\|codex 不可用' \
  && ok "codex 不可用时记录了「不取新任务」" \
  || bad "codex 不可用时未走 fix-only 分支（额度中继未实现）"
[ "$CALLED" = "0" ] && ok "codex 不可用时对它的 exec 调用为 0 次（严格断言）" \
                    || bad "codex 已知不可用却仍调用了 ${CALLED} 次"

# ── 单侧故障不得结束本跳（R13 符合性扫查: 与「一跳工作到收工」矛盾）────
# claude 挂了，codex 正常: 本跳应继续推进（defer-review 接管），而不是白等 5 分钟。
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'let z = 3\n' >> "$(ls *.js 2>/dev/null | head -1)" 2>/dev/null || true
exit 0
FAKE
chmod +x "$BIN/codex"
cat > "$BIN/review.sh" <<'FAKE'
#!/usr/bin/env bash
echo "CLAUDE_UNAVAILABLE (quota)" >&2; exit 1
FAKE
chmod +x "$BIN/review.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## 甲
- id: s1
- repo: $REPO
- type: small-todo
> x

## 乙
- id: s2
- repo: $REPO2
- type: small-todo
> y
EOF
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
LOG3="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
printf '%s' "$LOG3" | grep -q '本跳继续' \
  && ok "claude 单侧故障后本跳继续（不再白等一整跳）" \
  || bad "单侧故障仍直接结束本跳（与「一跳工作到收工」矛盾）"
# 两个任务都应被实现过（第二个证明循环确实继续了）
# ⚠️ 数「实现开始」的行数不辨任务（Codex R14 #7）: s1 被重复实现两次而 s2 从未启动，
#    这条断言照样通过。改为**按任务 ID** 核对，并直接检查第二个仓库的产物。
printf '%s' "$LOG3" | grep -q '\[s1\] 实现开始' && ok "任务 s1 被实现" || bad "任务 s1 未被实现"
printf '%s' "$LOG3" | grep -q '\[s2\] 实现开始' \
  && ok "任务 s2 也被实现（证明循环确实继续到了第二个任务）" \
  || bad "任务 s2 从未启动，循环没继续"
# ⚠️ 「实现开始」是**调用 codex 之前**打的日志（Codex R15 #3）: 让 codex_step 对 s2
#    直接返回成功而不真调 codex，这条断言照样通过。必须核对第二个仓库的**实际产物**。
grep -q 'let z = 3' "$REPO2"/*.js 2>/dev/null \
  && ok "第二个仓库确有产物（不是只打了日志）" \
  || bad "第二个仓库没有任何产物——s2 实际未被实现"

# ── 内部错误退出必须推送（R13 符合性扫查）────────────────────────────
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
# ⚠️ 写坏 config 只会让 `init` 失败、走既有的「夜班未开工」推送，**根本进不了 hop_fail**
#    （Codex R14 #6——他实测把 hop_fail 改成静默退出后 24 条仍全过）。
#    要真正触发它，得让 init **成功**之后的 cli 调用失败: 先正常跑起来建好状态，
#    再把状态文件写坏，这样 availability-get / next-task 会失败而 init 已经过了。
# 写坏状态文件不行——`init` 会先失败，走的是既有的「夜班未开工」路径。
# 要真正进 hop_fail，得让 init **成功**而后续某个 cli 调用失败: 用 PATH 影子 node
# 做定点失败注入（只让 next-task 失败，其余原样透传）。这是 Codex 要求的「真实失败注入」。
# ⚠️ 必须在造影子**之前**取真实路径（Codex R15 #5）: $BIN 已在 PATH 首位，
#    造完再 `command -v node` 只是碰巧命中 bash 的 hash 缓存；`bash +h`、
#    之前执行过 `hash -r`、或测试重排都会让 REAL_NODE 指向影子自身 → 无限递归。
export REAL_NODE="$(command -v node)"
INJECT_MSG="injected-next-task-failure-$$"
cat > "$BIN/node" <<FAKENODE
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "next-task" ] || [ "\$a" = "mark-terminal-in-state" ]; then
    echo "$INJECT_MSG" >&2; exit 1
  fi
done
exec "$REAL_NODE" "\$@"
FAKENODE
chmod +x "$BIN/node"
rm -f "$SW/codex/TERMINATED"; rm -rf "$SW/NIGHT.lock"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
rm -f "$BIN/node"
LOG4="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
printf '%s' "$LOG4" | grep -q '本跳异常退出' \
  && ok "内部错误走 hop_fail 并留下告警（不再一声不吭）" \
  || bad "内部错误退出时未经 hop_fail——用户早上既无早报也无告警"
printf '%s' "$LOG4" | grep -q 'PUSH\[⚠️ 夜班异常退出\]' \
  && ok "hop_fail 确实发出了推送" || bad "hop_fail 未发推送"
# ⚠️ 只匹配标题不够（Codex R15 #4）: 把 hop_fail 正文换成任意文本，26 条照样全过——
#    用户会收到同名告警却没有可诊断的原因。断言正文必须携带本次失败的原因。
printf '%s' "$LOG4" | grep 'PUSH\[⚠️ 夜班异常退出\]' | grep -q '取任务失败' \
  && ok "异常推送正文携带了失败原因" \
  || bad "异常推送正文不含失败原因（用户收到告警但无从诊断）"
HOP_PUSHES_BEFORE="$(printf '%s' "$LOG4" | grep -c 'PUSH\[⚠️ 夜班异常退出\]' || true)"
if [ -f "$SW/codex/TERMINATED" ]; then
  ok "hop_fail 即使终止状态无法写入也落 TERMINATED"
else
  bad "hop_fail 未落 TERMINATED"
fi
# A launchd-style second trigger must stop at TERMINATED and publish nothing.
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
LOG4_AFTER="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
HOP_PUSHES_AFTER="$(printf '%s' "$LOG4_AFTER" | grep -c 'PUSH\[⚠️ 夜班异常退出\]' || true)"
if [ "$HOP_PUSHES_AFTER" -eq "$HOP_PUSHES_BEFORE" ]; then
  ok "持续内部故障的下一次触发不重复推送"
else
  bad "持续内部故障重复推送（before=${HOP_PUSHES_BEFORE} after=${HOP_PUSHES_AFTER}）"
fi

# A failed needs_human transition must be an immediate internal fault, not a
# successful return that hot-loops on the same unchanged task until cutoff.
STATE_FAIL_CALLS="$TMPD/state-fail-calls"
cat > "$BIN/node" <<FAKENODE
#!/usr/bin/env bash
case " \$* " in
  *" advance state-transition-fail needs_human "*)
    printf 'attempt\n' >> "$STATE_FAIL_CALLS"
    exit 99 ;;
esac
exec "$REAL_NODE" "\$@"
FAKENODE
chmod +x "$BIN/node"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## State transition failure
- id: state-transition-fail
- repo: $TMPD/not-a-git-repository
- type: bugfix
> Must fail before implementation.
EOF
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
rm -f "$BIN/node"
STATE_FAIL_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
STATE_FAIL_N="$(wc -l < "$STATE_FAIL_CALLS" 2>/dev/null | tr -d ' ' || echo 0)"
if [ "${STATE_FAIL_N:-0}" -eq 1 ] \
  && printf '%s' "$STATE_FAIL_LOG" | grep -q '任务状态无法可靠推进（状态读写失败）' \
  && printf '%s' "$STATE_FAIL_LOG" | grep -q 'PUSH\[⚠️ 夜班异常退出\]' \
  && [ -f "$SW/codex/TERMINATED" ]; then
  ok "转人工状态写入失败立即异常收敛，不在同一任务上热转"
else
  bad "转人工失败仍被当作成功或重复空转（attempts=${STATE_FAIL_N:-0}）"
fi

# The first pending -> implementing transition is the authorization to let
# Codex edit the repository. If it cannot be persisted, no Codex call may run.
REPO_IMPLEMENTING_FAIL="$TMPD/implementing-transition-repo"
mkdir -p "$REPO_IMPLEMENTING_FAIL"
git -C "$REPO_IMPLEMENTING_FAIL" init -q .
git -C "$REPO_IMPLEMENTING_FAIL" config user.email t@t
git -C "$REPO_IMPLEMENTING_FAIL" config user.name t
printf 'base\n' > "$REPO_IMPLEMENTING_FAIL/app.txt"
git -C "$REPO_IMPLEMENTING_FAIL" add -A >/dev/null 2>&1
git -C "$REPO_IMPLEMENTING_FAIL" commit -qm base >/dev/null 2>&1
IMPLEMENTING_CODEX_CALLS="$TMPD/implementing-codex-calls"
cat > "$BIN/codex-implementing-fail" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'unexpected\n' >> "$IMPLEMENTING_CODEX_CALLS"
exit 0
FAKE
chmod +x "$BIN/codex-implementing-fail"
cat > "$BIN/node" <<FAKENODE
#!/usr/bin/env bash
case " \$* " in
  *" advance implementing-transition-fail implementing "*) exit 98 ;;
esac
exec "$REAL_NODE" "\$@"
FAKENODE
chmod +x "$BIN/node"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## Implementing transition failure
- id: implementing-transition-fail
- repo: $REPO_IMPLEMENTING_FAIL
- type: bugfix
> Must not edit before state persistence.
EOF
export IMPLEMENTING_CODEX_CALLS
export SLEEP_WELL_CODEX="$BIN/codex-implementing-fail"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
rm -f "$BIN/node"
export SLEEP_WELL_CODEX="$BIN/codex"
IMPLEMENTING_FAIL_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ ! -s "$IMPLEMENTING_CODEX_CALLS" ] \
  && printf '%s' "$IMPLEMENTING_FAIL_LOG" | grep -q 'pending → implementing 状态写入失败' \
  && printf '%s' "$IMPLEMENTING_FAIL_LOG" | grep -q 'PUSH\[⚠️ 夜班异常退出\]' \
  && [ -f "$SW/codex/TERMINATED" ]; then
  ok "pending 状态写入失败时禁止 Codex 编辑并立即异常收敛"
else
  bad "pending 状态写入失败后仍调用 Codex 或未收敛"
fi


# ── codex_step 必须真的调用护栏（Codex R15 #2）─────────────────────────
# 他实测把 codex_step 里两处 guard_verify 都换成 true，26 条 E2E 仍全绿——
# 意味着以后**删掉集中式护栏实现**照样能拿到全绿。这里注入两种情形:
#   (a) codex 成功但改了受保护文件 → 必须中止整夜
#   (b) codex 非零退出且改了受保护文件 → 同样必须中止（R13 补的那个洞）
# ⚠️ 上一版只注入了「改受保护文件」这一条分支（Codex R17 #1）: 他把 rev-list、
#    merge 标记、分支切换、for-each-ref 四项核验**全部删掉**，149 项照样全绿。
#    五项核验必须各有独立注入——「加了失败注入」不等于「护栏被覆盖」。
#    每个用例声明: 动作 → 期望在日志里看到的**那一句**。
guard_case() {   # $1=用例名 $2=fake codex 里要执行的动作 $3=期望的日志片段
  rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
  rm -rf "$REPO3"; mkdir -p "$REPO3"
  git -C "$REPO3" init -q .; git -C "$REPO3" config user.email t@t; git -C "$REPO3" config user.name t
  printf 'node_modules/\n' > "$REPO3/.gitignore"
  mkdir -p "$REPO3/node_modules/p"; printf 'ORIGINAL\n' > "$REPO3/node_modules/p/.env"
  printf 'x\n' > "$REPO3/a.js"
  git -C "$REPO3" add -A >/dev/null 2>&1; git -C "$REPO3" commit -qm base >/dev/null 2>&1
  cat > "$BIN/codex" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
cd "$REPO3" || exit 1
$2
exit 0
FAKE
  chmod +x "$BIN/codex"
  cat > "$SW/queue.md" <<EOF
## 护栏注入
- id: gc
- repo: $REPO3
- type: small-todo
> x
EOF
  : > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
  local lg; lg="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
  local miss=""
  printf '%s' "$lg" | grep -q "$3" || miss="${miss}[未报出「$3」]"
  printf '%s' "$lg" | grep -q '收工: 护栏违规，中止整夜' || miss="${miss}[未中止整夜]"
  [ -z "$miss" ] && ok "护栏注入·$1" || bad "护栏注入·$1 未按预期: ${miss}"
}

guard_case "未授权提交"   'printf "sneaky\n" >> a.js; git add -A >/dev/null 2>&1; git commit -qm sneaky >/dev/null 2>&1' '新提交'
guard_case "merge 标记"   'printf "merged\n" > .git/MERGE_MSG' 'MERGE_MSG'
guard_case "分支引用变化" 'git branch evil-branch >/dev/null 2>&1' '本地分支引用发生变化'
guard_case "切换分支"     'git checkout -q -b other >/dev/null 2>&1' '当前分支由'
guard_case ".review 保留区写入" 'mkdir -p .review; printf "hidden\n" > .review/hidden.txt' '护栏违规: 实现者修改了 .review 保留区'

# 「核验命令自身失败」与「检出违规」是两条不同的路（Codex R18 #1）:
# 前者是护栏不可用，必须报「核验不可得」并中止，而不是当成「未检出违规」放行。
# 用 PATH 包装 git: 快照阶段放行，见到 marker 之后让指定子命令失败。
guard_cmdfail_case() {   # $1=用例名 $2=要让其失败的 git 子命令 $3=期望日志片段
  rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
  rm -rf "$REPO3"; mkdir -p "$REPO3"
  git -C "$REPO3" init -q .; git -C "$REPO3" config user.email t@t; git -C "$REPO3" config user.name t
  printf 'x\n' > "$REPO3/a.js"; git -C "$REPO3" add -A >/dev/null 2>&1; git -C "$REPO3" commit -qm base >/dev/null 2>&1
  REAL_GIT="$(command -v git)"
  MARKER="$TMPD/cmdfail-marker"; rm -f "$MARKER"
  cat > "$BIN/git" <<GITW
#!/usr/bin/env bash
# 只在 marker 存在后让目标子命令失败——快照阶段必须成功，否则测的是快照失败而非核验失败
if [ -f "$MARKER" ]; then
  if [ "$2" = "branch-identity" ]; then
    case " \$* " in
      *" symbolic-ref "*|*" rev-parse --verify HEAD "*)
        echo "injected git failure" >&2; exit 1 ;;
    esac
  fi
  for a in "\$@"; do
    if [ "\$a" = "$2" ]; then echo "injected git failure" >&2; exit 1; fi
  done
fi
exec "$REAL_GIT" "\$@"
GITW
  chmod +x "$BIN/git"
  cat > "$BIN/codex" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
touch "$MARKER"          # 快照已过，从这里开始让核验命令失败
printf 'y\n' >> "$REPO3/a.js"
exit 0
FAKE
  chmod +x "$BIN/codex"
  cat > "$SW/queue.md" <<EOF
## 核验失败注入
- id: cf
- repo: $REPO3
- type: small-todo
> x
EOF
  : > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
  local lg; lg="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
  rm -f "$BIN/git" "$MARKER"
  local miss=""
  printf '%s' "$lg" | grep -q "$3" || miss="${miss}[未报出「$3」]"
  printf '%s' "$lg" | grep -q '收工: 护栏不可得，中止整夜' || miss="${miss}[未如实报告护栏不可得]"
  printf '%s' "$lg" | grep -q '收工: 护栏违规，中止整夜' && miss="${miss}[把核验不可得误报成违规]"
  [ -z "$miss" ] && ok "核验命令失败·$1" || bad "核验命令失败·$1 未按预期: ${miss}"
}

guard_cmdfail_case "for-each-ref 出错" "for-each-ref" "护栏核验失败: for-each-ref 出错"
guard_cmdfail_case "rev-list 出错"     "rev-list"     "护栏核验失败: rev-list 出错"
guard_cmdfail_case "当前分支探测出错" "branch-identity" "护栏核验失败: 无法核验当前分支"

for CASE in success failure; do
  rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
  rm -rf "$REPO3"; mkdir -p "$REPO3"
  git -C "$REPO3" init -q .; git -C "$REPO3" config user.email t@t; git -C "$REPO3" config user.name t
  printf 'node_modules/\n' > "$REPO3/.gitignore"
  mkdir -p "$REPO3/node_modules/p"; printf 'ORIGINAL\n' > "$REPO3/node_modules/p/.env"
  printf 'x\n' > "$REPO3/a.js"
  git -C "$REPO3" add -A >/dev/null 2>&1; git -C "$REPO3" commit -qm base >/dev/null 2>&1
  if [ "$CASE" = success ]; then EXITCODE=0; else EXITCODE=1; fi
  cat > "$BIN/codex" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'TAMPERED\n' > "$REPO3/node_modules/p/.env"
exit $EXITCODE
FAKE
  chmod +x "$BIN/codex"
  cat > "$SW/queue.md" <<EOF
## 护栏注入
- id: g1
- repo: $REPO3
- type: small-todo
> x
EOF
  : > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
  LOG5="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
  # ⚠️ 断言必须落在**具体的违规原因 + 终止状态**上（Codex R16 #1）:
  #    原来只 grep「护栏」二字——他把 guard_verify 换成「只打一行含『护栏』的日志然后
  #    返回成功」，30 条照样全过。我上一轮验检出能力时 crippled 版把日志也去掉了，
  #    所以没暴露。**关键词匹配不是断言。**
  MISS=""
  printf '%s' "$LOG5" | grep -q '护栏违规: 受保护路径内容变化' || MISS="${MISS}[无具体违规原因]"
  printf '%s' "$LOG5" | grep -q '收工: 护栏违规，中止整夜' || MISS="${MISS}[未中止整夜]"
  [ -f "$SW/codex/TERMINATED" ] || MISS="${MISS}[未落 TERMINATED]"
  # 被改的凭据必须仍是被改后的样子（护栏是检测不是回滚），且任务不得被 checkpoint
  [ "$(git -C "$REPO3" rev-list --count HEAD 2>/dev/null || echo 0)" = "1" ] || MISS="${MISS}[违规后仍产生了 checkpoint]"
  if [ -z "$MISS" ]; then
    ok "codex ${CASE} 且改了受保护文件 → 护栏报出确切违规并中止整夜"
  else
    bad "codex ${CASE} 改了受保护文件，护栏未按预期动作: ${MISS}"
  fi
done

# ── 独立审查器也必须经过事后护栏（Claude public review #1）─────────────
REPO_REVIEW_GUARD="$TMPD/reviewer-guard-repo"
mkdir -p "$REPO_REVIEW_GUARD/node_modules/p"
git -C "$REPO_REVIEW_GUARD" init -q .
git -C "$REPO_REVIEW_GUARD" config user.email t@t; git -C "$REPO_REVIEW_GUARD" config user.name t
printf 'node_modules/\n' > "$REPO_REVIEW_GUARD/.gitignore"
printf 'ORIGINAL\n' > "$REPO_REVIEW_GUARD/node_modules/p/.env"
printf 'base\n' > "$REPO_REVIEW_GUARD/app.txt"
git -C "$REPO_REVIEW_GUARD" add -A >/dev/null 2>&1; git -C "$REPO_REVIEW_GUARD" commit -qm base >/dev/null 2>&1
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'implementation\n' >> app.txt
exit 0
FAKE
chmod +x "$BIN/codex"
cat > "$BIN/review-tamper.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$repo/.review"
f="$repo/.review/zero.md"
cat > "$f" <<'MD'
# Review
- findings 条数: 0
- 高严重度: 0

## 处理状态
MD
printf 'TAMPERED-BY-REVIEWER\n' > "$repo/node_modules/p/.env"
echo "FINDINGS_FILE=$f"
exit 0
FAKE
chmod +x "$BIN/review-tamper.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## Review adapter guard
- id: review-guard
- repo: $REPO_REVIEW_GUARD
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-tamper.sh"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
REVIEW_GUARD_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
REVIEW_GUARD_COMMITS="$(git -C "$REPO_REVIEW_GUARD" rev-list --count HEAD 2>/dev/null || echo 0)"
if printf '%s' "$REVIEW_GUARD_LOG" | grep -q '护栏违规: 受保护路径内容变化' \
  && printf '%s' "$REVIEW_GUARD_LOG" | grep -q '收工: 护栏违规，中止整夜' \
  && [ "$REVIEW_GUARD_COMMITS" -eq 1 ]; then
  ok "审查适配器改受保护文件 → 事后护栏拦截且未 checkpoint"
else
  bad "审查适配器副作用未被事后护栏失败关闭（commits=${REVIEW_GUARD_COMMITS}）"
fi

# A reviewer changing an already-dirty ordinary source leaves the same porcelain
# status (` M app.txt`). The content snapshot, not status text, must catch it.
REPO_REVIEW_CONTENT="$TMPD/reviewer-content-repo"
mkdir -p "$REPO_REVIEW_CONTENT"
git -C "$REPO_REVIEW_CONTENT" init -q .
git -C "$REPO_REVIEW_CONTENT" config user.email t@t; git -C "$REPO_REVIEW_CONTENT" config user.name t
printf 'base\n' > "$REPO_REVIEW_CONTENT/app.txt"
git -C "$REPO_REVIEW_CONTENT" add -A >/dev/null 2>&1; git -C "$REPO_REVIEW_CONTENT" commit -qm base >/dev/null 2>&1
cat > "$BIN/review-content-tamper.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$repo/.review"
f="$repo/.review/zero-content.md"
cat > "$f" <<'MD'
# Review
- findings 条数: 0
- 高严重度: 0

## 处理状态
MD
printf 'REPLACED-BY-REVIEWER\n' > "$repo/app.txt"
echo "FINDINGS_FILE=$f"
FAKE
chmod +x "$BIN/review-content-tamper.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## Review ordinary-content guard
- id: review-content-guard
- repo: $REPO_REVIEW_CONTENT
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-content-tamper.sh"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
REVIEW_CONTENT_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$REVIEW_CONTENT_LOG" | grep -q '审查适配器修改了 .review/ 之外的 Git 可见内容或索引' \
  && printf '%s' "$REVIEW_CONTENT_LOG" | grep -q '收工: 护栏违规，中止整夜' \
  && [ "$(git -C "$REPO_REVIEW_CONTENT" rev-list --count HEAD 2>/dev/null || echo 0)" -eq 1 ]; then
  ok "审查适配器改已脏普通源码 → 内容快照拦截且未 checkpoint"
else
  bad "审查适配器普通源码副作用未被内容快照拦截"
fi

# The adapter owns .review working-tree output, but never the target repo's
# index. A staged review artifact must be caught before a plain checkpoint
# commit could submit the whole index.
REPO_REVIEW_INDEX="$TMPD/reviewer-index-repo"
mkdir -p "$REPO_REVIEW_INDEX"
git -C "$REPO_REVIEW_INDEX" init -q .
git -C "$REPO_REVIEW_INDEX" config user.email t@t; git -C "$REPO_REVIEW_INDEX" config user.name t
printf 'base\n' > "$REPO_REVIEW_INDEX/app.txt"
git -C "$REPO_REVIEW_INDEX" add -A >/dev/null 2>&1; git -C "$REPO_REVIEW_INDEX" commit -qm base >/dev/null 2>&1
cat > "$BIN/review-index-tamper.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$repo/.review"
f="$repo/.review/staged-zero.md"
cat > "$f" <<'MD'
# Review
- findings 条数: 0
- 高严重度: 0

## 处理状态
MD
git -C "$repo" add -- .review/staged-zero.md
echo "FINDINGS_FILE=$f"
FAKE
chmod +x "$BIN/review-index-tamper.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## Review index guard
- id: review-index-guard
- repo: $REPO_REVIEW_INDEX
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-index-tamper.sh"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
REVIEW_INDEX_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$REVIEW_INDEX_LOG" | grep -q '审查适配器修改了 .review/ 之外的 Git 可见内容或索引' \
  && printf '%s' "$REVIEW_INDEX_LOG" | grep -q '收工: 护栏违规，中止整夜' \
  && [ "$(git -C "$REPO_REVIEW_INDEX" rev-list --count HEAD 2>/dev/null || echo 0)" -eq 1 ] \
  && ! git -C "$REPO_REVIEW_INDEX" show --pretty=format: --name-only HEAD | grep -q '^\.review/'; then
  ok "审查适配器 stage .review → 索引快照拦截且未 checkpoint"
else
  bad "审查适配器 staging .review 未在 checkpoint 前失败关闭"
fi

# A pre-existing repository file cannot be claimed as a findings artifact.
REPO_REVIEW_PATH="$TMPD/reviewer-path-repo"
mkdir -p "$REPO_REVIEW_PATH"
git -C "$REPO_REVIEW_PATH" init -q .
git -C "$REPO_REVIEW_PATH" config user.email t@t; git -C "$REPO_REVIEW_PATH" config user.name t
printf 'base\n' > "$REPO_REVIEW_PATH/app.txt"
cat > "$REPO_REVIEW_PATH/source-findings.md" <<'MD'
# Review
- findings 条数: 0
- 高严重度: 0

## 处理状态
MD
git -C "$REPO_REVIEW_PATH" add -A >/dev/null 2>&1; git -C "$REPO_REVIEW_PATH" commit -qm base >/dev/null 2>&1
cat > "$BIN/review-wrong-path.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
echo "FINDINGS_FILE=$repo/source-findings.md"
FAKE
chmod +x "$BIN/review-wrong-path.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## Reject ordinary findings path
- id: review-wrong-path
- repo: $REPO_REVIEW_PATH
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-wrong-path.sh"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
REVIEW_PATH_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$REVIEW_PATH_LOG" | grep -q 'findings 位于普通仓库路径而非 .review/' \
  && ! grep -q '"taskId":"review-wrong-path"' "$SW/codex/findings.jsonl" 2>/dev/null; then
  ok "仓库普通路径 findings 在记录前被拒绝"
else
  bad "仓库普通路径 findings 未失败关闭或已被记录"
fi

# The authoritative high count comes from extractFindings. Extra heading spaces
# deliberately evade the legacy grep while remaining valid structured output.
REPO_REVIEW_HIGH="$TMPD/reviewer-high-repo"
mkdir -p "$REPO_REVIEW_HIGH"
git -C "$REPO_REVIEW_HIGH" init -q .
git -C "$REPO_REVIEW_HIGH" config user.email t@t; git -C "$REPO_REVIEW_HIGH" config user.name t
printf 'base\n' > "$REPO_REVIEW_HIGH/app.txt"
git -C "$REPO_REVIEW_HIGH" add -A >/dev/null 2>&1; git -C "$REPO_REVIEW_HIGH" commit -qm base >/dev/null 2>&1
HIGH_CODEX_CALLS="$TMPD/high-codex-calls"
cat > "$BIN/codex-high" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'call\n' >> "$HIGH_CODEX_CALLS"
printf 'implementation\n' >> app.txt
FAKE
chmod +x "$BIN/codex-high"
cat > "$BIN/review-high.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$repo/.review"
f="$repo/.review/high.md"
cat > "$f" <<'MD'
# Review
- findings 条数: 1
- 高严重度: 0

###    #1 [高] Must not auto-fix
- 位置: `app.txt` L2

## 处理状态
- [ ] #1
MD
echo "FINDINGS_FILE=$f"
FAKE
chmod +x "$BIN/review-high.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## Authoritative high gate
- id: review-high
- repo: $REPO_REVIEW_HIGH
- type: bugfix
> Add one line.
EOF
export HIGH_CODEX_CALLS
export SLEEP_WELL_CODEX="$BIN/codex-high"
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-high.sh"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
REVIEW_HIGH_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
HIGH_CALL_N="$(wc -l < "$HIGH_CODEX_CALLS" 2>/dev/null | tr -d ' ' || echo 0)"
if printf '%s' "$REVIEW_HIGH_LOG" | grep -q '含 1 条高严重度 findings' \
  && [ "${HIGH_CALL_N:-0}" -eq 1 ] \
  && node -e '
    const fs=require("fs");
    const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
    process.exit(rows.some(x=>x.taskId==="review-high" && x.severity==="needs-human") ? 0 : 1);
  ' "$SW/codex/findings.jsonl"; then
  ok "extractFindings 权威高危计数阻断自动修复"
else
  bad "高危门禁仍依赖脆弱 grep（codex calls=${HIGH_CALL_N:-0}）"
fi
export SLEEP_WELL_CODEX="$BIN/codex"

# ── 审查超时: 即使适配器提前写了 0 findings 骨架，也绝不能 checkpoint ─
cat > "$BIN/review-zero.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$repo/.review"
f="$repo/.review/zero-stable.md"
cat > "$f" <<'MD'
# Review
- findings 条数: 0
- 高严重度: 0

## 处理状态
MD
echo "FINDINGS_FILE=$f"
FAKE
chmod +x "$BIN/review-zero.sh"
GOOD_REVIEW="$BIN/review-zero.sh"

# Publishing a valid-looking zero-findings file does not rescue a nonzero
# adapter exit. The review is incomplete and must never create a checkpoint.
REPO_REVIEW_NONZERO="$TMPD/review-nonzero-repo"
mkdir -p "$REPO_REVIEW_NONZERO"
git -C "$REPO_REVIEW_NONZERO" init -q .
git -C "$REPO_REVIEW_NONZERO" config user.email t@t; git -C "$REPO_REVIEW_NONZERO" config user.name t
printf 'let before = 1\n' > "$REPO_REVIEW_NONZERO/app.js"
git -C "$REPO_REVIEW_NONZERO" add -A >/dev/null 2>&1; git -C "$REPO_REVIEW_NONZERO" commit -qm base >/dev/null 2>&1
cat > "$BIN/review-zero-nonzero.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$repo/.review"
f="$repo/.review/zero-before-crash.md"
cat > "$f" <<'MD'
# Incomplete review
- findings 条数: 0
- 高严重度: 0

## 处理状态
MD
echo "FINDINGS_FILE=$f"
exit 7
FAKE
chmod +x "$BIN/review-zero-nonzero.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## Nonzero reviewer exit
- id: review-nonzero
- repo: $REPO_REVIEW_NONZERO
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-zero-nonzero.sh"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
REVIEW_NONZERO_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
REVIEW_NONZERO_COMMITS="$(git -C "$REPO_REVIEW_NONZERO" rev-list --count HEAD 2>/dev/null || echo 0)"
if [ "$REVIEW_NONZERO_COMMITS" -eq 1 ] \
  && printf '%s' "$REVIEW_NONZERO_LOG" | grep -q '适配器以退出码 7 结束' \
  && node -e '
    const fs=require("fs"), path=require("path"), dir=process.argv[1];
    const files=fs.readdirSync(dir).filter(x=>/^run-.*\.json$/.test(x));
    const ok=files.some(file=>JSON.parse(fs.readFileSync(path.join(dir,file),"utf8")).tasks?.some(t=>t.id==="review-nonzero" && t.status==="needs_human"));
    process.exit(ok ? 0 : 1);
  ' "$SW/codex/state"; then
  ok "适配器发布文件后非零退出仍按不完整审查失败关闭"
else
  bad "非零退出的半成品 findings 被采信或产生 checkpoint"
fi
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"

REPO4="$TMPD/review-timeout-repo"
mkdir -p "$REPO4"
git -C "$REPO4" init -q .
git -C "$REPO4" config user.email t@t; git -C "$REPO4" config user.name t
printf 'let before = 1\n' > "$REPO4/app.js"
git -C "$REPO4" add -A >/dev/null 2>&1; git -C "$REPO4" commit -qm base >/dev/null 2>&1
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'let after = 2\n' >> app.js
exit 0
FAKE
chmod +x "$BIN/codex"
cat > "$BIN/review-timeout.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$repo/.review"
f="$repo/.review/provisional-zero.md"
cat > "$f" <<'MD'
# Provisional review
- findings 条数: 0
- 高严重度: 0

## 处理状态
MD
echo "FINDINGS_FILE=$f"
sleep 600
FAKE
chmod +x "$BIN/review-timeout.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## Review timeout must fail closed
- id: review-timeout
- repo: $REPO4
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-timeout.sh"
export SLEEP_WELL_AI_TIMEOUT=5
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
REVIEW_TIMEOUT_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
REVIEW_TIMEOUT_COMMITS="$(git -C "$REPO4" rev-list --count HEAD 2>/dev/null || echo 0)"
REVIEW_TIMEOUT_STATE="$(cat "$SW/codex/state/"run-*.json 2>/dev/null | tail -200)"
if printf '%s' "$REVIEW_TIMEOUT_LOG" | grep -q '审查超时.*不完整审查' \
  && [ "$REVIEW_TIMEOUT_COMMITS" -eq 1 ] \
  && printf '%s' "$REVIEW_TIMEOUT_STATE" | grep -q '"status": "needs_human"' \
  && printf '%s' "$REVIEW_TIMEOUT_STATE" | grep -q '"dirtyResidue": true'; then
  ok "审查超时不采信预写的 0 findings，未 checkpoint 且记录残留"
else
  bad "审查超时路径未失败关闭（commits=${REVIEW_TIMEOUT_COMMITS}）"
fi

# A reviewer that mutates a protected file before timing out must be checked
# before the timeout branch can return.
REPO_REVIEW_TIMEOUT_GUARD="$TMPD/review-timeout-guard-repo"
mkdir -p "$REPO_REVIEW_TIMEOUT_GUARD/node_modules/p"
git -C "$REPO_REVIEW_TIMEOUT_GUARD" init -q .
git -C "$REPO_REVIEW_TIMEOUT_GUARD" config user.email t@t; git -C "$REPO_REVIEW_TIMEOUT_GUARD" config user.name t
printf 'node_modules/\n' > "$REPO_REVIEW_TIMEOUT_GUARD/.gitignore"
printf 'ORIGINAL\n' > "$REPO_REVIEW_TIMEOUT_GUARD/node_modules/p/.env"
printf 'base\n' > "$REPO_REVIEW_TIMEOUT_GUARD/app.txt"
git -C "$REPO_REVIEW_TIMEOUT_GUARD" add -A >/dev/null 2>&1
git -C "$REPO_REVIEW_TIMEOUT_GUARD" commit -qm base >/dev/null 2>&1
cat > "$BIN/review-timeout-tamper.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
printf 'TAMPERED-BEFORE-TIMEOUT\n' > "$repo/node_modules/p/.env"
sleep 600
FAKE
chmod +x "$BIN/review-timeout-tamper.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## Review timeout guard
- id: review-timeout-guard
- repo: $REPO_REVIEW_TIMEOUT_GUARD
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-timeout-tamper.sh"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
REVIEW_TIMEOUT_GUARD_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$REVIEW_TIMEOUT_GUARD_LOG" | grep -q '护栏违规: 受保护路径内容变化' \
  && printf '%s' "$REVIEW_TIMEOUT_GUARD_LOG" | grep -q '收工: 护栏违规，中止整夜' \
  && [ "$(git -C "$REPO_REVIEW_TIMEOUT_GUARD" rev-list --count HEAD 2>/dev/null || echo 0)" -eq 1 ]; then
  ok "审查适配器超时前篡改受保护文件仍先触发护栏"
else
  bad "审查超时返回路径跳过了事后护栏"
fi

# Malformed/non-zero review output is another early-return path and must obey
# the same invariant.
REPO_REVIEW_INVALID_GUARD="$TMPD/review-invalid-guard-repo"
mkdir -p "$REPO_REVIEW_INVALID_GUARD/node_modules/p"
git -C "$REPO_REVIEW_INVALID_GUARD" init -q .
git -C "$REPO_REVIEW_INVALID_GUARD" config user.email t@t; git -C "$REPO_REVIEW_INVALID_GUARD" config user.name t
printf 'node_modules/\n' > "$REPO_REVIEW_INVALID_GUARD/.gitignore"
printf 'ORIGINAL\n' > "$REPO_REVIEW_INVALID_GUARD/node_modules/p/.env"
printf 'base\n' > "$REPO_REVIEW_INVALID_GUARD/app.txt"
git -C "$REPO_REVIEW_INVALID_GUARD" add -A >/dev/null 2>&1
git -C "$REPO_REVIEW_INVALID_GUARD" commit -qm base >/dev/null 2>&1
cat > "$BIN/review-invalid-tamper.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
printf 'TAMPERED-BEFORE-FAILURE\n' > "$repo/node_modules/p/.env"
echo 'malformed review output' >&2
exit 1
FAKE
chmod +x "$BIN/review-invalid-tamper.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## Invalid review guard
- id: review-invalid-guard
- repo: $REPO_REVIEW_INVALID_GUARD
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-invalid-tamper.sh"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
REVIEW_INVALID_GUARD_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$REVIEW_INVALID_GUARD_LOG" | grep -q '护栏违规: 受保护路径内容变化' \
  && printf '%s' "$REVIEW_INVALID_GUARD_LOG" | grep -q '收工: 护栏违规，中止整夜' \
  && [ "$(git -C "$REPO_REVIEW_INVALID_GUARD" rev-list --count HEAD 2>/dev/null || echo 0)" -eq 1 ]; then
  ok "审查产物不可信且有副作用时仍先触发护栏"
else
  bad "审查失败返回路径跳过了事后护栏"
fi
export SLEEP_WELL_AI_TIMEOUT=60
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"

# ── 公开推送不得包含本机路径（Claude release review #6）───────────────
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
GOOD_REVIEW="$SLEEP_WELL_CLAUDE_REVIEW"
export SLEEP_WELL_CLAUDE_REVIEW="$TMPD/private/missing-review.sh"
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
PUSH_LINE="$(grep 'PUSH\[⚠️ 夜班未开工\]' "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | tail -1)"
DEP_PUSHES_BEFORE="$(grep -c 'PUSH\[⚠️ 夜班未开工\]' "$SW/codex/logs/"orchestrator-*.log 2>/dev/null || true)"
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
DEP_PUSHES_AFTER="$(grep -c 'PUSH\[⚠️ 夜班未开工\]' "$SW/codex/logs/"orchestrator-*.log 2>/dev/null || true)"
if printf '%s' "$PUSH_LINE" | grep -q 'claude-handoff' \
  && ! printf '%s' "$PUSH_LINE" | grep -q "$TMPD" \
  && ! printf '%s' "$PUSH_LINE" | grep -q '/Users/' \
  && [ -f "$SW/codex/TERMINATED" ] \
  && [ "$DEP_PUSHES_BEFORE" -eq 1 ] \
  && [ "$DEP_PUSHES_AFTER" -eq 2 ] \
  && [ "$(grep -c 'PUSH\[⚠️ 夜班未开工\].*terminal-clear' "$SW/codex/logs/"orchestrator-*.log 2>/dev/null || true)" -eq 1 ]; then
  ok "缺依赖告警与遗留 TERMINATED 提示各一次，且不泄露路径"
else
  bad "缺依赖收工路径不安全或重复推送: $PUSH_LINE"
fi

# Missing dependencies can interrupt an existing run before its cutoff. It
# must be marked terminal before report generation and archived before unload.
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
mkdir -p "$SW/codex/state"
ACTIVE_STARTED="$(date +%s)"
ACTIVE_CUTOFF=$((ACTIVE_STARTED + 3600))
cat > "$SW/codex/state/current-run.json" <<EOF
{"startedAt":$ACTIVE_STARTED,"cutoffEpoch":$ACTIVE_CUTOFF,"tasks":[{"id":"active","title":"active task","repo":"$REPO","status":"implementing"}]}
EOF
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
if [ ! -e "$SW/codex/state/current-run.json" ] \
  && ls "$SW/codex/state/"run-*.json >/dev/null 2>&1 \
  && grep -q '已收工' "$SW/codex/morning-report.md" 2>/dev/null \
  && ! grep -q '运行中' "$SW/codex/morning-report.md" 2>/dev/null; then
  ok "活动运行遇缺依赖会先标终止、生成真实早报并归档"
else
  bad "活动运行的缺依赖收工留下陈旧状态或早报仍显示运行中"
fi

# STOP must take precedence over the same missing dependency.
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
touch "$SW/STOP"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
STOP_BEFORE_DEP_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$STOP_BEFORE_DEP_LOG" | grep -q 'STOP 已生效' \
  && ! printf '%s' "$STOP_BEFORE_DEP_LOG" | grep -q '缺少依赖'; then
  ok "STOP 在依赖预检前生效"
else
  bad "STOP 被依赖预检挡住"
fi
rm -f "$SW/STOP"

# An already-started run must honor cutoff before the same missing dependency.
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
mkdir -p "$SW/codex/state"
cat > "$SW/codex/state/current-run.json" <<EOF
{"startedAt":1,"cutoffEpoch":1,"tasks":[{"id":"cutoff-inflight","title":"cutoff in-flight","repo":"$REPO","status":"reviewing","reviewDeferred":true}]}
EOF
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
CUTOFF_BEFORE_DEP_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
CUTOFF_ARCHIVE="$(find "$SW/codex/state" -name 'run-*.json' -type f 2>/dev/null | sort | tail -1)"
if printf '%s' "$CUTOFF_BEFORE_DEP_LOG" | grep -q '收工: 到达 cutoff' \
  && ! printf '%s' "$CUTOFF_BEFORE_DEP_LOG" | grep -q '缺少依赖' \
  && [ -n "$CUTOFF_ARCHIVE" ] \
  && node -e '
    const fs=require("fs"), run=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const t=run.tasks?.find(x=>x.id==="cutoff-inflight");
    process.exit(t?.status==="needs_human" && t.reviewDeferred===false ? 0 : 1);
  ' "$CUTOFF_ARCHIVE" \
  && grep -q 'cutoff-inflight' "$SW/codex/morning-report.md" 2>/dev/null; then
  ok "已有运行的 cutoff 在依赖预检前生效并将中断任务转人工"
else
  bad "cutoff 被依赖预检挡住或在途任务未进入可操作状态"
fi
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"

# ── STOP + 空队列必须一次收工，不进入归档失败循环（Claude review #11）──
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/queue.md"
touch "$SW/STOP"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
STOP_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
STOP_PUSHES="$(printf '%s' "$STOP_LOG" | grep -c 'PUSH\[' || true)"
if [ -f "$SW/codex/TERMINATED" ] \
  && [ "$STOP_PUSHES" -eq 1 ] \
  && ! printf '%s' "$STOP_LOG" | grep -q '归档失败'; then
  ok "STOP + 空队列一次收工并落 TERMINATED"
else
  bad "STOP + 空队列未干净收工（pushes=${STOP_PUSHES}）"
fi

# ── .review alone must not keep a cleaned needs_human repository blocked ─
REPO5="$TMPD/review-only-repo"
mkdir -p "$REPO5/.review"
git -C "$REPO5" init -q .
git -C "$REPO5" config user.email t@t; git -C "$REPO5" config user.name t
printf 'base\n' > "$REPO5/app.txt"
git -C "$REPO5" add -A >/dev/null 2>&1; git -C "$REPO5" commit -qm base >/dev/null 2>&1
printf 'review artifact\n' > "$REPO5/.review/finding.md"
mkdir -p "$SW/codex/state"
cat > "$SW/codex/state/current-run.json" <<EOF
{"tasks":[
  {"id":"old","repo":"$REPO5","status":"needs_human","dirtyResidue":true},
  {"id":"next","repo":"$REPO5","status":"pending"}
]}
EOF
REVIEW_ONLY_NEXT="$(node "$CLI_PATH" next-task 2>/dev/null || echo '{}')"
if printf '%s' "$REVIEW_ONLY_NEXT" | grep -q '"id":"next"'; then
  ok ".review 单独存在时不会永久阻塞同仓库后续任务"
else
  bad ".review 被 repoStillDirty 误判为任务残留"
fi

# A repository-owned tracked .review tree conflicts with the adapter's reserved
# output namespace and must be rejected before any Codex invocation.
REPO6="$TMPD/tracked-review-repo"
mkdir -p "$REPO6/.review"
git -C "$REPO6" init -q .
git -C "$REPO6" config user.email t@t; git -C "$REPO6" config user.name t
printf 'base\n' > "$REPO6/app.txt"
printf 'project checklist\n' > "$REPO6/.review/checklist.md"
git -C "$REPO6" add -A >/dev/null 2>&1; git -C "$REPO6" commit -qm base >/dev/null 2>&1
TRACKED_REVIEW_CALLS="$TMPD/tracked-review-codex-calls"
: > "$TRACKED_REVIEW_CALLS"
cat > "$BIN/codex" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
echo called >> "$TRACKED_REVIEW_CALLS"
exit 0
FAKE
chmod +x "$BIN/codex"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## Reject tracked review namespace
- id: tracked-review
- repo: $REPO6
- type: bugfix
> Must not run here.
EOF
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
TRACKED_REVIEW_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$TRACKED_REVIEW_LOG" | grep -q '已跟踪 .review/' \
  && [ ! -s "$TRACKED_REVIEW_CALLS" ]; then
  ok "目标仓库已跟踪 .review/ 时转人工且不调用 Codex"
else
  bad "已跟踪 .review/ 未失败关闭或仍调用了 Codex"
fi

# A queue repo must be the complete Git/worktree root, never a subdirectory.
mkdir -p "$REPO5/subpkg"
TOPLEVEL_CALLS="$TMPD/toplevel-codex-calls"
: > "$TOPLEVEL_CALLS"
cat > "$BIN/codex" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
echo called >> "$TOPLEVEL_CALLS"
exit 0
FAKE
chmod +x "$BIN/codex"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## Reject subdirectory repo
- id: subdir-repo
- repo: $REPO5/subpkg
- type: bugfix
> Must not run here.
EOF
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
TOPLEVEL_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$TOPLEVEL_LOG" | grep -q 'repo 必须是 Git 仓库顶层目录' \
  && [ ! -s "$TOPLEVEL_CALLS" ]; then
  ok "repo 指向仓库子目录时转人工且不调用 Codex"
else
  bad "repo 子目录未失败关闭或仍调用了 Codex"
fi

# Repository shapes whose extra Git metadata is outside the frozen guard scope
# must be rejected before any implementation/review call.
REPO_GITLINK="$TMPD/unsupported-gitlink-repo"
REPO_INCLUDE="$TMPD/unsupported-include-repo"
REPO_LINKED="$TMPD/unsupported-linked-repo"
REPO_HOOKSPATH="$TMPD/unsupported-hookspath-repo"
REPO_WORKTREE_CONFIG="$TMPD/unsupported-worktree-config-repo"
LINKED_CHECKOUT="$TMPD/unsupported-linked-checkout"
for shape_repo in "$REPO_GITLINK" "$REPO_INCLUDE" "$REPO_LINKED" "$REPO_HOOKSPATH" "$REPO_WORKTREE_CONFIG"; do
  mkdir -p "$shape_repo"
  git -C "$shape_repo" init -q .
  git -C "$shape_repo" config user.email t@t; git -C "$shape_repo" config user.name t
  printf 'base\n' > "$shape_repo/app.txt"
  git -C "$shape_repo" add -A >/dev/null 2>&1; git -C "$shape_repo" commit -qm base >/dev/null 2>&1
done
GITLINK_SHA="$(git -C "$REPO_GITLINK" rev-parse HEAD)"
git -C "$REPO_GITLINK" update-index --add --cacheinfo "160000,$GITLINK_SHA,vendor/sub"
git -C "$REPO_GITLINK" commit -qm gitlink
: > "$REPO_INCLUDE/local.inc"
git -C "$REPO_INCLUDE" config include.path "$REPO_INCLUDE/local.inc"
git -C "$REPO_LINKED" worktree add -q -b e2e-linked "$LINKED_CHECKOUT"
git -C "$REPO_HOOKSPATH" config core.hooksPath .husky/_
git -C "$REPO_WORKTREE_CONFIG" config extensions.worktreeConfig true
UNSUPPORTED_SHAPE_CALLS="$TMPD/unsupported-shape-calls"
: > "$UNSUPPORTED_SHAPE_CALLS"
cat > "$BIN/codex-unsupported-shape" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'called\n' >> "$UNSUPPORTED_SHAPE_CALLS"
exit 0
FAKE
chmod +x "$BIN/codex-unsupported-shape"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
cat > "$SW/queue.md" <<EOF
## Reject submodule metadata
- id: reject-gitlink
- repo: $REPO_GITLINK
- type: bugfix
> Must not run.

## Reject local config include
- id: reject-include
- repo: $REPO_INCLUDE
- type: bugfix
> Must not run.

## Reject linked worktree metadata
- id: reject-linked
- repo: $REPO_LINKED
- type: bugfix
> Must not run.

## Reject custom hooks path
- id: reject-hookspath
- repo: $REPO_HOOKSPATH
- type: bugfix
> Must not run.

## Reject worktree config scope
- id: reject-worktree-config
- repo: $REPO_WORKTREE_CONFIG
- type: bugfix
> Must not run.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-unsupported-shape"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
UNSUPPORTED_SHAPE_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ ! -s "$UNSUPPORTED_SHAPE_CALLS" ] \
  && printf '%s' "$UNSUPPORTED_SHAPE_LOG" | grep -q '仓库含子模块 gitlink' \
  && printf '%s' "$UNSUPPORTED_SHAPE_LOG" | grep -q 'include.path/includeIf' \
  && printf '%s' "$UNSUPPORTED_SHAPE_LOG" | grep -q 'linked worktree' \
  && printf '%s' "$UNSUPPORTED_SHAPE_LOG" | grep -q 'core.hooksPath' \
  && printf '%s' "$UNSUPPORTED_SHAPE_LOG" | grep -q 'extensions.worktreeConfig'; then
  ok "额外 gitdir/config/hook 拓扑均在 AI 前转人工"
else
  bad "未覆盖的 Git 元数据拓扑仍进入无人值守调用"
fi

# A process-level interruption has no persisted guard baseline. Persisted
# in-flight tasks must be quarantined rather than resumed on a fresh baseline.
REPO_INTERRUPTED="$TMPD/interrupted-inflight-repo"
mkdir -p "$REPO_INTERRUPTED/config"
git -C "$REPO_INTERRUPTED" init -q .
git -C "$REPO_INTERRUPTED" config user.email t@t; git -C "$REPO_INTERRUPTED" config user.name t
printf 'config/\n' > "$REPO_INTERRUPTED/.gitignore"
printf 'base\n' > "$REPO_INTERRUPTED/app.txt"
printf 'ORIGINAL\n' > "$REPO_INTERRUPTED/config/.env"
git -C "$REPO_INTERRUPTED" add -A >/dev/null 2>&1; git -C "$REPO_INTERRUPTED" commit -qm base >/dev/null 2>&1
INTERRUPTED_CALLS="$TMPD/interrupted-inflight-calls"
: > "$INTERRUPTED_CALLS"
cat > "$BIN/codex-interrupted" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'called\n' >> "$INTERRUPTED_CALLS"
exit 0
FAKE
chmod +x "$BIN/codex-interrupted"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
cat > "$SW/queue.md" <<EOF
## Interrupted in-flight guard
- id: interrupted-inflight
- repo: $REPO_INTERRUPTED
- type: bugfix
> Must not resume automatically.
EOF
SLEEP_WELL_ROOT="$SW" node "$CLI_PATH" init >/dev/null
SLEEP_WELL_ROOT="$SW" node "$CLI_PATH" advance interrupted-inflight implementing >/dev/null
printf 'UNVERIFIED-CHANGE\n' > "$REPO_INTERRUPTED/config/.env"
export SLEEP_WELL_CODEX="$BIN/codex-interrupted"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
INTERRUPTED_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ ! -s "$INTERRUPTED_CALLS" ] \
  && printf '%s' "$INTERRUPTED_LOG" | grep -q '已隔离上一进程遗留的 1 个在途任务' \
  && grep -q 'UNVERIFIED-CHANGE' "$REPO_INTERRUPTED/config/.env" \
  && [ "$(SLEEP_WELL_ROOT="$SW" node "$CLI_PATH" get-field interrupted-inflight reviewDeferred 2>/dev/null || echo false)" = false ]; then
  ok "跨进程在途任务转人工且不吸收未核验内容为新基线"
else
  bad "跨进程恢复仍自动续跑或覆盖未核验护栏窗口"
fi

# A deliberate availability hand-off is different from a crash. First run:
# implement once, hit a transient Claude outage, persist a guarded hop marker.
# Second run: consume that proof and resume review without re-implementing or
# quarantining the task. This is the multi-process relay contract.
REPO_RELAY="$TMPD/graceful-relay-repo"
mkdir -p "$REPO_RELAY"
git -C "$REPO_RELAY" init -q .
git -C "$REPO_RELAY" config user.email t@t; git -C "$REPO_RELAY" config user.name t
printf 'base\n' > "$REPO_RELAY/app.js"
git -C "$REPO_RELAY" add -A >/dev/null 2>&1; git -C "$REPO_RELAY" commit -qm base >/dev/null 2>&1
RELAY_CODEX_CALLS="$TMPD/graceful-relay-codex-calls"
: > "$RELAY_CODEX_CALLS"
export RELAY_CODEX_CALLS
cat > "$BIN/codex-relay" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'exec\n' >> "$RELAY_CODEX_CALLS"
printf 'relay-change\n' >> app.js
exit 0
FAKE
chmod +x "$BIN/codex-relay"
cat > "$BIN/review-relay-unavailable.sh" <<'FAKE'
#!/usr/bin/env bash
echo "CLAUDE_UNAVAILABLE (other)" >&2
exit 1
FAKE
chmod +x "$BIN/review-relay-unavailable.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
cat > "$SW/queue.md" <<EOF
## Graceful relay survives process boundary
- id: graceful-relay
- repo: $REPO_RELAY
- type: bugfix
> Implement once, then resume review after a transient outage.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-relay"
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-relay-unavailable.sh"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
RELAY_FIRST_OK=no
if [ -f "$SW/codex/state/current-run.json" ] && node -e '
  const fs=require("fs");
  const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const t=s.tasks.find(x=>x.id==="graceful-relay");
  process.exit(t?.status==="reviewing" && s.gracefulHopExit?.runId===s.startedAt ? 0 : 1);
' "$SW/codex/state/current-run.json"; then
  RELAY_FIRST_OK=yes
fi
# Make the scheduled retry due now, then restore a trustworthy zero-findings
# reviewer. The implementation fake must not run a second time.
SLEEP_WELL_ROOT="$SW" node "$CLI_PATH" backoff-clear >/dev/null 2>&1
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
RELAY_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
RELAY_CODEX_N="$(wc -l < "$RELAY_CODEX_CALLS" | tr -d ' ')"
RELAY_ARCHIVE="$(find "$SW/codex/state" -maxdepth 1 -type f -name 'run-*.json' -print | LC_ALL=C sort | tail -1)"
if [ "$RELAY_FIRST_OK" = yes ] \
  && [ "$RELAY_CODEX_N" = 1 ] \
  && printf '%s' "$RELAY_LOG" | grep -q '已验证上一进程为计划内跳退出' \
  && ! printf '%s' "$RELAY_LOG" | grep -q '已隔离上一进程遗留' \
  && node -e '
    const fs=require("fs");
    const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    process.exit(s.tasks.find(x=>x.id==="graceful-relay")?.status==="done"
      && !Object.hasOwn(s, "gracefulHopExit") ? 0 : 1);
  ' "$RELAY_ARCHIVE"; then
  ok "计划内可用性退避跨进程续审且不重跑实现"
else
  bad "计划内跳退出被误隔离、未续审或重复实现"
fi

# A marker that exists but is stale or structurally incomplete is not proof.
# Both shapes must be consumed, quarantined, and never reach Codex.
invalid_marker_case() {
  local kind="$1" id="invalid-marker-${1}" repo="$TMPD/invalid-marker-${1}-repo"
  local calls="$TMPD/invalid-marker-${1}-calls" archive log_text
  mkdir -p "$repo"
  git -C "$repo" init -q .
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  printf 'base\n' > "$repo/app.txt"
  git -C "$repo" add -A >/dev/null 2>&1; git -C "$repo" commit -qm base >/dev/null 2>&1
  : > "$calls"
  cat > "$BIN/codex-invalid-marker" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'called\n' >> "$calls"
exit 0
FAKE
  chmod +x "$BIN/codex-invalid-marker"
  rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
  rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
  cat > "$SW/queue.md" <<EOF
## Invalid graceful marker $kind
- id: $id
- repo: $repo
- type: bugfix
> Must be quarantined before Codex.
EOF
  SLEEP_WELL_ROOT="$SW" node "$CLI_PATH" init >/dev/null
  SLEEP_WELL_ROOT="$SW" node "$CLI_PATH" advance "$id" implementing >/dev/null
  SLEEP_WELL_ROOT="$SW" node "$CLI_PATH" set-field "$id" reviewDeferred true >/dev/null
  node -e '
    const fs=require("fs"), p=process.argv[1], kind=process.argv[2];
    const s=JSON.parse(fs.readFileSync(p,"utf8"));
    s.gracefulHopExit = kind === "stale"
      ? { runId: s.startedAt - 1, at: s.startedAt, reason: "old run" }
      : { reason: "missing proof fields" };
    fs.writeFileSync(p, JSON.stringify(s, null, 2));
  ' "$SW/codex/state/current-run.json" "$kind"
  export SLEEP_WELL_CODEX="$BIN/codex-invalid-marker"
  export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
  : > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
  log_text="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
  archive="$(find "$SW/codex/state" -maxdepth 1 -type f -name 'run-*.json' -print | LC_ALL=C sort | tail -1)"
  if [ ! -s "$calls" ] \
    && printf '%s' "$log_text" | grep -q '已隔离上一进程遗留的 1 个在途任务' \
    && node -e '
      const fs=require("fs"), s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const t=s.tasks.find(x=>x.id===process.argv[2]);
      process.exit(t?.status==="needs_human" && t.reviewDeferred===false
        && !Object.hasOwn(s,"gracefulHopExit") ? 0 : 1);
    ' "$archive" "$id"; then
    ok "$kind gracefulHopExit 证明失败关闭且一次性清除"
  else
    bad "$kind gracefulHopExit 被误信或未清除"
  fi
}
invalid_marker_case stale
invalid_marker_case malformed

# prepare_codex_home failures are terminal for the night: one truthful alert,
# TERMINATED, unload attempt, and no five-minute repeat loop.
REPO_PREP="$TMPD/prepare-fail-repo"
mkdir -p "$REPO_PREP"
git -C "$REPO_PREP" init -q .
git -C "$REPO_PREP" config user.email t@t; git -C "$REPO_PREP" config user.name t
printf 'base\n' > "$REPO_PREP/app.txt"
git -C "$REPO_PREP" add -A >/dev/null 2>&1; git -C "$REPO_PREP" commit -qm base >/dev/null 2>&1
cat > "$BIN/codex-mcp-fail" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "probe failed" >&2; exit 9 ;; esac
exit 99
FAKE
chmod +x "$BIN/codex-mcp-fail"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
cat > "$SW/queue.md" <<EOF
## Prepare failure
- id: prepare-fail
- repo: $REPO_PREP
- type: bugfix
> Must not run.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-mcp-fail"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
PREP_FAIL_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
PREP_FAIL_PUSHES="$(printf '%s' "$PREP_FAIL_LOG" | grep -c 'PUSH\[⚠️ 夜班未开工\]' || true)"
if [ "$PREP_FAIL_PUSHES" -eq 2 ] \
  && [ -f "$SW/codex/TERMINATED" ] \
  && printf '%s' "$PREP_FAIL_LOG" | grep -q 'codex mcp list 退出码 9' \
  && [ "$(printf '%s' "$PREP_FAIL_LOG" | grep -c 'PUSH\[⚠️ 夜班未开工\].*隔离运行环境不可用' || true)" -eq 1 ] \
  && [ "$(printf '%s' "$PREP_FAIL_LOG" | grep -c 'PUSH\[⚠️ 夜班未开工\].*terminal-clear' || true)" -eq 1 ] \
  && ! printf '%s' "$PREP_FAIL_LOG" | grep -q 'MCP 未能清空'; then
  ok "隔离失败与遗留终止标记各告警一次并终止本夜"
else
  bad "prepare_codex_home 失败仍重复或误导告警（pushes=${PREP_FAIL_PUSHES}）"
fi

# A conflicting pending hook recovery follows the same once-only terminal path.
HOOK_TARGET="$TMPD/conflicting-pre-push"
HOOK_BACKUP="$TMPD/conflicting-pre-push.sleepwell-bak"
printf 'EXTERNAL-HOOK\n' > "$HOOK_TARGET"
printf 'USER-BACKUP\n' > "$HOOK_BACKUP"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
mkdir -p "$SW/codex"
printf '{"hook":"%s","backup":"%s","token":"not-ours"}\n' \
  "$HOOK_TARGET" "$HOOK_BACKUP" > "$SW/codex/hook-recovery.json"
cat > "$BIN/codex-hook-test" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
exit 99
FAKE
chmod +x "$BIN/codex-hook-test"
export SLEEP_WELL_CODEX="$BIN/codex-hook-test"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
HOOK_FAIL_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
HOOK_FAIL_PUSHES="$(printf '%s' "$HOOK_FAIL_LOG" | grep -c 'PUSH\[⚠️ 需要手动处理\]' || true)"
if [ "$HOOK_FAIL_PUSHES" -eq 1 ] \
  && [ -f "$SW/codex/TERMINATED" ] \
  && [ -f "$SW/codex/hook-recovery.json" ] \
  && grep -q 'EXTERNAL-HOOK' "$HOOK_TARGET" \
  && grep -q 'USER-BACKUP' "$HOOK_BACKUP"; then
  ok "hook 恢复冲突只告警一次、保留两份材料并终止本夜"
else
  bad "hook 恢复失败未走一次性终止路径（pushes=${HOOK_FAIL_PUSHES}）"
fi

# If the hook is replaced during a live task, process_task's own uninstall
# failure must become the terminal reason. Reusing the stale guard snapshot
# reason would misdirect the morning report toward protected-path setup.
REPO_HOOK_RUNTIME="$TMPD/hook-runtime-repo"
mkdir -p "$REPO_HOOK_RUNTIME"
git -C "$REPO_HOOK_RUNTIME" init -q .
git -C "$REPO_HOOK_RUNTIME" config user.email t@t; git -C "$REPO_HOOK_RUNTIME" config user.name t
printf 'base\n' > "$REPO_HOOK_RUNTIME/app.txt"
printf '#!/bin/sh\necho USER-ORIGINAL\n' > "$REPO_HOOK_RUNTIME/.git/hooks/pre-push"
chmod +x "$REPO_HOOK_RUNTIME/.git/hooks/pre-push"
git -C "$REPO_HOOK_RUNTIME" add -A >/dev/null 2>&1; git -C "$REPO_HOOK_RUNTIME" commit -qm base >/dev/null 2>&1
cat > "$BIN/codex-hook-runtime" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'implementation\n' >> app.txt
printf '#!/bin/sh\necho EXTERNAL-REPLACEMENT\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
exit 0
FAKE
chmod +x "$BIN/codex-hook-runtime"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
cat > "$SW/queue.md" <<EOF
## Runtime hook replacement
- id: hook-runtime
- repo: $REPO_HOOK_RUNTIME
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-hook-runtime"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
HOOK_RUNTIME_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$HOOK_RUNTIME_LOG" | grep -q '收工: pre-push hook 未能恢复，中止整夜' \
  && ! printf '%s' "$HOOK_RUNTIME_LOG" | grep -q '收工: 护栏不可得，中止整夜' \
  && grep -q 'EXTERNAL-REPLACEMENT' "$REPO_HOOK_RUNTIME/.git/hooks/pre-push" \
  && [ -f "$SW/codex/hook-recovery.json" ]; then
  ok "任务内 hook 恢复失败以真实原因终止并保留恢复材料"
else
  bad "任务内 hook 恢复失败仍沿用旧护栏原因或丢失恢复材料"
fi

# Hooks other than the managed pre-push are also executable repository
# metadata. The first post-AI operation must detect a new pre-commit before any
# Git command can trigger it, and the checkpoint must never be created.
REPO_META_HOOK="$TMPD/git-meta-hook-repo"
mkdir -p "$REPO_META_HOOK"
git -C "$REPO_META_HOOK" init -q .
git -C "$REPO_META_HOOK" config user.email t@t; git -C "$REPO_META_HOOK" config user.name t
printf 'base\n' > "$REPO_META_HOOK/app.txt"
git -C "$REPO_META_HOOK" add -A >/dev/null 2>&1; git -C "$REPO_META_HOOK" commit -qm base >/dev/null 2>&1
META_HOOK_MARKER="$TMPD/pre-commit-executed"
cat > "$BIN/codex-meta-hook" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'implementation\n' >> app.txt
cat > .git/hooks/pre-commit <<EOF
#!/bin/sh
printf executed > "$META_HOOK_MARKER"
EOF
chmod +x .git/hooks/pre-commit
exit 0
FAKE
chmod +x "$BIN/codex-meta-hook"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json" "$META_HOOK_MARKER"
cat > "$SW/queue.md" <<EOF
## Git metadata hook guard
- id: git-meta-hook
- repo: $REPO_META_HOOK
- type: bugfix
> Add one line.
EOF
export META_HOOK_MARKER
export SLEEP_WELL_CODEX="$BIN/codex-meta-hook"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
META_HOOK_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$META_HOOK_LOG" | grep -q '护栏违规: Git hooks/config/info 元数据发生变化' \
  && printf '%s' "$META_HOOK_LOG" | grep -q '收工: 护栏违规，中止整夜' \
  && [ ! -e "$META_HOOK_MARKER" ] \
  && [ "$(git -C "$REPO_META_HOOK" rev-list --count HEAD 2>/dev/null || echo 0)" -eq 1 ]; then
  ok "AI 写入 pre-commit 在任何后续 Git 命令前被检出且未执行"
else
  bad "Git 元数据护栏未阻止新 hook 执行或仍产生 checkpoint"
fi

# Git's own maintenance rewrites pure cache entries under info/. They are not
# execution/configuration state and must not create a false security alert.
REPO_META_CACHE="$TMPD/git-meta-cache-repo"
mkdir -p "$REPO_META_CACHE"
git -C "$REPO_META_CACHE" init -q .
git -C "$REPO_META_CACHE" config user.email t@t; git -C "$REPO_META_CACHE" config user.name t
printf 'base\n' > "$REPO_META_CACHE/app.txt"
git -C "$REPO_META_CACHE" add -A >/dev/null 2>&1; git -C "$REPO_META_CACHE" commit -qm base >/dev/null 2>&1
cat > "$BIN/codex-meta-cache" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'implementation\n' >> app.txt
printf 'cache rewritten by git maintenance\n' > .git/info/refs
exit 0
FAKE
chmod +x "$BIN/codex-meta-cache"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
cat > "$SW/queue.md" <<EOF
## Git metadata cache rewrite
- id: git-meta-cache
- repo: $REPO_META_CACHE
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-meta-cache"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
META_CACHE_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$(git -C "$REPO_META_CACHE" rev-list --count HEAD 2>/dev/null || echo 0)" -eq 2 ] \
  && ! printf '%s' "$META_CACHE_LOG" | grep -q '护栏违规: Git hooks/config/info 元数据发生变化'; then
  ok "Git 后台维护缓存变化不伪造元数据护栏违规"
else
  bad "纯 info 缓存变化被误报为安全元数据篡改"
fi

# Security-relevant info entries remain protected after narrowing the cache
# scope. Changing info/exclude can hide untracked paths from later Git scans.
REPO_META_INFO="$TMPD/git-meta-info-repo"
mkdir -p "$REPO_META_INFO"
git -C "$REPO_META_INFO" init -q .
git -C "$REPO_META_INFO" config user.email t@t; git -C "$REPO_META_INFO" config user.name t
printf 'base\n' > "$REPO_META_INFO/app.txt"
git -C "$REPO_META_INFO" add -A >/dev/null 2>&1; git -C "$REPO_META_INFO" commit -qm base >/dev/null 2>&1
cat > "$BIN/codex-meta-info" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'implementation\n' >> app.txt
printf '*.env\n' > .git/info/exclude
exit 0
FAKE
chmod +x "$BIN/codex-meta-info"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
cat > "$SW/queue.md" <<EOF
## Git metadata info guard
- id: git-meta-info
- repo: $REPO_META_INFO
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-meta-info"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
META_INFO_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$META_INFO_LOG" | grep -q '护栏违规: Git hooks/config/info 元数据发生变化' \
  && printf '%s' "$META_INFO_LOG" | grep -q '收工: 护栏违规，中止整夜' \
  && [ "$(git -C "$REPO_META_INFO" rev-list --count HEAD 2>/dev/null || echo 0)" -eq 1 ]; then
  ok "缩窄缓存范围后安全相关 info/exclude 仍失败关闭"
else
  bad "安全相关 info 元数据从护栏中漏失"
fi

# Inject metadata only after the last post-review guard_verify: the next final
# status probe installs the hook after forwarding its result. checkpoint_commit
# must classify its own metadata guard as rc=3 and terminate the whole night.
REPO_CHECKPOINT_META="$TMPD/checkpoint-meta-repo"
mkdir -p "$REPO_CHECKPOINT_META"
git -C "$REPO_CHECKPOINT_META" init -q .
git -C "$REPO_CHECKPOINT_META" config user.email t@t; git -C "$REPO_CHECKPOINT_META" config user.name t
printf 'base\n' > "$REPO_CHECKPOINT_META/app.txt"
git -C "$REPO_CHECKPOINT_META" add -A >/dev/null 2>&1; git -C "$REPO_CHECKPOINT_META" commit -qm base >/dev/null 2>&1
CHECKPOINT_META_ARM="$TMPD/checkpoint-meta-arm"
CHECKPOINT_META_EXEC="$TMPD/checkpoint-meta-executed"
CHECKPOINT_REVIEW="$BIN/review-checkpoint-meta"
cat > "$CHECKPOINT_REVIEW" <<FAKE
#!/usr/bin/env bash
"$GOOD_REVIEW" "\$@"
rc=\$?
[ "\$rc" -eq 0 ] && touch "$CHECKPOINT_META_ARM"
exit "\$rc"
FAKE
chmod +x "$CHECKPOINT_REVIEW"
cat > "$BIN/codex-checkpoint-meta" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'implementation\n' >> app.txt
exit 0
FAKE
chmod +x "$BIN/codex-checkpoint-meta"
REAL_GIT_CHECKPOINT="$(command -v git)"
REPO_CHECKPOINT_META_REAL="$(cd "$REPO_CHECKPOINT_META" && pwd -P)"
cat > "$BIN/git" <<GITW
#!/usr/bin/env bash
target=0; status=0; porcelain=0
for a in "\$@"; do
  [ "\$a" = "$REPO_CHECKPOINT_META_REAL" ] && target=1
  [ "\$a" = status ] && status=1
  [ "\$a" = --porcelain ] && porcelain=1
done
if [ -f "$CHECKPOINT_META_ARM" ] && [ "\$target" -eq 1 ] && [ "\$status" -eq 1 ] && [ "\$porcelain" -eq 1 ]; then
  "$REAL_GIT_CHECKPOINT" "\$@"
  rc=\$?
  if [ "\$rc" -eq 0 ]; then
    printf '#!/bin/sh\nprintf executed > "%s"\n' "$CHECKPOINT_META_EXEC" > "$REPO_CHECKPOINT_META/.git/hooks/post-commit"
    chmod +x "$REPO_CHECKPOINT_META/.git/hooks/post-commit"
    rm -f "$CHECKPOINT_META_ARM"
  fi
  exit "\$rc"
fi
exec "$REAL_GIT_CHECKPOINT" "\$@"
GITW
chmod +x "$BIN/git"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json" "$CHECKPOINT_META_ARM" "$CHECKPOINT_META_EXEC"
cat > "$SW/queue.md" <<EOF
## Checkpoint metadata race guard
- id: checkpoint-meta
- repo: $REPO_CHECKPOINT_META
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-checkpoint-meta"
export SLEEP_WELL_CLAUDE_REVIEW="$CHECKPOINT_REVIEW"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
CHECKPOINT_META_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
rm -f "$BIN/git" "$CHECKPOINT_META_ARM"
CHECKPOINT_META_COMMITS="$(git -C "$REPO_CHECKPOINT_META" rev-list --count HEAD 2>/dev/null || echo 0)"
if printf '%s' "$CHECKPOINT_META_LOG" | grep -q '收工: 护栏违规，中止整夜' \
  && ! printf '%s' "$CHECKPOINT_META_LOG" | grep -q '审查通过但提交失败' \
  && [ ! -e "$CHECKPOINT_META_EXEC" ] \
  && [ "$CHECKPOINT_META_COMMITS" -eq 1 ]; then
  ok "checkpoint 阶段元数据违规保持护栏 rc=3 并中止整夜"
else
  bad "checkpoint 元数据违规路径不符（commits=${CHECKPOINT_META_COMMITS}, executed=$([ -e "$CHECKPOINT_META_EXEC" ] && echo yes || echo no)）"
  printf '%s\n' "$CHECKPOINT_META_LOG" | grep -E 'checkpoint|护栏|收工|提交失败' | sed 's/^/       /'
fi

# A transition check must read this task by id, never use next-task as a proxy.
# Make another task reviewing so the old proxy would falsely pass.
REPO_STATE_DRIFT="$TMPD/state-drift-repo"
mkdir -p "$REPO_STATE_DRIFT"
git -C "$REPO_STATE_DRIFT" init -q .
git -C "$REPO_STATE_DRIFT" config user.email t@t; git -C "$REPO_STATE_DRIFT" config user.name t
printf 'base\n' > "$REPO_STATE_DRIFT/app.txt"
git -C "$REPO_STATE_DRIFT" add -A >/dev/null 2>&1; git -C "$REPO_STATE_DRIFT" commit -qm base >/dev/null 2>&1
STATE_DRIFT_REVIEW_CALLS="$TMPD/state-drift-review-calls"
: > "$STATE_DRIFT_REVIEW_CALLS"
cat > "$BIN/review-state-drift" <<FAKE
#!/usr/bin/env bash
printf 'called\n' >> "$STATE_DRIFT_REVIEW_CALLS"
exec "$GOOD_REVIEW" "\$@"
FAKE
chmod +x "$BIN/review-state-drift"
STATE_DRIFT_FILE="$SW/codex/state/current-run.json"
cat > "$BIN/codex-state-drift" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'implementation\n' >> app.txt
node -e '
const fs=require("fs"), p=process.argv[1];
const s=JSON.parse(fs.readFileSync(p,"utf8"));
s.tasks.find(t=>t.id==="state-drift").status="needs_human";
s.tasks.find(t=>t.id==="other-reviewing").status="reviewing";
fs.writeFileSync(p,JSON.stringify(s,null,2)+"\\n");
' "$STATE_DRIFT_FILE"
exit 0
FAKE
chmod +x "$BIN/codex-state-drift"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
cat > "$SW/queue.md" <<EOF
## Exact task state lookup
- id: state-drift
- repo: $REPO_STATE_DRIFT
- type: bugfix
> Add one line.

## Other reviewing task
- id: other-reviewing
- repo: $REPO2
- type: bugfix
> Must not authorize the first task.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-state-drift"
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review-state-drift"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
STATE_DRIFT_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if printf '%s' "$STATE_DRIFT_LOG" | grep -q '无法转入 reviewing（当前状态: needs_human）' \
  && [ ! -s "$STATE_DRIFT_REVIEW_CALLS" ]; then
  ok "reviewing 转移失败按任务 id 直读，不借用另一任务状态"
else
  bad "reviewing 转移仍把 next-task 当成本任务状态代理"
fi

# Deterministic lock-publication race. A slow ps creates the old implementation's
# mkdir-before-owner window; the new hard-link publication exposes no partial lock.
# An incomplete legacy owner record is not a normal live-lock exit. Alert once,
# but do not steal or terminate a possibly-live upgraded owner.
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
mkdir -p "$SW/codex/state" "$SW/NIGHT.lock"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
LOCK_ANOMALY_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
LOCK_ANOMALY_PUSHES="$(printf '%s' "$LOCK_ANOMALY_LOG" | grep -c 'PUSH\[⚠️ 夜班未开工\].*锁状态异常' || true)"
if [ "$LOCK_ANOMALY_PUSHES" -eq 1 ] \
  && [ -d "$SW/codex/state/.push-once-lock-anomaly" ] \
  && [ -d "$SW/NIGHT.lock" ]; then
  ok "不可验证的锁 owner 只告警一次且不偷锁"
else
  bad "不可验证锁仍静默、重复告警或被错误接管（pushes=${LOCK_ANOMALY_PUSHES}）"
fi

REPO_LOCK="$TMPD/lock-race-repo"
mkdir -p "$REPO_LOCK"
git -C "$REPO_LOCK" init -q .
git -C "$REPO_LOCK" config user.email t@t; git -C "$REPO_LOCK" config user.name t
printf 'base\n' > "$REPO_LOCK/app.txt"
git -C "$REPO_LOCK" add -A >/dev/null 2>&1; git -C "$REPO_LOCK" commit -qm base >/dev/null 2>&1
LOCK_CODEX_CALLS="$TMPD/lock-codex-calls"
cat > "$BIN/codex-lock" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'call\n' >> "$LOCK_CODEX_CALLS"
printf 'implementation\n' >> app.txt
sleep 1
FAKE
chmod +x "$BIN/codex-lock"
cat > "$BIN/ps" <<'FAKE'
#!/usr/bin/env bash
sleep 1
exec /bin/ps "$@"
FAKE
chmod +x "$BIN/ps"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/codex/hook-recovery.json" "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## Lock race
- id: lock-race
- repo: $REPO_LOCK
- type: bugfix
> Add one line.
EOF
export LOCK_CODEX_CALLS
export SLEEP_WELL_CODEX="$BIN/codex-lock"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1 & LOCK_P1=$!
LOCK_WAIT_N=0
while [ ! -e "$SW/NIGHT.lock" ] && kill -0 "$LOCK_P1" 2>/dev/null && [ "$LOCK_WAIT_N" -lt 500 ]; do
  sleep 0.01
  LOCK_WAIT_N=$((LOCK_WAIT_N + 1))
done
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1 & LOCK_P2=$!
wait "$LOCK_P1"; wait "$LOCK_P2"
rm -f "$BIN/ps"
LOCK_CALL_N="$(wc -l < "$LOCK_CODEX_CALLS" 2>/dev/null | tr -d ' ' || echo 0)"
LOCK_COMMIT_N="$(git -C "$REPO_LOCK" rev-list --count HEAD 2>/dev/null || echo 0)"
LOCK_EXISTS=no; [ -e "$SW/NIGHT.lock" ] && LOCK_EXISTS=yes
if [ "${LOCK_CALL_N:-0}" -eq 1 ] \
  && [ "$LOCK_EXISTS" = no ] \
  && [ "$LOCK_COMMIT_N" -eq 2 ]; then
  ok "锁 owner 原子发布阻止双持有者竞争"
else
  bad "锁发布竞争产生重复执行或残留（codex calls=${LOCK_CALL_N:-0}, commits=${LOCK_COMMIT_N}, lock=${LOCK_EXISTS}）"
  tail -20 "$SW/codex/logs/"orchestrator-*.log 2>/dev/null || true
fi

# A successful no-op implementation plus zero findings is not a Git failure.
# It needs human attention with a truthful "no changes" diagnostic and no
# empty checkpoint.
REPO_EMPTY="$TMPD/empty-diff-repo"
mkdir -p "$REPO_EMPTY"
git -C "$REPO_EMPTY" init -q .
git -C "$REPO_EMPTY" config user.email t@t; git -C "$REPO_EMPTY" config user.name t
printf 'base\n' > "$REPO_EMPTY/app.txt"
git -C "$REPO_EMPTY" add -A >/dev/null 2>&1; git -C "$REPO_EMPTY" commit -qm base >/dev/null 2>&1
cat > "$BIN/codex-empty" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
exit 0
FAKE
chmod +x "$BIN/codex-empty"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/codex/hook-recovery.json" "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## Empty implementation
- id: empty-diff
- repo: $REPO_EMPTY
- type: bugfix
> Confirm whether a change is required.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-empty"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
EMPTY_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
EMPTY_COMMITS="$(git -C "$REPO_EMPTY" rev-list --count HEAD 2>/dev/null || echo 0)"
if [ "$EMPTY_COMMITS" -eq 1 ] \
  && printf '%s' "$EMPTY_LOG" | grep -q '本次实现未产生任何改动，未创建 checkpoint' \
  && ! printf '%s' "$EMPTY_LOG" | grep -q 'checkpoint 提交失败' \
  && node -e '
    const fs=require("fs"), path=require("path"), dir=process.argv[1];
    const files=fs.readdirSync(dir).filter(x=>/^run-.*\.json$/.test(x));
    const ok=files.some(file=>{
      const run=JSON.parse(fs.readFileSync(path.join(dir,file),"utf8"));
      return run.tasks?.some(t=>t.id==="empty-diff" && t.status==="needs_human");
    });
    process.exit(ok ? 0 : 1);
  ' "$SW/codex/state"; then
  ok "空实现如实报告无改动并转人工，不误报提交失败"
else
  bad "空实现仍误报 Git 提交失败或创建了空 checkpoint"
fi

# A repository without any commit cannot establish the guard/checkpoint
# baseline. It is a task-local needs-human precondition; later queued work must
# continue, and the terminal reason must never fabricate a guard violation.
REPO_UNBORN="$TMPD/unborn-repo"
REPO_AFTER_UNBORN="$TMPD/after-unborn-repo"
mkdir -p "$REPO_UNBORN" "$REPO_AFTER_UNBORN"
git -C "$REPO_UNBORN" init -q .
git -C "$REPO_UNBORN" config user.email t@t; git -C "$REPO_UNBORN" config user.name t
git -C "$REPO_AFTER_UNBORN" init -q .
git -C "$REPO_AFTER_UNBORN" config user.email t@t; git -C "$REPO_AFTER_UNBORN" config user.name t
printf 'base\n' > "$REPO_AFTER_UNBORN/app.txt"
git -C "$REPO_AFTER_UNBORN" add -A >/dev/null 2>&1
git -C "$REPO_AFTER_UNBORN" commit -qm base >/dev/null 2>&1
UNBORN_CODEX_CALLS="$TMPD/unborn-codex-calls"
cat > "$BIN/codex-after-unborn" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'call\n' >> "$UNBORN_CODEX_CALLS"
printf 'implemented\n' >> app.txt
FAKE
chmod +x "$BIN/codex-after-unborn"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/codex/hook-recovery.json" "$SW/STOP"
cat > "$SW/queue.md" <<EOF
## Unborn first
- id: unborn-first
- repo: $REPO_UNBORN
- type: bugfix
> Bootstrap work requiring an initial baseline.

## Later normal task
- id: after-unborn
- repo: $REPO_AFTER_UNBORN
- type: bugfix
> Add one line.
EOF
export UNBORN_CODEX_CALLS
export SLEEP_WELL_CODEX="$BIN/codex-after-unborn"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
UNBORN_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
UNBORN_CALL_N="$(wc -l < "$UNBORN_CODEX_CALLS" 2>/dev/null | tr -d ' ' || echo 0)"
AFTER_UNBORN_COMMITS="$(git -C "$REPO_AFTER_UNBORN" rev-list --count HEAD 2>/dev/null || echo 0)"
if [ "${UNBORN_CALL_N:-0}" -eq 1 ] \
  && [ "${AFTER_UNBORN_COMMITS:-0}" -eq 2 ] \
  && printf '%s' "$UNBORN_LOG" | grep -q 'repo 尚无可用的 HEAD 提交' \
  && ! printf '%s' "$UNBORN_LOG" | grep -q '收工: 护栏违规，中止整夜'; then
  ok "无提交 repo 如实转人工，后续队列继续执行"
else
  bad "无提交 repo 被误报为违规、调用了 AI 或阻断后续队列"
fi

# A real launchd unload may terminate the running job. Runtime ownership must
# already be gone before the unload child sends TERM to its parent.
REPO_SELF_UNLOAD="$TMPD/self-unload-repo"
mkdir -p "$REPO_SELF_UNLOAD"
git -C "$REPO_SELF_UNLOAD" init -q .
git -C "$REPO_SELF_UNLOAD" config user.email t@t; git -C "$REPO_SELF_UNLOAD" config user.name t
printf 'base\n' > "$REPO_SELF_UNLOAD/app.txt"
git -C "$REPO_SELF_UNLOAD" add -A >/dev/null 2>&1; git -C "$REPO_SELF_UNLOAD" commit -qm base >/dev/null 2>&1
cat > "$BIN/codex-self-unload" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'implementation\n' >> app.txt
exit 0
FAKE
chmod +x "$BIN/codex-self-unload"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
rm -f "$SW/STOP" "$SW/codex/hook-recovery.json"
cat > "$SW/queue.md" <<EOF
## Self unload cleanup
- id: self-unload
- repo: $REPO_SELF_UNLOAD
- type: bugfix
> Add one line.
EOF
export SLEEP_WELL_CODEX="$BIN/codex-self-unload"
export SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW"
export FAKE_LAUNCHCTL_TERM_PARENT=yes
: > "$FAKE_LAUNCHCTL_LOG"
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
unset FAKE_LAUNCHCTL_TERM_PARENT
if [ ! -e "$SW/NIGHT.lock" ] \
  && [ ! -e "$SW/codex/state/active-pgid" ] \
  && grep -q '^unload ' "$FAKE_LAUNCHCTL_LOG" 2>/dev/null; then
  ok "launchd 自卸载终止自身前已释放锁与进程账本"
else
  bad "launchd 自卸载可能在运行时清理前终止自身"
fi

# finalize publishes TERMINATED before a rare hook-restore failure. The next
# launchd trigger must restore the pending hook and then finish the deferred
# self-unload instead of exiting forever every five minutes.
TERM_HOOK="$TMPD/terminated-recovery-pre-push"
TERM_BACKUP="$TMPD/terminated-recovery-pre-push.sleepwell-bak"
TERM_TOKEN="0123456789abcdef0123456789abcdef"
cat > "$TERM_HOOK" <<EOF
#!/bin/sh
# sleep-well-codex-guard-hook-v1 $TERM_TOKEN
echo "sleep-well-codex: push 被夜班护栏阻断（纵深防御层）" >&2
exit 1
EOF
printf '#!/bin/sh\necho USER-RESTORED-HOOK\n' > "$TERM_BACKUP"
mkdir -p "$SW/codex"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({hook:process.argv[2],backup:process.argv[3],token:process.argv[4]}))' \
  "$SW/codex/hook-recovery.json" "$TERM_HOOK" "$TERM_BACKUP" "$TERM_TOKEN"
: > "$SW/codex/TERMINATED"
: > "$FAKE_LAUNCHCTL_LOG"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
TERM_RECOVERY_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if grep -q 'USER-RESTORED-HOOK' "$TERM_HOOK" 2>/dev/null \
  && [ ! -f "$SW/codex/hook-recovery.json" ] \
  && grep -q '^unload ' "$FAKE_LAUNCHCTL_LOG" 2>/dev/null \
  && printf '%s' "$TERM_RECOVERY_LOG" | grep -q 'PUSH\[✓ 夜班收尾恢复\].*pre-push hook 已恢复' \
  && ! printf '%s' "$TERM_RECOVERY_LOG" | grep -q '忘.*terminal-clear\|请先执行 terminal-clear'; then
  ok "终止态下一跳恢复 hook 后如实通知并完成延迟自卸载"
else
  bad "终止态 hook 恢复成功后通知失实或未完成 launchd 自卸载"
fi
rm -f "$SW/codex/TERMINATED"

# Forgetting terminal-clear must be visible once, and the documented re-arm
# command must clear both TERMINATED and every prior-run push-once marker.
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
mkdir -p "$SW/codex/state"
: > "$SW/codex/TERMINATED"
mkdir -p "$SW/codex/.push-once-fallback-test"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
TERMINATED_NOOP_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
TERMINATED_NOOP_PUSHES="$(printf '%s' "$TERMINATED_NOOP_LOG" | grep -c 'PUSH\[⚠️ 夜班未开工\].*terminal-clear' || true)"
SLEEP_WELL_ROOT="$SW" node "$CLI_PATH" terminal-clear >/dev/null 2>&1
if [ "$TERMINATED_NOOP_PUSHES" -eq 1 ] \
  && [ ! -f "$SW/codex/TERMINATED" ] \
  && ! find "$SW/codex/state" -maxdepth 1 -name '.push-once-*' -print -quit | grep -q . \
  && ! find "$SW/codex" -maxdepth 1 -name '.push-once-fallback-*' -print -quit | grep -q .; then
  ok "遗留 TERMINATED 只告警一次，terminal-clear 同时清理跨夜通知标记"
else
  bad "遗留 TERMINATED 仍静默/重复，或 terminal-clear 未清理通知标记"
fi

# A non-owner exits through the same EXIT trap while a live owner holds the
# lock. Its cleanup must preserve the owner's active-pgid ledger.
rm -f "$SW/codex/TERMINATED"; rm -rf "$SW/NIGHT.lock"
mkdir -p "$SW/codex/state"
printf '%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null | tr -s ' ')" > "$SW/NIGHT.lock"
printf '12345 54321\n' > "$SW/codex/state/active-pgid"
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
if [ "$(cat "$SW/codex/state/active-pgid" 2>/dev/null)" = '12345 54321' ]; then
  ok "非锁持有者退出不删除在跑实例的 active-pgid"
else
  bad "非锁持有者的 EXIT trap 删除了共享 active-pgid"
fi
rm -f "$SW/NIGHT.lock" "$SW/codex/state/active-pgid"

# If ps cannot produce the owner start time, publishing a PID-only lock would
# let a competitor steal it. The first process must fail closed without a lock.
cat > "$BIN/ps" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$BIN/ps"
rm -f "$SW/NIGHT.lock" "$SW/codex/TERMINATED"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
PS_LOCK_LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ ! -e "$SW/NIGHT.lock" ] \
  && printf '%s' "$PS_LOCK_LOG" | grep -q '锁 owner 记录不完整，无法可靠判断是否陈旧'; then
  ok "ps 失败时不发布 PID-only 锁也不抢占未知 owner"
else
  bad "ps 失败时仍发布或抢占了不可验证的锁"
fi
rm -f "$BIN/ps"

# The dependency gate must honor an absolute SLEEP_WELL_CODEX override even
# when the controlled PATH has no command literally named `codex`.
PREFLIGHT_BLOCK="$TMPD/preflight-block.sh"
awk '/^# >>>TESTABLE:preflight>>>/{f=1;next} /^# <<<TESTABLE:preflight<<</{f=0} f' \
  "$ROOT_DIR/bin/orchestrator.sh" > "$PREFLIGHT_BLOCK"
PREFLIGHT_BIN="$TMPD/preflight-bin"; mkdir -p "$PREFLIGHT_BIN"
for dep in node git realpath shasum xargs ps link; do ln -s "$(command -v "$dep")" "$PREFLIGHT_BIN/$dep"; done
PREFLIGHT_CODEX="$TMPD/codex-wrapper"; printf '#!/bin/sh\nexit 0\n' > "$PREFLIGHT_CODEX"; chmod +x "$PREFLIGHT_CODEX"
PREFLIGHT_REVIEW="$TMPD/review-wrapper"; printf '#!/bin/sh\nexit 0\n' > "$PREFLIGHT_REVIEW"; chmod +x "$PREFLIGHT_REVIEW"
if PATH="$PREFLIGHT_BIN" CODEX_BIN="$PREFLIGHT_CODEX" REVIEW_SH="$PREFLIGHT_REVIEW" SKILL_DIR="$ROOT_DIR" \
   SW_USER_CODEX_HOME="$CODEX_HOME" \
   RUNLOG="$TMPD/preflight.log" /bin/bash -c \
   'log(){ :; }; . "$1"; preflight_deps' _ "$PREFLIGHT_BLOCK"; then
  ok "依赖预检尊重 SLEEP_WELL_CODEX 覆写"
else
  bad "依赖预检仍硬编码查找裸 codex"
fi

PREFLIGHT_SKILL="$TMPD/incomplete-skill"
mkdir -p "$PREFLIGHT_SKILL/prompts"
printf 'present\n' > "$PREFLIGHT_SKILL/prompts/implement.md"
: > "$TMPD/preflight-missing-prompt.log"
if PATH="$PREFLIGHT_BIN" CODEX_BIN="$PREFLIGHT_CODEX" REVIEW_SH="$PREFLIGHT_REVIEW" SKILL_DIR="$PREFLIGHT_SKILL" \
   SW_USER_CODEX_HOME="$CODEX_HOME" \
   RUNLOG="$TMPD/preflight-missing-prompt.log" /bin/bash -c \
   'log(){ printf "%s\n" "$*" >>"$RUNLOG"; }; . "$1"; preflight_deps' _ "$PREFLIGHT_BLOCK"; then
  bad "约束提示词缺失时依赖预检仍放行"
elif grep -q 'prompts/fix.md' "$TMPD/preflight-missing-prompt.log"; then
  ok "约束提示词缺失时在调用 AI 前失败关闭并给出诊断"
else
  bad "约束提示词缺失虽被拒绝但诊断未指出缺失文件"
fi

PREFLIGHT_NO_AUTH="$TMPD/preflight-no-auth"
mkdir -p "$PREFLIGHT_NO_AUTH"
: > "$TMPD/preflight-no-auth.log"
if PATH="$PREFLIGHT_BIN" CODEX_BIN="$PREFLIGHT_CODEX" REVIEW_SH="$PREFLIGHT_REVIEW" SKILL_DIR="$ROOT_DIR" \
   SW_USER_CODEX_HOME="$PREFLIGHT_NO_AUTH" \
   RUNLOG="$TMPD/preflight-no-auth.log" /bin/bash -c \
   'log(){ printf "%s\n" "$*" >>"$RUNLOG"; }; . "$1"; preflight_deps' _ "$PREFLIGHT_BLOCK"; then
  bad "Codex 登录态缺失时依赖预检仍放行"
elif grep -q 'codex-auth' "$TMPD/preflight-no-auth.log"; then
  ok "Codex 登录态缺失在任何 AI 调用前失败关闭并给出诊断"
else
  bad "Codex 登录态缺失虽被拒绝但诊断不明确"
fi

# Once the lock is held, even startup dependency probes must be under the
# watchdog. Hang only the node liveness probe; the watchdog should terminate
# the orchestrator and its child, run EXIT cleanup, and release NIGHT.lock.
STARTUP_HANG_ROOT="$TMPD/startup-hang-root"
mkdir -p "$STARTUP_HANG_ROOT/codex"
printf '{"morning_hour":"07:00","ntfy_topic":"test_topic"}\n' > "$STARTUP_HANG_ROOT/codex/config.json"
cat > "$STARTUP_HANG_ROOT/queue.md" <<EOF
## startup hang probe
- id: startup-hang
- repo: $REPO
- type: bugfix
> Must never reach task execution.
EOF
cat > "$BIN/node" <<FAKENODE
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in
  -e:*'JSON.parse(s)'*) while :; do :; done ;;
esac
exec "$REAL_NODE" "\$@"
FAKENODE
chmod +x "$BIN/node"
STARTUP_HANG_START="$(date +%s)"
STARTUP_HANG_FORCED=no
case "$-" in *m*) STARTUP_PREV_M=yes ;; *) STARTUP_PREV_M=no ;; esac
set -m
SLEEP_WELL_ROOT="$STARTUP_HANG_ROOT" SLEEP_WELL_CODEX="$BIN/codex" \
  SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW" SLEEP_WELL_AI_TIMEOUT=5 \
  SLEEP_WELL_HANG_LIMIT=6 SLEEP_WELL_WATCHDOG_POLL=1 SLEEP_WELL_WATCHDOG_GRACE=3 \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1 &
STARTUP_HANG_PID=$!
[ "$STARTUP_PREV_M" = no ] && set +m
STARTUP_HANG_POLLS=0
while kill -0 "$STARTUP_HANG_PID" 2>/dev/null && [ "$STARTUP_HANG_POLLS" -lt 25 ]; do
  sleep 1
  STARTUP_HANG_POLLS=$((STARTUP_HANG_POLLS + 1))
done
if kill -0 "$STARTUP_HANG_PID" 2>/dev/null; then
  STARTUP_HANG_FORCED=yes
  kill -TERM -"$STARTUP_HANG_PID" 2>/dev/null || kill -TERM "$STARTUP_HANG_PID" 2>/dev/null || true
  sleep 1
  kill -KILL -"$STARTUP_HANG_PID" 2>/dev/null || kill -KILL "$STARTUP_HANG_PID" 2>/dev/null || true
fi
wait "$STARTUP_HANG_PID" 2>/dev/null || true
STARTUP_HANG_ELAPSED=$(( $(date +%s) - STARTUP_HANG_START ))
rm -f "$BIN/node"
STARTUP_HANG_LOG="$(cat "$STARTUP_HANG_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$STARTUP_HANG_FORCED" = no ] \
  && [ "$STARTUP_HANG_ELAPSED" -lt 25 ] \
  && printf '%s' "$STARTUP_HANG_LOG" | grep -q '看门狗: 心跳停滞' \
  && [ ! -e "$STARTUP_HANG_ROOT/NIGHT.lock" ]; then
  ok "锁前 topic 读取不调用 node，锁后 JSON 探测挂起由看门狗终止"
else
  bad "锁前 node 挂起或主看门狗未覆盖锁后启动期（elapsed=${STARTUP_HANG_ELAPSED}s, forced=${STARTUP_HANG_FORCED}）"
fi

# The ps probes needed to publish/validate a lock run before the main watchdog.
# Their dedicated startup process-group timeout must prevent a broken ps shim
# from swallowing the entire night.
STARTUP_PS_ROOT="$TMPD/startup-ps-root"
mkdir -p "$STARTUP_PS_ROOT/codex"
printf '{"morning_hour":"07:00","ntfy_topic":"test_topic"}\n' > "$STARTUP_PS_ROOT/codex/config.json"
cat > "$BIN/ps" <<'FAKEPS'
#!/usr/bin/env bash
while :; do :; done
FAKEPS
chmod +x "$BIN/ps"
STARTUP_PS_START="$(date +%s)"
SLEEP_WELL_ROOT="$STARTUP_PS_ROOT" SLEEP_WELL_STARTUP_TIMEOUT=3 \
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
STARTUP_PS_ELAPSED=$(( $(date +%s) - STARTUP_PS_START ))
rm -f "$BIN/ps"
STARTUP_PS_LOG="$(cat "$STARTUP_PS_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ "$STARTUP_PS_ELAPSED" -lt 15 ] \
  && printf '%s' "$STARTUP_PS_LOG" | grep -q '启动阶段命令超时.*读取当前进程启动时间' \
  && [ ! -e "$STARTUP_PS_ROOT/NIGHT.lock" ]; then
  ok "锁 owner 的 ps 探针挂起会在启动时限内失败关闭"
else
  bad "锁前 ps 挂起未被启动时限收敛（elapsed=${STARTUP_PS_ELAPSED}s）"
fi

# Broken/missing node must still produce a fresh local report and one ntfy
# alert using the shell fallback; otherwise the previous night's report lies.
NODELESS_ROOT="$TMPD/nodeless-root"
mkdir -p "$NODELESS_ROOT/codex"
printf '{ "ntfy_topic": "test_topic" }\n' > "$NODELESS_ROOT/codex/config.json"
printf '{"hook":"%s","backup":"%s","token":"test-token"}\n' \
  "$NODELESS_ROOT/user-pre-push" "$NODELESS_ROOT/user-pre-push.backup" \
  > "$NODELESS_ROOT/codex/hook-recovery.json"
cat > "$BIN/node" <<'FAKE'
#!/usr/bin/env bash
exit 127
FAKE
chmod +x "$BIN/node"
: > "$FAKE_CURL_PAYLOAD"
SLEEP_WELL_ROOT="$NODELESS_ROOT" SLEEP_WELL_CODEX="$BIN/codex" \
  SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW" /bin/bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
NODELESS_LOG="$(cat "$NODELESS_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if grep -q '缺少依赖: node' "$NODELESS_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q 'terminal-clear 并重新 load' "$NODELESS_ROOT/codex/morning-report.md" 2>/dev/null \
  && grep -q '^raw:.*node' "$FAKE_CURL_PAYLOAD" 2>/dev/null \
  && grep -q '^raw:.*terminal-clear 并重新 load' "$FAKE_CURL_PAYLOAD" 2>/dev/null \
  && ! grep -q '下一跳重试' "$FAKE_CURL_PAYLOAD" 2>/dev/null \
  && printf '%s' "$NODELESS_LOG" | grep -q 'node 不可用，无法解析 hook 恢复元数据' \
  && printf '%s' "$NODELESS_LOG" | grep -q 'PUSH\[⚠️ 夜班未开工\]' \
  && ! printf '%s' "$NODELESS_LOG" | grep -q 'hook 恢复元数据损坏' \
  && [ -f "$NODELESS_ROOT/codex/TERMINATED" ]; then
  ok "node 失效且有 hook 恢复材料时如实诊断、生成早报并推送一次告警"
else
  bad "node 失效且有 hook 恢复材料时诊断仍指错方向或早报/推送缺失"
fi

# The shell fallback must validate the exact configured topic. The old sed
# captured only the legal prefix of `test_topic.public` and sent the alert to
# the different public topic `test_topic`.
NODELESS_BAD_ROOT="$TMPD/nodeless-invalid-topic-root"
mkdir -p "$NODELESS_BAD_ROOT/codex"
printf '{ "ntfy_topic": "test_topic.public" }\n' > "$NODELESS_BAD_ROOT/codex/config.json"
: > "$FAKE_CURL_PAYLOAD"
SLEEP_WELL_ROOT="$NODELESS_BAD_ROOT" SLEEP_WELL_CODEX="$BIN/codex" \
  SLEEP_WELL_CLAUDE_REVIEW="$GOOD_REVIEW" /bin/bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
NODELESS_BAD_LOG="$(cat "$NODELESS_BAD_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
if [ ! -s "$FAKE_CURL_PAYLOAD" ] \
  && printf '%s' "$NODELESS_BAD_LOG" | grep -q 'ntfy_topic 含非法字符'; then
  ok "node 失效时非法 ntfy topic 不截断、不推向其它公开 topic"
else
  bad "node 失效时 ntfy topic 仍被截断或未明确拒绝"
fi
rm -f "$BIN/node"

# A persistent archive failure must retry without publishing the same two
# notifications on every launchd interval.
ARCHIVE_FAIL_ROOT="$TMPD/archive-fail-root"
mkdir -p "$ARCHIVE_FAIL_ROOT/codex/state"
printf '{"ntfy_topic":"test_topic"}\n' > "$ARCHIVE_FAIL_ROOT/codex/config.json"
printf '{"startedAt":1,"cutoffEpoch":1,"tasks":[]}\n' > "$ARCHIVE_FAIL_ROOT/codex/state/current-run.json"
# Force the quarantine alert's primary marker path to fail mkdir. The runtime
# fallback marker must still deliver once and deduplicate the second tick.
: > "$ARCHIVE_FAIL_ROOT/codex/state/.push-once-finalize-quarantine-failure"
cat > "$BIN/node" <<FAKENODE
#!/usr/bin/env bash
if [ "\${1:-}" = "$CLI_PATH" ]; then
  case "\${2:-}" in quarantine-inflight|mark-terminal-in-state|archive) exit 97 ;; esac
fi
exec "$REAL_NODE" "\$@"
FAKENODE
chmod +x "$BIN/node"
SLEEP_WELL_ROOT="$ARCHIVE_FAIL_ROOT" bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
SLEEP_WELL_ROOT="$ARCHIVE_FAIL_ROOT" bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
rm -f "$BIN/node"
ARCHIVE_FAIL_LOG="$(cat "$ARCHIVE_FAIL_ROOT/codex/logs/"orchestrator-*.log 2>/dev/null)"
ARCHIVE_SUMMARY_PUSHES="$(printf '%s' "$ARCHIVE_FAIL_LOG" | grep -c 'PUSH\[☀️ 夜班早报\]' || true)"
ARCHIVE_ERROR_PUSHES="$(printf '%s' "$ARCHIVE_FAIL_LOG" | grep -c 'PUSH\[⚠️ 夜班收工异常\].*归档失败' || true)"
ARCHIVE_QUARANTINE_PUSHES="$(printf '%s' "$ARCHIVE_FAIL_LOG" | grep -c 'PUSH\[⚠️ 夜班收工异常\].*无法确认在途任务状态' || true)"
ARCHIVE_TERMINAL_WRITE_PUSHES="$(printf '%s' "$ARCHIVE_FAIL_LOG" | grep -c 'PUSH\[⚠️ 夜班收工异常\].*终止状态未能写入' || true)"
if [ "$ARCHIVE_SUMMARY_PUSHES" -eq 1 ] \
  && [ "$ARCHIVE_ERROR_PUSHES" -eq 1 ] \
  && [ "$ARCHIVE_QUARANTINE_PUSHES" -eq 1 ] \
  && [ "$ARCHIVE_TERMINAL_WRITE_PUSHES" -eq 1 ] \
  && [ -d "$ARCHIVE_FAIL_ROOT/codex/.push-once-fallback-finalize-quarantine-failure" ] \
  && [ ! -f "$ARCHIVE_FAIL_ROOT/codex/TERMINATED" ] \
  && [ -f "$ARCHIVE_FAIL_ROOT/codex/state/current-run.json" ]; then
  ok "持续收工失败会重试且四类通知各只发一次（含备用去重标记）"
else
  bad "持续收工失败仍重复推送或错误终止（summary=${ARCHIVE_SUMMARY_PUSHES}, archive=${ARCHIVE_ERROR_PUSHES}, quarantine=${ARCHIVE_QUARANTINE_PUSHES}, terminal=${ARCHIVE_TERMINAL_WRITE_PUSHES}）"
fi

# Two runs started in the same second must retain two archives, and lexical
# newest selection must choose the later collision.
ARCHIVE_ROOT="$TMPD/archive-root"
mkdir -p "$ARCHIVE_ROOT/codex/state"
printf '{"startedAt":1000,"tasks":[{"id":"first"}]}\n' > "$ARCHIVE_ROOT/codex/state/current-run.json"
SLEEP_WELL_ROOT="$ARCHIVE_ROOT" node "$CLI_PATH" archive >/dev/null 2>&1
printf '{"startedAt":1000,"tasks":[{"id":"second"}]}\n' > "$ARCHIVE_ROOT/codex/state/current-run.json"
SLEEP_WELL_ROOT="$ARCHIVE_ROOT" node "$CLI_PATH" archive >/dev/null 2>&1
ARCHIVE_COUNT="$(find "$ARCHIVE_ROOT/codex/state" -name 'run-*.json' -type f | wc -l | tr -d ' ')"
if [ "$ARCHIVE_COUNT" -eq 2 ] \
  && node -e '
    const fs=require("fs"), path=require("path"), dir=process.argv[1];
    const files=fs.readdirSync(dir).filter(x=>/^run-.*\.json$/.test(x)).sort();
    const newest=files.at(-1), run=JSON.parse(fs.readFileSync(path.join(dir,newest),"utf8"));
    process.exit(/~001\.json$/.test(newest) && run.tasks?.[0]?.id==="second" ? 0 : 1);
  ' "$ARCHIVE_ROOT/codex/state"; then
  ok "同秒二次开工保留两份归档且 newest-last 选择后写入者"
else
  bad "同秒二次归档覆盖或 newest-last 选择错误（仅 ${ARCHIVE_COUNT} 份）"
fi

# The installed Codex skill must test independently; only inspect the sibling
# Claude variant when this is the complete source tree.
CODEX_PLIST="$ROOT_DIR/bin/com.user.sleepwell-codex.plist"
SIBLING_PLIST="$ROOT_DIR/../sleep-well/bin/com.user.sleepwell-watchdog.plist"
if grep -q '/tmp/sleepwell' "$CODEX_PLIST" \
  || ! grep -q 'umask 077' "$CODEX_PLIST" \
  || ! grep -q 'Library/Logs/sleep-well' "$CODEX_PLIST"; then
  bad "Codex launchd 模板仍含共享 /tmp 日志路径或未收紧权限"
elif [ -f "$SIBLING_PLIST" ] \
  && { grep -q '/tmp/sleepwell' "$SIBLING_PLIST" \
       || ! grep -q 'Library/Logs/sleep-well' "$SIBLING_PLIST"; }; then
  bad "Claude watchdog launchd 模板仍含共享 /tmp 日志路径或未收紧权限"
else
  ok "launchd 模板使用用户私有日志目录而非共享 /tmp"
fi

printf '\ne2e: pass %d / fail %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
