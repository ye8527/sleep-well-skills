// lib/guardrails.mjs
// SAFETY-CRITICAL decision helpers. Enforcement depends on the calling orchestrator;
// see each variant's SKILL.md for the actual boundary.

// KNOWN LIMITATION: this is a fail-closed allowlist + denylist over COMMAND STRINGS. It cannot
// sandbox arbitrary code execution — `node -e`/`python -c`, and especially project scripts run by
// `npm test`/`make`/`cargo test`, can do anything the process can. Fully containing that needs an OS
// sandbox (e.g. sandbox-exec / a container) around task commands. That is the recommended next
// hardening; the allowlist here bounds the ORCHESTRATOR-issued command surface, not what run code does.

const MUTATING_CMDS = new Set(["cp", "mv", "rm", "tee", "dd", "truncate", "ln", "install", "touch", "sed", "perl"]);

const DENY_PATTERNS = [
  /\bsudo\b/,
  /\bdoas\b/,
  /\bgit\b.*\bpush\b/,                       // git push with any flags (incl. `git -C <dir> push`)
  /--force\b|--force-with-lease\b|\bforce-push\b/,
  // `gh` is a general remote mutation/exfiltration client (`api`, `gist`,
  // `repo delete`, ...). Keep only the bounded read-only discovery forms that
  // this skill actually needs; fail closed for every other subcommand.
  /\bgh\s+(?!(?:issue\s+(?:list|view)|pr\s+(?:list|view|diff)|repo\s+view|run\s+(?:list|view)|workflow\s+(?:list|view))\b)/,
  /\bnpm\s+publish\b|\byarn\s+publish\b|\bpnpm\s+publish\b/,
  /\b(yarn|pnpm)\s+(deploy|publish|release)\b/,             // yarn/pnpm deploy|publish|release
  /\b(npm|yarn|pnpm)\b[^|;&]*\brun\b[^|;&]*\b(deploy|publish|release|prod)/i,  // run a deploy-ish script (flags before `run` OK)
  /\b(npm|pnpm)\s+(--?\S+\s+)*exec\b/,                                          // npm/pnpm exec runs an arbitrary package
  /\b(yarn|pnpm)\s+(--?\S+\s+)*dlx\b/,                                          // yarn/pnpm dlx runs an arbitrary package
  /\b(vercel|netlify|fly|railway|wrangler)\b.*\bdeploy\b/,  // deploy anywhere after the tool (incl. `wrangler pages deploy`)
  /\bvercel\b.*--prod\b/,
  /\baws\s+\S+\s+(sync|cp|mv|put|deploy|update-function|update-code)\b/,
  /\bgcloud\b.*\bdeploy\b/,
  /\bterraform\s+(apply|destroy)\b/,
  /\bansible(-playbook)?\b.*\.(ya?ml)\b/,
  /\bheroku\b.*\b(config:set|releases:rollback|addons:create)\b/,
  /\bkubectl\s+(apply|delete|rollout)\b|\bhelm\s+(install|upgrade)\b/,
  /\bdocker\s+push\b/,
  /\b(alembic|prisma|knex|sequelize|flyway|liquibase)\b.*\b(migrate|upgrade|deploy)\b/,
  /\bmigrate\s+(deploy|up|head)\b/,
  /\balembic\s+downgrade\b/,
  /\bliquibase\s+(update|migrate)\b/,
  /\bcurl\b.+\|\s*(ba)?sh\b/,
  /\bwget\b.+\|\s*(ba)?sh\b/,
  /\bcurl\b.*(\s-[A-Za-z]*[TF]|--upload-file\b|--form\b|\s-d\s*@|--data\S*\s*@)/,  // curl upload incl. concatenated -Ffile=@ / -Treport
  /\bwget\b.*(--post-file|--body-file)\b/,                                          // wget file upload exfiltration
  /\bscp\b/,
  /\brsync\b.*\s\S+@\S+:/,
  /\bfind\b[^|;&\n]*\s-(delete|exec|execdir|ok|okdir)\b/,  // action predicates can execute arbitrary commands or mass-delete
  /\brm\b[^|;&\n]*\s(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)\b/,  // recursive rm anywhere in argv: -rf/-Rf/-r, split `-f -r`, --recursive
  /\bgit\b.*\breset\s+--hard\b/,                        // discards uncommitted work the review loop depends on (incl. git -C <dir> reset --hard)
  /\bgit\b.*\bcheckout\b.*(\s--(\s|$)|\s\.(\s|$)|\s-f(\s|$)|\s--force\b)/,  // checkout that discards worktree: `-- <pathspec>`, `.`, `-f`, `--force` (incl. `git checkout HEAD -- file`)
  /\bgit\b.*\bcheckout\s+(?!-)[^\s|;&]+\s+[^\s|;&-]/,        // `git checkout <treeish> <pathspec>` (two positional args) discards files
  /\bgit\b.*\bcheckout\s+[^\s|;&-]\S*\.\w{1,6}(\s|$)/,       // `git checkout file.ext` (single path arg) discards a file
  /\bgit\b.*\bswitch\b.*(\s-f(\s|$)|\s--force\b|\s--discard-changes\b)/,  // `git switch -f` / `--discard-changes` discards worktree
  /\bgit\b.*\brestore\b.*(--worktree|\s-W\b)/,                            // `git restore --worktree` discards even with --staged
  /\bgit\b.*\brestore\b(?!\s+--staged)/,               // `git restore <path>` discards (allow `git restore --staged`)
  /\bgit\b.*\bclean\s+-[a-zA-Z]*[dfx]/,               // `git clean -fd` deletes untracked files
  /\bgit\b.*\bstash\b/,                               // moves the uncheckpointed review diff out of the worktree
  /\bxargs\s+rm\b/,                                    // `find … | xargs rm` mass-delete
  /\bgit\b.*\bbranch\b.*(\s-[a-zA-Z]*[dD]|--delete\b)/,  // git branch -d/-D/-df/--delete removes checkpoint branches
  /\bgit\b.*\bpull\b/,  // pull merges/rebases fetched commits — violates never-merge + changes base
  /\bgit\b.*\bmerge\b/,                                // NEVER merge (incl. git -C <dir> merge)
  /\bgh\s+pr\s+merge\b/,
  /\bsed\b[^|;&]*\s-i\b/,   // sed -i edits files in place, bypassing the backup-aware edit path
  /\bperl\b[^|;&]*\s-i\b/,  // perl -i in-place edit
];

