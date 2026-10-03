#!/usr/bin/env bash
# setup-relay.sh — install the muse-relay bridge (the thing that makes YOU a
# provider). Idempotent: safe to re-run.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$REPO/.env" ] && . "$REPO/.env"
DATA_DIR="${DATA_DIR:-$HOME/muse-9router-provider-data}"
SECRET_DIR="${SECRET_DIR:-$HOME/.muse-9router-provider}"
KEY_FILE="$SECRET_DIR/.relay-key"
PORT="${RELAY_PORT:-20129}"
MODEL_ID="${RELAY_MODEL_ID:-muse-agent}"
SERVICE="muse-relay-bridge.service"

mkdir -p "$DATA_DIR"/{queue,done,stale} "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

# 1. Bridge key (600). Never printed, never committed.
if [ ! -f "$KEY_FILE" ]; then
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 >"$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "Generated bridge key -> $KEY_FILE (mode 600)"
else
  echo "Bridge key already exists -> $KEY_FILE"
fi

# 2. Render the systemd unit from the template.
UNIT_SRC="$DATA_DIR/$SERVICE"
sed -e "s|__HOME__|${HOME}|g" \
    -e "s|__DATA_DIR__|${DATA_DIR}|g" \
    -e "s|__KEY_FILE__|${KEY_FILE}|g" \
    -e "s|__PORT__|${PORT}|g" \
    -e "s|__MODEL_ID__|${MODEL_ID}|g" \
    -e "s|__REPO__|${REPO}|g" \
    "$REPO/relay/muse-relay-bridge.service.template" >"$UNIT_SRC"
echo "Rendered unit -> $UNIT_SRC"

# 3. Install + start (systemd preferred; nohup fallback otherwise).
if [ -d /run/systemd/system ]; then
  cp "$UNIT_SRC" "/etc/systemd/system/$SERVICE"
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
  systemctl restart "$SERVICE"
  sleep 3
  if systemctl is-active --quiet "$SERVICE"; then
    echo "Service active: $SERVICE"
  else
    echo "ERROR: service failed to start. Check $DATA_DIR/bridge.log" >&2
    exit 1
  fi
else
  echo "No systemd — using nohup fallback (watchdog keeps it alive)."
  if ! pgrep -f "muse-9router-provider/relay/bridge.py" >/dev/null 2>&1; then
    cd "$HOME" || exit 1
    MUSE_RELAY_DATA_DIR="$DATA_DIR" MUSE_RELAY_KEY_FILE="$KEY_FILE" \
      MUSE_RELAY_PORT="$PORT" MUSE_RELAY_MODEL_ID="$MODEL_ID" \
      nohup python3 "$REPO/relay/bridge.py" >>"$DATA_DIR/bridge.log" 2>&1 &
    disown
    sleep 3
  fi
fi

# 4. Health check.
export MUSE_RELAY_KEY_FILE="$KEY_FILE"
if [ "$(curl -s -m 8 -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $(cat "$KEY_FILE")" \
      "http://127.0.0.1:${PORT}/health")" = "200" ]; then
  echo "Relay healthy: http://127.0.0.1:${PORT}/health (model: $MODEL_ID)"
else
  echo "ERROR: relay health check failed. Check $DATA_DIR/bridge.log" >&2
  exit 1
fi

echo "OK. Next: bash $REPO/scripts/register-provider.sh"
