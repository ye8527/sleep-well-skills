#!/bin/sh
# sleep-well out-of-band watchdog — OFF by default. See docs/resilience-watchdog.md.
umask 077
HOME_DIR="${SLEEP_WELL_HOME:-$HOME/sleep-well}"
SKILL="${SLEEP_WELL_SKILL:-$HOME/.claude/skills/sleep-well}"
case "$HOME_DIR" in
  /*) : ;;
  *) echo "sleep-well watchdog: SLEEP_WELL_HOME must be an absolute path" >&2; exit 1 ;;
esac
ACCOUNT_HOME="$(cd "$HOME" 2>/dev/null && pwd -P)" || {
  echo "sleep-well watchdog: cannot resolve account HOME" >&2; exit 1; }
if [ -e "$HOME_DIR" ]; then
  [ -d "$HOME_DIR" ] || { echo "sleep-well watchdog: runtime root is not a directory" >&2; exit 1; }
  REAL_HOME_DIR="$(cd "$HOME_DIR" 2>/dev/null && pwd -P)" || {
    echo "sleep-well watchdog: cannot resolve runtime root" >&2; exit 1; }
else
  HOME_PARENT="${HOME_DIR%/*}"
  HOME_LEAF="${HOME_DIR##*/}"
  [ -n "$HOME_PARENT" ] || HOME_PARENT="/"
  [ -n "$HOME_LEAF" ] || { echo "sleep-well watchdog: invalid runtime root" >&2; exit 1; }
  REAL_PARENT="$(cd "$HOME_PARENT" 2>/dev/null && pwd -P)" || {
    echo "sleep-well watchdog: runtime parent does not exist" >&2; exit 1; }
  REAL_HOME_DIR="${REAL_PARENT%/}/$HOME_LEAF"
fi
[ "$REAL_HOME_DIR" != "/" ] && [ "$REAL_HOME_DIR" != "$ACCOUNT_HOME" ] || {
  echo "sleep-well watchdog: runtime root must be a dedicated directory" >&2; exit 1; }
HOME_DIR="$REAL_HOME_DIR"
[ ! -L "$HOME_DIR/logs" ] || { echo "sleep-well watchdog: logs path must not be a symlink" >&2; exit 1; }
mkdir -p "$HOME_DIR/logs" || exit 1
chmod 700 "$HOME_DIR" "$HOME_DIR/logs" || exit 1
LOG="$HOME_DIR/logs/watchdog.log"
[ ! -L "$LOG" ] || { echo "sleep-well watchdog: log file must not be a symlink" >&2; exit 1; }
: >>"$LOG" || exit 1
chmod 600 "$LOG" || exit 1

AI_TIMEOUT="${SLEEP_WELL_AI_TIMEOUT:-1800}"
# launchd does not reliably inherit interactive-shell PATH additions. Preserve the
# caller's selection and append common fallback locations, including installed nvm versions.
for _d in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin; do
  [ -d "$_d" ] && PATH="$PATH:$_d"
done
if [ -d "$HOME/.nvm/versions/node" ]; then
  for _nb in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$_nb" ] && PATH="$PATH:$_nb"; done
fi
export PATH

# 1) ALWAYS refresh the session-independent report from disk (so a report exists even if Claude is fully down).
NODE_CMD="${SLEEP_WELL_NODE:-node}"
if ! NODE_BIN="$(command -v "$NODE_CMD" 2>/dev/null)" || [ -z "$NODE_BIN" ]; then
  echo "$(date) node not found; report refresh unavailable (PATH=$PATH)" >>"$LOG"
  exit 1
fi
"$NODE_BIN" "$SKILL/bin/report.mjs" >>"$LOG" 2>&1
# 2) Respect STOP / no active run.
[ -f "$HOME_DIR/STOP" ] && exit 0
[ -f "$HOME_DIR/state/current-run.json" ] || exit 0
# A normal Codex review may use the entire AI timeout without refreshing the
# in-band heartbeat. Validate only after the unconditional report refresh and
# STOP/no-run checks: a bad resume threshold must not suppress the morning report.
case "$AI_TIMEOUT" in
  ''|*[!0-9]*)
    echo "$(date) invalid SLEEP_WELL_AI_TIMEOUT; report refreshed, headless resume disabled" >>"$LOG"
    exit 1 ;;
esac
# Canonicalize before arithmetic: shell arithmetic interprets a leading zero as
# octal even though the validation comparisons below are decimal.
while [ "${#AI_TIMEOUT}" -gt 1 ] && [ "${AI_TIMEOUT#0}" != "$AI_TIMEOUT" ]; do
  AI_TIMEOUT="${AI_TIMEOUT#0}"
done
if [ "${#AI_TIMEOUT}" -gt 5 ] || [ "$AI_TIMEOUT" -lt 1 ] || [ "$AI_TIMEOUT" -gt 86400 ]; then
  echo "$(date) invalid SLEEP_WELL_AI_TIMEOUT; report refreshed, headless resume disabled" >>"$LOG"
  exit 1
fi
STALE=$((AI_TIMEOUT + 900))
[ "$STALE" -lt 2700 ] && STALE=2700
# 3) Heartbeat staleness → best-effort headless resume (SEPARATE session — see doc caveat).
HB="$HOME_DIR/state/heartbeat"
[ -f "$HB" ] || exit 0
HB_MTIME="$(stat -f %m "$HB" 2>/dev/null)" || {
  echo "$(date) heartbeat mtime unavailable; headless resume skipped" >>"$LOG"
  exit 0
}
case "$HB_MTIME" in
  ''|*[!0-9]*)
    echo "$(date) heartbeat mtime invalid; headless resume skipped" >>"$LOG"
    exit 0 ;;
esac
AGE=$(( $(date +%s) - HB_MTIME ))
[ "$AGE" -le "$STALE" ] && exit 0
echo "$(date) heartbeat stale ${AGE}s → headless resume attempt" >>"$LOG"
CLAUDE_CMD="${SLEEP_WELL_CLAUDE:-claude}"
if ! CLAUDE_BIN="$(command -v "$CLAUDE_CMD" 2>/dev/null)" || [ -z "$CLAUDE_BIN" ]; then
  echo "$(date) claude not found; report refreshed but headless resume skipped (PATH=$PATH)" >>"$LOG"
  exit 0
fi
"$CLAUDE_BIN" -p "Resume the sleep-well night shift: run the sleep-well skill, which will loadState from ~/sleep-well/state/current-run.json and continue." >>"$LOG" 2>&1
