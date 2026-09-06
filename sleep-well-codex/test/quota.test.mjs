import { test } from "node:test";
import assert from "node:assert/strict";
import { classifyOutcome, decideHop, nextBackoffHops } from "../lib/quota.mjs";

test("classifyOutcome: 各类信号", () => {
  assert.equal(classifyOutcome("", 0, "codex").kind, "ok");
  assert.equal(classifyOutcome("rate limit exceeded", 1, "codex").kind, "quota");
  assert.equal(classifyOutcome("Not logged in · Please run /login", 1, "claude").kind, "auth");
  assert.equal(classifyOutcome("529 overloaded", 1, "codex").kind, "transient");
  assert.equal(classifyOutcome("something weird", 1, "codex").kind, "other");
});

test("本地超时与普通任务正文绝不升级为认证失效", () => {
  assert.equal(
    classifyOutcome("正在修复 OAuth 401 unauthorized credential 重试", 124, "codex").kind,
    "transient",
  );
  assert.equal(
    classifyOutcome("实现 authenticate() 时测试失败: credential fixture missing", 1, "codex").kind,
    "other",
  );
  assert.equal(classifyOutcome("Error: 401 Unauthorized", 1, "codex").kind, "auth");
});

test("claude-handoff 自报的 kind 优先采信", () => {
  assert.equal(classifyOutcome("CLAUDE_UNAVAILABLE (quota)", 2, "claude").kind, "quota");
  assert.equal(classifyOutcome("CLAUDE_UNAVAILABLE (auth)", 2, "claude").kind, "auth");
  assert.equal(classifyOutcome("CLAUDE_UNAVAILABLE (other)", 2, "claude").kind, "other");
});

test("退出码 0 + 正文含额度字样 → 判 ok（Codex R1 #17: 不得从成功输出误判）", () => {
  // 一个成功实现「额度处理功能」的任务，正文必然出现 quota/429/exceeded 等词。
  // 按文本判会误判成不可用 → 错误退避甚至 halt。退出码 0 一律视为成功。
  assert.equal(classifyOutcome("usage limit reached", 0, "codex").kind, "ok");
  assert.equal(classifyOutcome("已实现 HTTP 429 重试与 quota 上限提示", 0, "codex").kind, "ok");
});

test("唯一例外: claude-handoff 自报的结构化信号，即便退出码 0 也采信", () => {
  assert.equal(classifyOutcome("CLAUDE_UNAVAILABLE (quota)", 0, "claude").kind, "quota");
  assert.equal(classifyOutcome("CLAUDE_UNAVAILABLE (quota)", 0, "codex").kind, "ok");
});

test("decideHop: 五种动作", () => {
  assert.equal(decideHop("ok","ok").action, "work");
  assert.equal(decideHop("quota","ok").action, "defer-review");
  assert.equal(decideHop("ok","quota").action, "fix-only");
  assert.equal(decideHop("quota","quota").action, "idle");
  assert.equal(decideHop("auth","ok").action, "halt");
  assert.equal(decideHop("ok","auth").action, "halt");
});

test("认证失效优先于一切（重试无用）", () => {
  assert.equal(decideHop("quota","auth").action, "halt");
});

test("nextBackoffHops: 递增后放弃", () => {
  assert.equal(nextBackoffHops(0).hops, 1);
  assert.equal(nextBackoffHops(4).hops, 12);
  assert.equal(nextBackoffHops(6).giveUp, true);
});
