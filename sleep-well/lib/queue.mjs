// lib/queue.mjs
// Parse queue.md: each "## Title" starts a task block. Lines "- key: value"
// are fields; remaining non-field, non-heading text is the prompt.
import { expandHome } from "./config.mjs";

const META_KEYS = new Set(["id", "repo", "priority", "type", "files", "team"]);

export function parseQueue(md) {
  const blocks = [];
  let cur = null;
  for (const line of md.split("\n")) {
    const h = line.match(/^##\s+(.+?)\s*$/);
    if (h) {
      if (cur) blocks.push(cur);
      cur = { title: h[1], fields: {}, body: [] };
      continue;
    }
    if (!cur) continue; // skip preamble before first ##
    const f = line.match(/^-\s+(\w+):\s*(.+?)\s*$/);
    if (f && META_KEYS.has(f[1])) cur.fields[f[1]] = f[2];
    else if (line.trim() !== "") cur.body.push(line.replace(/^>\s?/, ""));
  }
  if (cur) blocks.push(cur);

  const tasks = blocks.map((b) => {
    if (!b.fields.id) throw new Error(`queue task "${b.title}" is missing id`);
    return {
      id: b.fields.id,
      title: b.title,
      repo: expandHome(b.fields.repo || ""),
      priority: b.fields.priority ? Number(b.fields.priority) : 100,
      type: b.fields.type || "task",
      files: b.fields.files ? Number(b.fields.files) : undefined,
      team: b.fields.team === "true" ? true : b.fields.team === "false" ? false : undefined,
      prompt: b.body.join("\n").trim(),
      status: "pending",
      reviewRounds: 0,
      reviewRotations: 0,
      findingsHistory: [],
    };
  });
  tasks.sort((a, b) => a.priority - b.priority);
  return tasks;
}
