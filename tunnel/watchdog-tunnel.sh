#!/usr/bin/env bash
# watchdog-tunnel.sh — keep 9router + the localtunnel bridge alive.
# Run every 5 minutes via cron/scheduler:
#   */5 * * * * LT_SUBDOMAIN="<name>" bash /path/to/muse-9router-provider/tunnel/watchdog-tunnel.sh
#
# Env (all optional, defaults shown):
#   LT_SUBDOMAIN        fixed public name (required for stable access)
#   LT_LOCAL_PORT       20128
#   NINEROUTER_PORT     20128
#   DATA_DIR            ~/muse-9router-provider-data
#   SECRET_DIR          ~/.muse-9router-provider
#   REPO_DIR            auto-detected (parent of this script)
#
# HOLD mode: if $SECRET_DIR/.tunnel-hold exists, the bridge is never
# restarted. Use it when a subdomain reclaim is waiting out localtunnel's
# server-side quarantine — restarts reset the quarantine timer.
set -u
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$REPO_DIR/.env" ] && . "$REPO_DIR/.env"
export PATH="$HOME/.local/bin:$PATH"
PORT="${NINEROUTER_PORT:-20128}"
SUBDOMAIN="${LT_SUBDOMAIN:-}"
DATA_DIR="${DATA_DIR:-$HOME/muse-9router-provider-data}"
SECRET_DIR="${SECRET_DIR:-$HOME/.muse-9router-provider}"
LOG="$DATA_DIR/watchdog-tunnel.log"
HOLD_FILE="$SECRET_DIR/.tunnel-hold"
mkdir -p "$DATA_DIR"

ts() { date -u '+%F %H:%M:%S'; }

# 1. 9router API must answer locally.
if ! curl -s --fail -m 8 -o /dev/null "http://127.0.0.1:${PORT}/dashboard" 2>/dev/null; then
  if [ -f "$SECRET_DIR/.9router-pass" ]; then
    cd "$HOME" || exit 1
    INITIAL_PASSWORD="$(cat "$SECRET_DIR/.9router-pass")" \
      nohup 9router --tray -H 127.0.0.1 -p "$PORT" -n --skip-update \
        >>"$DATA_DIR/9router.log" 2>&1 &
    disown
    echo "[$(ts)] restarted 9router" >>"$LOG"
  else
    echo "[$(ts)] 9router down but no dashboard password file; run setup-9router.sh" >>"$LOG"
  fi
fi

# 2. The public URL must actually serve the dashboard.
if [ -n "$SUBDOMAIN" ]; then
  URL="https://${SUBDOMAIN}.loca.lt"
else
  URL="$(grep -o 'https://[a-zA-Z0-9-]*\.loca\.lt' "$DATA_DIR/lt-bridge.log" 2>/dev/null | tail -1)"
fi
if [ -z "$URL" ] || ! curl -s --fail -m 20 -o /dev/null "$URL/dashboard" 2>/dev/null; then
  if [ -f "$HOLD_FILE" ]; then
    echo "[$(ts)] tunnel down but HOLD active - no restart" >>"$LOG"
  else
    # Grace period: a freshly started bridge can 5xx for a few minutes while
    # localtunnel.me wires up the URL — don't churn it with rapid restarts.
    BRIDGE_PID="$(pgrep -f 'muse-9router-provider/tunnel/lt-bridge[.]js' | head -1)"
    BRIDGE_AGE=""
    [ -n "$BRIDGE_PID" ] && BRIDGE_AGE="$(ps -o etimes= -p "$BRIDGE_PID" 2>/dev/null | tr -d ' ')"
    if [ -n "$BRIDGE_AGE" ] && [ "$BRIDGE_AGE" -lt 600 ]; then
      echo "[$(ts)] tunnel check failed but bridge only ${BRIDGE_AGE}s old - grace, no restart" >>"$LOG"
    else
      [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null
      sleep 2
      cd "$HOME" || exit 1
      LT_SUBDOMAIN="$SUBDOMAIN" nohup node "$REPO_DIR/tunnel/lt-bridge.js" \
        >>"$DATA_DIR/lt-bridge.log" 2>&1 &
      disown
      echo "[$(ts)] restarted lt-bridge (fixed URL https://${SUBDOMAIN}.loca.lt)" >>"$LOG"
    fi
  fi
fi
