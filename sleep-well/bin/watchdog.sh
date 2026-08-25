#!/bin/sh
# sleep-well out-of-band watchdog — OFF by default. See docs/resilience-watchdog.md.
HOME_DIR="${SLEEP_WELL_HOME:-$HOME/sleep-well}"
SKILL="$HOME/.claude/skills/sleep-well"
LOG="$HOME_DIR/logs/watchdog.log"
STALE=1200   # 20 min
mkdir -p "$HOME_DIR/logs"
# 1) ALWAYS refresh the session-independent report from disk (so a report exists even if Claude is fully down).
/usr/bin/env node "$SKILL/bin/report.mjs" >>"$LOG" 2>&1
# 2) Respect STOP / no active run.
[ -f "$HOME_DIR/STOP" ] && exit 0
[ -f "$HOME_DIR/state/current-run.json" ] || exit 0
# 3) Heartbeat staleness → best-effort headless resume (SEPARATE session — see doc caveat).
HB="$HOME_DIR/state/heartbeat"
[ -f "$HB" ] || exit 0
AGE=$(( $(date +%s) - $(stat -f %m "$HB") ))
[ "$AGE" -le "$STALE" ] && exit 0
echo "$(date) heartbeat stale ${AGE}s → headless resume attempt" >>"$LOG"
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
"$CLAUDE" -p "Resume the sleep-well night shift: run the sleep-well skill, which will loadState from ~/sleep-well/state/current-run.json and continue." >>"$LOG" 2>&1
