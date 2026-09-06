// test/codexReview.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildReviewArgs, parseFindings, reviewExecOptions, reviewTimeoutMs } from "../lib/codexReview.mjs";

test("buildReviewArgs targets uncommitted changes", () => {
  assert.deepEqual(buildReviewArgs({ scope: "uncommitted" }), ["exec", "review", "--uncommitted", "--json"]);
});

test("buildReviewArgs supports base-branch scope", () => {
  assert.deepEqual(buildReviewArgs({ scope: "base", base: "main" }), ["exec", "review", "--base", "main", "--json"]);
});

test("review execution closes stdin and has a bounded configurable timeout", () => {
  assert.equal(reviewTimeoutMs(undefined), 1_800_000);
  assert.equal(reviewTimeoutMs("45"), 45_000);
  assert.throws(() => reviewTimeoutMs("0"), /between 1 and 86400/);
  assert.throws(() => reviewTimeoutMs("forever"), /integer/);
  const opts = reviewExecOptions("/tmp/repo", "12");
  assert.deepEqual(opts.stdio, ["ignore", "pipe", "pipe"]);
  assert.equal(opts.timeout, 12_000);
  assert.equal(opts.cwd, "/tmp/repo");
});

test("parseFindings counts zero on empty findings", () => {
  assert.deepEqual(parseFindings('{"type":"review","findings":[]}'), {
    count: 0, findings: [], reviewed: true,
  });
});

test("parseFindings extracts findings across JSONL lines, last wins", () => {
  const out = [
    '{"type":"progress"}',
    '{"type":"review","findings":[{"file":"a.js","line":3,"issue":"bug","severity":"high"}]}',
  ].join("\n");
  const r = parseFindings(out);
  assert.equal(r.count, 1);
  assert.equal(r.findings[0].file, "a.js");
});

test("parseFindings is robust to non-JSON noise lines", () => {
  const out = "warning: something\n" + '{"findings":[]}';
  assert.deepEqual(parseFindings(out), { count: 0, findings: [], reviewed: true });
});

test("parseFindings fails the trust predicate when no review body exists", () => {
  const out = [
    '{"type":"thread.started","thread_id":"abc"}',
    '{"type":"turn.started"}',
    '{"type":"turn.completed"}',
  ].join("\n");
  assert.deepEqual(parseFindings(out), { count: 0, findings: [], reviewed: false });
});

// NOTE: real codex exec review --json JSONL has no findings[] array.
// The agent emits type:"item.completed" with item.type:"agent_message" and a text field.
// parseFindings handles this via the agentText fallback path.
test("parseFindings extracts agent_message text from real codex JSONL output", () => {
  const out = [
    '{"type":"thread.started","thread_id":"abc"}',
    '{"type":"turn.started"}',
    '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Bug: add() returns a-b not a+b. Severity: High"}}',
    '{"type":"turn.completed","usage":{"input_tokens":10}}',
  ].join("\n");
  const r = parseFindings(out);
  // No structured findings[] array, so count=0 but agentText is populated
  assert.equal(r.count, 0);
  assert.equal(r.reviewed, true);
  assert.ok(r.agentText.includes("Bug"));
});
