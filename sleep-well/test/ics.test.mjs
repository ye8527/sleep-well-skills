import { test } from "node:test";
import assert from "node:assert/strict";
import { parseIcs, deriveCalendarTasks } from "../lib/ics.mjs";

const ICS = [
  "BEGIN:VCALENDAR",
  "BEGIN:VEVENT",
  "SUMMARY:Prepare slides for lab meeting",
  "DTSTART;TZID=Asia/Tokyo:20260617T100000",
  "DESCRIPTION:bring the Q2 figures",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "SUMMARY:Lunch with Kenji",
  "DTSTART:20260617T120000Z",
  "END:VEVENT",
  "END:VCALENDAR",
].join("\r\n");

test("parseIcs extracts VEVENTs with summary/start/notes", () => {
  const ev = parseIcs(ICS);
  assert.equal(ev.length, 2);
  assert.equal(ev[0].summary, "Prepare slides for lab meeting");
  assert.equal(ev[0].start, "20260617T100000");
  assert.equal(ev[0].notes, "bring the Q2 figures");
  assert.equal(ev[1].summary, "Lunch with Kenji");
});

test("deriveCalendarTasks keeps only artifact-implying events, all propose-only", () => {
  const tasks = deriveCalendarTasks(parseIcs(ICS));
  assert.equal(tasks.length, 1); // "Prepare slides..." implies an artifact; "Lunch" does not
  assert.equal(tasks[0].source, "tier4-calendar");
  assert.equal(tasks[0].propose, true);
  assert.match(tasks[0].title, /Prepare slides/);
});

test("deriveCalendarTasks matches CJK artifact titles", () => {
  const ev = [{ summary: "准备周会材料" }, { summary: "和朋友吃饭" }];
  const tasks = deriveCalendarTasks(ev);
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].title, "准备周会材料");
});

test("parseIcs unfolds RFC5545 folded lines", () => {
  const ics = "BEGIN:VEVENT\r\nSUMMARY:Prepare the quar\r\n terly figures\r\nEND:VEVENT";
  const ev = parseIcs(ics);
  assert.equal(ev[0].summary, "Prepare the quarterly figures");
});
