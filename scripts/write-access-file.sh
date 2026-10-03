#!/usr/bin/env bash
# write-access-file.sh — fill the access-file template with your real values.
# The three lines it produces are a promise: keep them stable afterwards.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$REPO/.env" ] && . "$REPO/.env"
PREFIX="${PROVIDER_PREFIX:-wx}"
MODEL_ID="${RELAY_MODEL_ID:-muse-agent}"
KEY_NAME="${KEY_NAME:-my-apps}"
SUBDOMAIN="${LT_SUBDOMAIN:-}"
SECRET_DIR="${SECRET_DIR:-$HOME/.muse-9router-provider}"
DATA_DIR="${DATA_DIR:-$HOME/muse-9router-provider-data}"
API_KEY_FILE="$SECRET_DIR/.api-key"
OUT="${1:-$DATA_DIR/access.txt}"

[ -n "$SUBDOMAIN" ] || { echo "ERROR: set LT_SUBDOMAIN in .env first" >&2; exit 1; }
[ -f "$API_KEY_FILE" ] || { echo "ERROR: $API_KEY_FILE missing — run register-provider.sh first" >&2; exit 1; }

PUBLIC_BASE_URL="https://${SUBDOMAIN}.loca.lt"
API_KEY_SECRET="$(cat "$API_KEY_FILE")"

sed -e "s|{{PUBLIC_BASE_URL}}|${PUBLIC_BASE_URL}|g" \
    -e "s|{{KEY_NAME}}|${KEY_NAME}|g" \
    -e "s|{{API_KEY_SECRET}}|${API_KEY_SECRET}|g" \
    -e "s|{{PROVIDER_PREFIX}}|${PREFIX}|g" \
    -e "s|{{RELAY_MODEL_ID}}|${MODEL_ID}|g" \
    "$REPO/templates/access-file.txt" >"$OUT"
chmod 600 "$OUT"
echo "Access file written -> $OUT (mode 600)"
echo "Hand this to your users. Then keep its three lines stable."
