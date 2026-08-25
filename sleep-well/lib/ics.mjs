// lib/ics.mjs — minimal .ics (VEVENT) parser + propose-only calendar-task derivation.
// Bypasses the broken computer-use Calendar.app path: parse a watched-folder .ics export.

export function parseIcs(text) {
  const unfolded = String(text).replace(/\r?\n[ \t]/g, ""); // RFC 5545: CRLF + space/tab continues the previous line
  const events = [];
  let cur = null;
  for (const raw of unfolded.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "BEGIN:VEVENT") cur = {};
    else if (line === "END:VEVENT") { if (cur) events.push(cur); cur = null; }
    else if (cur) {
      const m = line.match(/^([A-Z]+)(?:;[^:]*)?:(.*)$/);
      if (!m) continue;
      const [, key, val] = m;
      if (key === "SUMMARY") cur.summary = val;
      else if (key === "DTSTART") cur.start = val;
      else if (key === "DESCRIPTION") cur.notes = val;
    }
  }
  return events;
}

const ARTIFACT_RE = /\b(prepare|draft|slides?|agenda|pull data|update (the )?figure|write)\b|准备|草稿|做.{0,6}slides/i;

// PROPOSE-ONLY: only events that imply a concrete prep artifact become (suggested) tasks.
export function deriveCalendarTasks(events) {
  return events
    .filter((e) => e.summary && ARTIFACT_RE.test(`${e.summary} ${e.notes || ""}`))
    .map((e) => ({
      source: "tier4-calendar",
      title: e.summary,
      when: e.start,
      prompt: e.notes ? `${e.summary} — ${e.notes}` : e.summary,
      propose: true,
    }));
}
