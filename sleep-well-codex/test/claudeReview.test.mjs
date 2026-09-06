import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, mkdtempSync, readFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseReviewOutput, extractFindings, verifyFindingsIntegrity } from "../lib/claudeReview.mjs";

test("CLAUDE_UNAVAILABLE 优先于一切", () => {
  const r = parseReviewOutput("FINDINGS_FILE=/x\n", "CLAUDE_UNAVAILABLE (quota)\n", 2);
  assert.equal(r.ok, false); assert.equal(r.unavailable, "quota");
});

test("无 FINDINGS_FILE 一律 ok=false（失败关闭）", () => {
  const r = parseReviewOutput("什么都没有", "", 2);
  assert.equal(r.ok, false); assert.match(r.reason, /不得视为零 findings/);
});

test("条数以 findings 文件元信息头为准", () => {
  const d = mkdtempSync(join(tmpdir(), "cr-"));
  const f = join(d, "findings.md");
  writeFileSync(f, "# x\n\n- findings 条数: 7（读回时…）\n- 高严重度: 3\n");
  const r = parseReviewOutput(`FINDINGS_FILE=${f}\nfindings: 99 条  高: 0\n`, "", 0);
  assert.equal(r.ok, true); assert.equal(r.count, 7); assert.equal(r.high, 3);
});

test("适配器即使发布了有效 findings 文件，非零退出仍是不完整审查", () => {
  const d = mkdtempSync(join(tmpdir(), "cr-exit-"));
  const f = join(d, "findings.md");
  writeFileSync(f, "# x\n\n- findings 条数: 0\n- 高严重度: 0\n");
  const r = parseReviewOutput(`FINDINGS_FILE=${f}\n`, "adapter crashed", 1);
  assert.equal(r.ok, false);
  assert.equal(r.findingsFile, f);
  assert.match(r.reason, /退出码 1.*不完整审查/);
});

test("stdout 声明了 findings 文件但文件不存在 → 失败关闭，绝不退回 stdout（Codex R1 #3）", () => {
  // 契约是「文件存在 ⟺ 完整可信」。退回读 stdout 会让一个「0 条」摘要直接放行任务。
  const r = parseReviewOutput("FINDINGS_FILE=/nope/x.md\nfindings: 4 条  高: 1\n", "", 0);
  assert.equal(r.ok, false);
  assert.match(r.reason, /文件存在才可信/);
});

test("findings 文件存在但条数不可解析 → ok=false，绝不猜", () => {
  const d = mkdtempSync(join(tmpdir(), "cr2-"));
  const f = join(d, "f.md");
  writeFileSync(f, "# 报告\n\n（元信息头缺失）\n");
  const r = parseReviewOutput(`FINDINGS_FILE=${f}\n`, "", 0);
  assert.equal(r.ok, false); assert.match(r.reason, /不得猜测条数/);
});

test("零条是合法的成功——但必须有真实的 findings 文件佐证", () => {
  const d = mkdtempSync(join(tmpdir(), "cr3-"));
  const f = join(d, "f.md");
  writeFileSync(f, "# 报告\n\n- findings 条数: 0（…）\n- 高严重度: 0\n\n无 findings。\n");
  const r = parseReviewOutput(`FINDINGS_FILE=${f}\n`, "", 0);
  assert.equal(r.ok, true); assert.equal(r.count, 0);
});

test("extractFindings: 严重度映射保守（高→needs-human）", () => {
  const md = [
    "### #1 [高] SQL 注入","","- 位置: `db.py` L9-10","- 说明: x","",
    "### #2 [低] 句柄未关闭","","- 位置: `a.py` L3","",
  ].join("\n");
  const fs = extractFindings(md);
  assert.equal(fs.length, 2);
  assert.equal(fs[0].kind, "needs-human"); assert.equal(fs[0].file, "db.py"); assert.equal(fs[0].location, "L9-10");
  assert.equal(fs[1].kind, "auto");
});

