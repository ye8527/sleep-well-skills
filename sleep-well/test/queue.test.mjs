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