// 边界规则改了多版，每版都被打出反例——所以现在**按关键词分别列后缀**，并双向断言。
//   v1 裸子串        → `sta<nda>rd/` `il<legal>/` 误报，那个仓库每次改动中止整夜（R18）
//   v2 两端要分隔符  → `NDA2026.pdf` `contractual-obligations.pdf` 漏报（R19 #1）
//   v3 统一词尾白名单 → `NDAv2.pdf` `contractDraft.docx` 仍漏，而 `legality/` 误报（R20 #2 #3）
// 规律: 误报来自关键词**前面**接字母（所有关键词一致），漏报来自**后面**——
//       而后面能接什么，**每个关键词都不一样**:
//   · legal   是常见英文词根（legally/legality/legalese/legalize）→ 后面必须是边界
//   · nda / contract / agreement 很少作为别的词的前缀 → 可以带版本/状态后缀
const NOT_LETTER_BEFORE = "(^|[^A-Za-z])";
const B = "([^A-Za-z]|$)";                       // 后置边界
const VER = "(s|es|v?\\d+|final|draft|signed|executed)";   // 版本/状态后缀
const PROTECTED_PATH = new RegExp(
  // CJK: 必须**触到边界**（R20 自查）。原来是裸子串，理由写的是「中文无词边界」——
  // 恰恰相反，无词边界让歧义更严重: `组<合同>步器.js` `符<合同>一标准.md`
  // `联<合同>步测试.ts` `方<法律>定.txt` 全被误判，是中文版的 sta-nda-rd。
  // ⚠️ 仍有一类未解: 日语 `合同テスト`（联合测试）、`合同練習` 等——「合同」在片段开头，
  //    前边界成立，故仍被判为受保护。要排除它就得两边都要边界，而那会误排除 `契約書`。
  //    Codex R20 把这条列为**需要人类拍板**（安全性 vs 夜班可用性）。
  //    当前取安全默认: 宁可误保护（那个仓库会中止整夜、你会立刻发现），
  //    也不漏保护（凭据被改而无人知晓）。见 SKILL.md 已知限制。
  "(^|[^\\u3400-\\u9fff\\u3040-\\u30ff])(合同|契約|法律)" +
  "|(合同|契約|法律)($|[^\\u3400-\\u9fff\\u3040-\\u30ff])" +
  // legal: 后面必须是边界（legally/legality/legalese/legalize 都不是法务文件）
  "|" + NOT_LETTER_BEFORE + "legal" + B +
  // nda / contract / agreement: 允许版本与状态后缀，也允许直接跟边界
  "|" + NOT_LETTER_BEFORE + "(nda|contract|agreement)" + VER + "?" + B +
  "|" + NOT_LETTER_BEFORE + "contract(ual|ing)" + B,
  "i",
);

