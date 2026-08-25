// lib/findings.mjs
import { appendFileSync } from "node:fs";
import { createHash } from "node:crypto";

export function findingKey({ repo = "", file = "", line = "", issue = "" }) {
  return createHash("sha1").update(`${repo}\0${file}\0${line}\0${issue}`).digest("hex").slice(0, 16);
}

export function appendFinding(path, finding) {
  const rec = { ...finding, key: findingKey(finding) };
  appendFileSync(path, JSON.stringify(rec) + "\n");
  return rec;
}

// （`readFindings` 已删除: 零生产调用，却有单测——而且它对损坏行不加 try/catch，
//   一行坏数据就让整个读取抛异常，与 report.mjs 的 readJsonl 行为相反。R16 自查。）
