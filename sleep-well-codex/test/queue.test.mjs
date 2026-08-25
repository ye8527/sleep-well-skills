// test/queue.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseQueue } from "../lib/queue.mjs";

const SAMPLE = `# Night queue

## Add CSV export
- id: t1
- repo: ~/Projects/example-repo
- priority: 1
- type: feature

Implement a CSV export button on the results page.

## Fix typo in README
- id: t2
- repo: ~/Projects/example-repo
- priority: 2
- type: docs

Correct the broken install command.
`;

test("parseQueue returns tasks in priority order with defaults applied", () => {
  const tasks = parseQueue(SAMPLE);
  assert.equal(tasks.length, 2);
  assert.equal(tasks[0].id, "t1");
  assert.equal(tasks[0].title, "Add CSV export");
  assert.equal(tasks[0].repo, process.env.HOME + "/Projects/example-repo");
  assert.equal(tasks[0].priority, 1);
  assert.equal(tasks[0].type, "feature");
  assert.match(tasks[0].prompt, /CSV export button/);
  assert.equal(tasks[0].status, "pending");
  assert.equal(tasks[0].reviewRounds, 0);
  assert.equal(tasks[0].reviewRotations, 0);
  assert.deepEqual(tasks[0].findingsHistory, []);
});

test("parseQueue sorts by priority ascending", () => {
  const tasks = parseQueue("## B\n- id: b\n- priority: 5\n\nx\n## A\n- id: a\n- priority: 1\n\ny\n");
  assert.deepEqual(tasks.map((t) => t.id), ["a", "b"]);
});

test("parseQueue throws on a block missing an id", () => {
  assert.throws(() => parseQueue("## No id\n- priority: 1\n\nbody\n"), /missing id/);
});

test("parseQueue passes through optional files/team fields", () => {
  const tasks = parseQueue("## Big\n- id: x\n- type: feature\n- files: 7\n- team: true\n\nbody\n");
  assert.equal(tasks[0].files, 7);
  assert.equal(tasks[0].team, true);
});

test("parseQueue expands ~ in repo to an absolute path", () => {
  const tasks = parseQueue("## T\n- id: x\n- repo: ~/proj\n- priority: 1\n\nbody\n");
  assert.equal(tasks[0].repo, process.env.HOME + "/proj");
});

test("untyped queue tasks default to inline-routed 'task'", () => {
  const tasks = parseQueue("## X\n- id: x\n- priority: 1\n\nbody\n");
  assert.equal(tasks[0].type, "task");
});

test("parseQueue keeps non-meta bullets (e.g. - Expected:) in the prompt", () => {
  const tasks = parseQueue("## T\n- id: x\n- type: bugfix\n\nReproduce then fix.\n- Expected: returns 200\n");
  assert.match(tasks[0].prompt, /Expected: returns 200/);
  assert.equal(tasks[0].type, "bugfix");
});

// R15 自查: 这个模块解析的是**用户手写的 Markdown**，而它十五轮没被单独审过。
// 三条都是我自己查出来的，Codex 本轮聚焦在 diff 上没覆盖到。
test("queue: id 只允许安全字符（它会被拼进文件路径）", () => {
  // 编排器用 `$LOG_DIR/${id}-*.out` 与 `$LOG_DIR/${id}.md`，`../` 会写到 logs 之外。
  // 队列是用户手写的，所以这不是攻击面，而是打错字就写到意想不到的地方——失败必须响亮。
  // R16 #2: R15 我限定 id 只能是 A-Za-z0-9._- ——**那是过度纠正**，
  // queue.md 与 Claude 侧共享且用户手写，中文/含空格 id 完全合法，
  // 整队拒绝解析会让一次升级静默停掉安装。只拦真正危险的那两类。
  assert.throws(() => parseQueue("## A\n- id: ../../evil\n> x\n"), /路径分隔符/);
  assert.throws(() => parseQueue("## A\n- id: a/b\n> x\n"), /路径分隔符/);
  assert.doesNotThrow(() => parseQueue("## A\n- id: 修复空指针\n> x\n"));
  assert.doesNotThrow(() => parseQueue("## A\n- id: task 1\n> x\n"));
});

test("queue: priority/files 非整数时报错，而不是静默变 NaN", () => {
  // NaN 参与比较全为 false → sort 结果不可预测且无任何提示
  assert.throws(() => parseQueue("## A\n- id: a\n- priority: l\n> x\n"), /priority/);
  assert.throws(() => parseQueue("## A\n- id: a\n- files: 三\n> x\n"), /files/);
  const t = parseQueue("## A\n- id: a\n- priority: 5\n> x\n");
  assert.equal(t[0].priority, 5);
});

test("queue: 重复 id 检查只做一次（曾有一段被误粘贴进循环内部）", () => {
  assert.throws(() => parseQueue("## A\n- id: a\n> x\n\n## B\n- id: a\n> y\n"), /重复/);
  // 多个不同 id 正常
  assert.equal(parseQueue("## A\n- id: a\n> x\n\n## B\n- id: b\n> y\n").length, 2);
});