// 复合词补充规则。通用的「同类字符边界」必须保留，否则 standard/组合同步器
// 会重新误报；但常见法务文书会把关键词包在复合词里。只补高置信长词，避免裸子串。
const CJK_LEGAL_COMPOUND =
  /(合同書|合同书|契約書|協議書|协议书|労働契約|劳动合同|勞動合同|秘密保持契約|秘密保持协议)/;
// 英文补大小写敏感的 CamelCase 边界：EmploymentContract、MasterAgreement、
// ClientNDA2026。小写 standard/contractor 不会命中；已有不区分大小写规则继续
// 处理以边界开头的 contractDraft、NDAv2 等名称。
const CAMEL_LEGAL_COMPOUND =
  /(?:^|[a-z])(?:NDA|Contract|Agreement)(?=(?:s|es|v?\d+|Final|Draft|Signed|Executed)?(?:[^A-Za-z]|$))/;

// 凭据类（Codex R3 #3）: 夜班无人值守，凭据被改或被读的后果比合同更直接。
// 与 PROTECTED_PATH 分开定义再合并，避免把两类语义混在一条难读的正则里。
const CREDENTIAL_PATH =
  /(^|\/)[^\/]*\.env(\.|$)|(^|\/)\.netrc$|(^|\/)\.npmrc$|(^|\/)\.pypirc$|(^|\/)id_(rsa|dsa|ecdsa|ed25519)$|\.pem$|\.p12$|\.pfx$|\.keystore$|(^|\/)credentials(\.json|\.ya?ml)?$|(^|\/)secrets?\.(json|ya?ml|toml|env)$|(^|\/)\.aws\/|(^|\/)\.ssh\/|(^|\/)\.gnupg\/|(^|\/)service[-_]?account[^\/]*\.json$|(^|\/)\.htpasswd$|(^|\/)\.pgpass$|(^|\/)kubeconfig$|(^|\/)\.kube\/|\.jks$|\.key$|(^|\/)\.envrc$|(^|\/)\.git-credentials$/i;

export const ALLOWED_TASK_TYPES = new Set([
  "review-fix", "test", "docs", "lint", "small-todo", "feature", "bugfix", "refactor",
]);

const ALLOW_FIRST_TOKEN = new Set([
  "git", "npm", "pnpm", "yarn", "node", "deno", "bun", "tsx", "ts-node",
  "python", "python3", "pip", "pip3", "pytest", "ruff", "black", "mypy", "flake8", "isort",
  "cargo", "go", "rustc", "gofmt", "make", "cmake", "gradle", "mvn",
  "tsc", "eslint", "prettier", "jest", "vitest", "mocha", "ava",
  "gh", "jq", "sed", "awk", "grep", "rg", "fd", "find", "ls", "cat", "head", "tail",
  "wc", "sort", "uniq", "diff", "echo", "printf", "mkdir", "touch", "cp", "mv",
  "tr", "cut", "rm", "curl", "wget", "true", "false", "pwd", "cd", "date",
  "basename", "dirname", "test", "[",
]);

// Runner prefixes that defer the actual command to a later token.
// "env" and "npx" are removed from ALLOW_FIRST_TOKEN and handled here so
// we can resolve the *effective* command and allowlist-check that instead.
const RUNNERS = new Set(["npx", "nohup", "time", "nice", "timeout", "watch", "stdbuf", "command"]);

function splitSegments(cmd) {
  const segs = [];
  let cur = "", sq = false, dq = false;
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i], n = cmd[i + 1];
    if (c === "'" && !dq) { sq = !sq; cur += c; continue; }
    if (c === '"' && !sq) { dq = !dq; cur += c; continue; }
    if (!sq && !dq) {
      if ((c === "&" && n === "&") || (c === "|" && n === "|")) { segs.push(cur); cur = ""; i++; continue; }
      if (c === "|" || c === ";" || c === "&" || c === "\n") { segs.push(cur); cur = ""; continue; }
    }
    cur += c;
  }
  segs.push(cur);
  return segs;
}

