#!/usr/bin/env bash
# muse-relay watchdog: ensures the bridge systemd service is installed and
# running, plus janitor duty. Run every 5 min via cron/scheduler.
#
# IMPORTANT: this script must NEVER start bridge.py directly. The bridge is
# owned by the muse-relay-bridge.service systemd unit (managed by pid 1).
# A bridge started from a scheduler worker gets killed when the worker's run
# times out, causing a restart death-spiral. systemd is immune.
#
# Env overrides (all optional):
#   MUSE_RELAY_DATA_DIR  default ~/muse-9router-provider-data
#   MUSE_RELAY_KEY_FILE  default ~/.muse-9router-provider/.relay-key
#   MUSE_RELAY_PORT      default 20129
set -u
BASE="${MUSE_RELAY_DATA_DIR:-$HOME/muse-9router-provider-data}"
LOG="$BASE/watchdog.log"
KEY_FILE="${MUSE_RELAY_KEY_FILE:-$HOME/.muse-9router-provider/.relay-key}"
PORT="${MUSE_RELAY_PORT:-20129}"
SERVICE="muse-relay-bridge.service"
# Installed copy of the unit template lives next to this script's repo;
# setup-relay.sh renders it to $SERVICE_SRC on install.
SERVICE_SRC="${MUSE_RELAY_SERVICE_SRC:-$HOME/muse-9router-provider/relay/muse-relay-bridge.service}"

up() {
  [ -f "$KEY_FILE" ] || return 1
  KEY=$(cat "$KEY_FILE")
  local code
  code=$(curl -s -m 8 -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $KEY" "http://127.0.0.1:${PORT}/health" 2>/dev/null)
  local rc=$?
  if [ "$code" = "200" ]; then return 0; fi
  echo "$(date '+%F %T') up() failed: curl_rc=$rc http_code='$code'" >>"$LOG"
  return 1
}

have_systemd() { [ -d /run/systemd/system ]; }

# Bootstrap: (re)install the systemd unit after a host rebuild wiped /etc.
if have_systemd && [ ! -f "/etc/systemd/system/$SERVICE" ]; then
  if [ -f "$SERVICE_SRC" ]; then
    cp "$SERVICE_SRC" "/etc/systemd/system/$SERVICE" 2>/dev/null
    timeout 30 systemctl daemon-reload 2>/dev/null
    timeout 30 systemctl enable "$SERVICE" 2>/dev/null
    echo "$(date '+%F %T') reinstalled $SERVICE after host rebuild" >>"$LOG"
  else
    echo "$(date '+%F %T') ERROR: $SERVICE_SRC missing, cannot bootstrap" >>"$LOG"
  fi
fi

# Make sure the service is active (systemd handles restarts itself).
if have_systemd; then
  if ! timeout 30 systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    timeout 30 systemctl start "$SERVICE" 2>/dev/null
    echo "$(date '+%F %T') started $SERVICE (was inactive)" >>"$LOG"
    sleep 4
  fi
else
  # No systemd: keep a nohup'd bridge alive as a fallback.
  if ! pgrep -f "muse-9router-provider/relay/bridge.py" >/dev/null 2>&1; then
    # shellcheck disable=SC2164
    cd "$HOME"
    nohup python3 "$HOME/muse-9router-provider/relay/bridge.py" >>"$BASE/bridge.log" 2>&1 &
    disown
    echo "$(date '+%F %T') started bridge via nohup fallback (no systemd)" >>"$LOG"
    sleep 4
  fi
fi

if ! up; then
  sleep 10
  if up; then
    echo "$(date '+%F %T') health probe flaked once, bridge OK on retry" >>"$LOG"
  else
    state="n/a"
    have_systemd && state="$(timeout 30 systemctl is-active "$SERVICE" 2>/dev/null)"
    echo "$(date '+%F %T') bridge DOWN (service state: $state)" >>"$LOG"
  fi
fi

# Janitor: drop done files older than 30 min (orphaned answers nobody picked
# up) and move queue jobs older than 30 min to stale/ (worker never got them).
find "$BASE/done" -name "*.json" -mmin +30 -delete 2>/dev/null
for f in "$BASE"/queue/*.json; do
  [ -e "$f" ] || continue
  if [ "$(($(date +%s) - $(stat -c %Y "$f")))" -gt 1800 ]; then
    mv "$f" "$BASE/stale/" 2>/dev/null
    echo "$(date '+%F %T') moved stale job $(basename "$f")" >>"$LOG"
  fi
done
