// lib/guardrails.mjs
// SAFETY-CRITICAL. Enforced in code, never left to model judgement.

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
  /\bgh\s+(pr|release)\s+create\b/,
  /\bgh\s+(secret|variable|workflow)\s+\S+/,
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
  /\bfind\b.*(-delete|-exec\s+rm)\b/,
  /\brm\b[^|;&\n]*\s(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)\b/,  // recursive rm anywhere in argv: -rf/-Rf/-r, split `-f -r`, --recursive
  /\bgit\b.*\breset\s+--hard\b/,                        // discards uncommitted work the review loop depends on (incl. git -C <dir> reset --hard)
  /\bgit\b.*\bcheckout\b.*(\s--(\s|$)|\s\.(\s|$)|\s-f(\s|$)|\s--force\b)/,  // checkout that discards worktree: `-- <pathspec>`, `.`, `-f`, `--force` (incl. `git checkout HEAD -- file`)
  /\bgit\b.*\bcheckout\s+(?!-)[^\s|;&]+\s+[^\s|;&-]/,        // `git checkout <treeish> <pathspec>` (two positional args) discards files
  /\bgit\b.*\bcheckout\s+[^\s|;&-]\S*\.\w{1,6}(\s|$)/,       // `git checkout file.ext` (single path arg) discards a file
  /\bgit\b.*\bswitch\b.*(\s-f(\s|$)|\s--force\b|\s--discard-changes\b)/,  // `git switch -f` / `--discard-changes` discards worktree
  /\bgit\b.*\brestore\b.*(--worktree|\s-W\b)/,                            // `git restore --worktree` discards even with --staged
  /\bgit\b.*\brestore\b(?!\s+--staged)/,               // `git restore <path>` discards (allow `git restore --staged`)
  /\bgit\b.*\bclean\s+-[a-zA-Z]*[dfx]/,               // `git clean -fd` deletes untracked files
  /\bxargs\s+rm\b/,                                    // `find … | xargs rm` mass-delete
  /\bgit\b.*\bbranch\b.*(\s-[a-zA-Z]*[dD]|--delete\b)/,  // git branch -d/-D/-df/--delete removes checkpoint branches
  /\bgit\b.*\bpull\b/,  // pull merges/rebases fetched commits — violates never-merge + changes base
  /\bgit\b.*\bmerge\b/,                                // NEVER merge (incl. git -C <dir> merge)
  /\bgh\s+pr\s+merge\b/,
  /\bsed\b[^|;&]*\s-i\b/,   // sed -i edits files in place, bypassing the backup-aware edit path
  /\bperl\b[^|;&]*\s-i\b/,  // perl -i in-place edit
];

const PROTECTED_PATH = /(合同|契約|contract|法律|legal|nda|agreement)/i;

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
  // 2) deny command substitution — shell evaluates $(...) / backtick before we see the result
  if (/\$\(|`/.test(cmd)) return { allowed: false, reason: "command substitution — needs human" };
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

export function isProtectedPath(p) {
  return PROTECTED_PATH.test(p);
}