function effectiveToken(seg) {
  let parts = seg.trim().replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+/, "").split(/\s+/).filter(Boolean);
  let guard = 0;
  while (parts.length && guard++ < 6) {
    if (parts[0] === "env") { parts = parts.slice(1); while (parts.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(parts[0])) parts = parts.slice(1); continue; }
    if (RUNNERS.has(parts[0])) { parts = parts.slice(1); while (parts.length && parts[0].startsWith("-")) parts = parts.slice(1); continue; }
    if ((parts[0] === "yarn" || parts[0] === "pnpm") && parts[1] === "dlx") { parts = parts.slice(2); continue; }
    if ((parts[0] === "pnpm" || parts[0] === "npm") && parts[1] === "exec") { parts = parts.slice(2); while (parts.length && parts[0].startsWith("-")) parts = parts.slice(1); continue; }
    break;
  }
  return parts[0] || "";
}

export function classifyCommand(cmd) {
  // 1) explicit hard denies first (precise reasons; also covers dangerous forms of allowlisted tools)
  for (const re of DENY_PATTERNS) {
    if (re.test(cmd)) return { allowed: false, reason: `denied by guardrail ${re}` };
  }
  // 2) deny command/process substitution — the shell evaluates their nested
  // commands before the allowlisted outer command sees the result.
  if (/\$\(|`|[<>]\(/.test(cmd)) return { allowed: false, reason: "command/process substitution — needs human" };
  // 2b) deny shell output redirection to files (allows 2>&1, >&2, >/dev/null)
  //     Strip fd-dup redirects (2>&1, >&2) and /dev/null redirects first so the
  //     segment splitter (which splits on bare `&`) does not misparse them.
  const cmdStripped = cmd
    .replace(/\d*>>?\/dev\/null\b/g, "")   // >/dev/null, 2>/dev/null, >>/dev/null …
    .replace(/\d*>&\d*/g, "");              // 2>&1, >&2, 1>&2 …
  if (/\d*>>?\s*(?!&|\/dev\/null\b)[^\s&|;]/.test(cmdStripped)) {
    return { allowed: false, reason: "shell output redirection to a file — needs human (use file tools, not >)" };
  }
  // 3) fail-closed: every segment (including & and \n separators) must resolve to a known-safe command
  for (const seg of splitSegments(cmdStripped)) {
    if (seg.trim() === "") continue;
    const tok = effectiveToken(seg);
    if (MUTATING_CMDS.has(tok) && isProtectedPath(seg)) {
      return { allowed: false, reason: "command would mutate a protected (contract/legal) document" };
    }
    if (!ALLOW_FIRST_TOKEN.has(tok)) {
      return { allowed: false, reason: `not on safe allowlist (unknown command "${tok}") — needs human` };
    }
  }
  return { allowed: true, reason: "ok" };
}

// 模板/示例文件不是真凭据，误判会让任务无法开工（Codex R4 #10）
// ⚠️ 后三条原本**没有末尾锚定**（Codex R18 + 我 R18 自查，两边独立发现）:
//   任何**包含** `.env.example` 子串的路径都会命中豁免，凭据判定被整个跳过——
//   实测 `.env.example.real` / `.env.example.prod` / `config/.env.sample.bak`
//   全部不受保护，而它们几乎肯定是真凭据。加 `$` 之后 `.env.example` 与
//   `.env.production.example` 仍豁免（由前面的 `\.example$` 兜住），另两类回归受保护。
const CREDENTIAL_EXEMPT = /(\.example$|\.sample$|\.template$|\.dist$|(^|\/)\.env\.example$|(^|\/)\.env\.sample$|(^|\/)\.env\.template$)/i;

export function isProtectedPath(p) {
  const legal = PROTECTED_PATH.test(p) || CJK_LEGAL_COMPOUND.test(p) || CAMEL_LEGAL_COMPOUND.test(p);
  if (CREDENTIAL_EXEMPT.test(p)) return legal;
  return legal || CREDENTIAL_PATH.test(p);
}

// Deterministic gate for the model-driven variant's pre-task status probe.
// Probe failure is never equivalent to a clean repository.
export function baselineGate(porcelainText, probeOk = true) {
  if (probeOk !== true) return { clean: false, reason: "git status probe failed" };
  if (String(porcelainText ?? "").trim() !== "") {
    return { clean: false, reason: "repository has pre-existing changes" };
  }
  return { clean: true, reason: "clean" };
}