test("verifyFindingsIntegrity: 骨架条目数必须等于声明条数", () => {
  const ok = "- [ ] #1 a — \n- [ ] #2 b — \n";
  assert.equal(verifyFindingsIntegrity(ok, 2).ok, true);
  assert.equal(verifyFindingsIntegrity(ok, 3).ok, false);
  assert.equal(verifyFindingsIntegrity("", 0).ok, true);
  const contradictory = verifyFindingsIntegrity("- [ ] #1 stale — \n", 0);
  assert.equal(contradictory.ok, false);
  assert.equal(contradictory.skeleton, 1);
});

test("repository snapshots stream files, enforce bounds, and run through the timeout heartbeat wrapper", () => {
  const cli = readFileSync(new URL("../lib/cli.mjs", import.meta.url), "utf8");
  const orchestrator = readFileSync(new URL("../bin/orchestrator.sh", import.meta.url), "utf8");
  assert.match(cli, /SNAPSHOT_MAX_ENTRIES/);
  assert.match(cli, /SNAPSHOT_MAX_BYTES/);
  assert.match(cli, /readSync\(fd, chunk/);
  assert.doesNotMatch(cli, /h\.update\(readFileSync\(abs\)\)/);
  assert.match(cli, /const index = snapshotGit\(repo, \["ls-files", "--stage", "-z", "--", "\."\]\);/);
  assert.match(orchestrator, /bounded_cli_snapshot repo-content-snapshot/);
  assert.match(orchestrator, /run_with_timeout "\$AI_TIMEOUT_SECS" _run_cli_snapshot_inner/);
  assert.match(orchestrator, /bounded_cli_snapshot review-content-snapshot/);
  assert.match(orchestrator, /checkpoint_commit\(\)/);
  assert.match(orchestrator, /git -C "\$repo" ls-files -- \.review/);
});

test("Git metadata snapshot changes when an untracked hook changes, without invoking Git", () => {
  const d = mkdtempSync(join(tmpdir(), "git-meta-snapshot-"));
  const hooks = join(d, "hooks");
  mkdirSync(hooks);
  const hook = join(hooks, "pre-commit");
  writeFileSync(hook, "#!/bin/sh\nexit 0\n");
  const cli = fileURLToPath(new URL("../lib/cli.mjs", import.meta.url));
  const snap = () => JSON.parse(execFileSync(process.execPath, [cli, "path-content-snapshot", hooks], { encoding: "utf8" })).digest;
  const before = snap();
  writeFileSync(hook, "#!/bin/sh\nexit 99\n");
  assert.notEqual(snap(), before);
});

test("protected-in-null preserves byte-invalid UTF-8 filenames", () => {
  const d = mkdtempSync(join(tmpdir(), "protected-null-"));
  const input = join(d, "input.bin");
  const output = join(d, "output.bin");
  const name = Buffer.concat([Buffer.from([0xff]), Buffer.from(".env")]);
  writeFileSync(input, Buffer.concat([name, Buffer.from([0])]));
  const cli = fileURLToPath(new URL("../lib/cli.mjs", import.meta.url));
  execFileSync(process.execPath, [cli, "protected-in-null", input, output]);
  assert.deepEqual(readFileSync(output), Buffer.concat([name, Buffer.from([0])]));
});

test("Git metadata scope protects security inputs but excludes maintenance caches", () => {
  const orchestrator = readFileSync(new URL("../bin/orchestrator.sh", import.meta.url), "utf8");
  assert.match(orchestrator, /info\/attributes/);
  assert.match(orchestrator, /info\/exclude/);
  assert.match(orchestrator, /objects\/info\/alternates/);
  assert.doesNotMatch(orchestrator, /"\$GUARD_META_COMMON\/objects\/info"/);
  assert.doesNotMatch(orchestrator, /"\$GUARD_META_COMMON\/info"/);
});

test("reviewing transition verifies the current task by id", () => {
  const orchestrator = readFileSync(new URL("../bin/orchestrator.sh", import.meta.url), "utf8");
  assert.match(orchestrator, /get-field "\$id" status/);
  assert.doesNotMatch(orchestrator, /jq_get "\$\(node "\$CLI" next-task\)" task\.status/);
});
