import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildReviewArgs, parseReviewOutput, extractFindings, verifyFindingsIntegrity } from "../lib/claudeReview.mjs";

test("buildReviewArgs: 三种 scope", () => {
  assert.deepEqual(buildReviewArgs({ repo: "/r" }), ["-C","/r","--uncommitted","-t","decision"]);
  assert.deepEqual(buildReviewArgs({ repo: "/r", scope: "base", base: "main" }), ["-C","/r","--base","main","-t","decision"]);
  assert.deepEqual(buildReviewArgs({ repo: "/r", scope: "commit", base: "abc" }), ["-C","/r","--commit","abc","-t","decision"]);
  assert.throws(() => buildReviewArgs({ repo: "/r", scope: "base" }));
});

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
});
