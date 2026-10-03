#!/usr/bin/env bash
# setup-9router.sh — install the 9router gateway and start it locally.
# Idempotent: safe to re-run.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$REPO/.env" ] && . "$REPO/.env"
PORT="${NINEROUTER_PORT:-20128}"
DATA_DIR="${DATA_DIR:-$HOME/muse-9router-provider-data}"
SECRET_DIR="${SECRET_DIR:-$HOME/.muse-9router-provider}"
PASS_FILE="$SECRET_DIR/.9router-pass"

mkdir -p "$SECRET_DIR" "$DATA_DIR"
chmod 700 "$SECRET_DIR"

# 1. Install the 9router CLI/server if missing.
if ! command -v 9router >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/9router" ]; then
  echo "Installing 9router (npm)..."
  npm install -g 9router
fi
export PATH="$HOME/.local/bin:$PATH"
command -v 9router >/dev/null 2>&1 || {
  echo "ERROR: 9router not found after install. Install Node.js 18+ and retry." >&2
  exit 1
}
echo "9router version: $(9router --version 2>/dev/null || echo unknown)"

# 2. Dashboard password (600). Without it a restart falls back to the default
#    password and remote dashboard login gets blocked.
if [ ! -f "$PASS_FILE" ]; then
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 >"$PASS_FILE"
  chmod 600 "$PASS_FILE"
  echo "Generated dashboard password -> $PASS_FILE (mode 600)"
else
  echo "Dashboard password already exists -> $PASS_FILE"
fi

# 3. Start 9router if the dashboard doesn't answer.
if curl -s --fail -m 8 -o /dev/null "http://127.0.0.1:${PORT}/dashboard" 2>/dev/null; then
  echo "9router already running on 127.0.0.1:${PORT}"
else
  echo "Starting 9router on 127.0.0.1:${PORT} ..."
  cd "$HOME" || exit 1
  INITIAL_PASSWORD="$(cat "$PASS_FILE")" \
    nohup 9router --tray -H 127.0.0.1 -p "$PORT" -n --skip-update \
      >>"$DATA_DIR/9router.log" 2>&1 &
  disown
  sleep 6
  if curl -s --fail -m 8 -o /dev/null "http://127.0.0.1:${PORT}/dashboard" 2>/dev/null; then
    echo "9router is up: http://127.0.0.1:${PORT}/dashboard"
  else
    echo "ERROR: 9router did not come up. See $DATA_DIR/9router.log" >&2
    exit 1
  fi
fi
