#!/usr/bin/env bash
# register-provider.sh — register this Muse as a 9router provider.
#
# Creates, idempotently:
#   1. provider node  "Muse Relay"  (openai-compatible, chat, -> relay bridge)
#   2. connection     "muse-relay"  (authType apikey, carries the bridge key)
#   3. validation     real request through /api/provider-nodes/validate
#   4. combo          "<prefix>"     (models: ["<prefix>/muse-agent"])
#   5. API key        "<KEY_NAME>"   (secret saved once to a 600 file)
#
# Auth: x-9r-cli-token, derived exactly like the 9router CLI does from
# ~/.9router/machine-id + ~/.9router/auth/cli-secret.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$REPO/.env" ] && . "$REPO/.env"
PREFIX="${PROVIDER_PREFIX:-wx}"
MODEL_ID="${RELAY_MODEL_ID:-muse-agent}"
FULL_MODEL="${PREFIX}/${MODEL_ID}"
KEY_NAME="${KEY_NAME:-my-apps}"
RELAY_PORT="${RELAY_PORT:-20129}"
NINE_PORT="${NINEROUTER_PORT:-20128}"
DATA_DIR="${DATA_DIR:-$HOME/muse-9router-provider-data}"
SECRET_DIR="${SECRET_DIR:-$HOME/.muse-9router-provider}"
BRIDGE_KEY_FILE="$SECRET_DIR/.relay-key"
API_KEY_FILE="$SECRET_DIR/.api-key"
BASE="http://127.0.0.1:${NINE_PORT}"
RELAY_BASE="http://127.0.0.1:${RELAY_PORT}/v1"

die() { echo "ERROR: $*" >&2; exit 1; }
[ -f "$BRIDGE_KEY_FILE" ] || die "bridge key missing — run scripts/setup-relay.sh first"
curl -s --fail -m 8 -o /dev/null "$BASE/dashboard" 2>/dev/null \
  || die "9router not answering on $BASE — run scripts/setup-9router.sh first"

# CLI token (same derivation as 9router's own CLI client).
NR_DIR="$HOME/.9router"
[ -f "$NR_DIR/machine-id" ] && [ -f "$NR_DIR/auth/cli-secret" ] \
  || die "~/.9router/machine-id or auth/cli-secret missing — is 9router running?"
RAW="$(cat "$NR_DIR/machine-id")"
SEC="$(cat "$NR_DIR/auth/cli-secret")"
TOK="$(printf '%s' "${RAW}9r-cli-auth${SEC}" | sha256sum | cut -c1-16)"

api() { # api METHOD PATH [JSON-BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -m 20 -X "$method" -H "x-9r-cli-token: $TOK" \
      -H "Content-Type: application/json" -d "$body" "$BASE$path"
  else
    curl -s -m 20 -X "$method" -H "x-9r-cli-token: $TOK" "$BASE$path"
  fi
}
jget() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)" 2>/dev/null; }

echo "== 1. provider node =="
NODE_ID="$(api GET /api/provider-nodes | python3 -c "
import json,sys
for n in json.load(sys.stdin).get('nodes',[]):
    if n.get('prefix')=='$PREFIX':
        print(n['id']); break
" 2>/dev/null)"
if [ -n "$NODE_ID" ]; then
  echo "Node with prefix '$PREFIX' already exists: $NODE_ID"
else
  RESP="$(api POST /api/provider-nodes "$(python3 -c "
import json; print(json.dumps({'name':'Muse Relay','prefix':'$PREFIX','apiType':'chat','baseUrl':'$RELAY_BASE','type':'openai-compatible'}))")")"
  NODE_ID="$(echo "$RESP" | jget "['node']['id']")"
  [ -n "$NODE_ID" ] || die "node creation failed: $RESP"
  echo "Created node: $NODE_ID"
fi

echo "== 2. connection (bridge key) =="
BRIDGE_KEY="$(cat "$BRIDGE_KEY_FILE")"
CONN_EXISTS="$(api GET /api/providers | python3 -c "
import json,sys
for c in json.load(sys.stdin).get('connections',[]):
    if c.get('provider')=='$NODE_ID':
        print(c['id']); break
" 2>/dev/null)"
if [ -n "$CONN_EXISTS" ]; then
  echo "Connection already exists for node: $CONN_EXISTS"
else
  RESP="$(api POST /api/providers "$(python3 -c "
import json; print(json.dumps({'provider':'$NODE_ID','apiKey':open('$BRIDGE_KEY_FILE').read().strip(),'name':'muse-relay','testStatus':'active'}))")")"
  echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'error' not in d, d; print('Created connection:', d.get('connection',{}).get('id') or d.get('id'))" \
    || die "connection creation failed: $RESP"
fi

echo "== 3. validate upstream =="
VALID="$(api POST /api/provider-nodes/validate "$(python3 -c "
import json; print(json.dumps({'baseUrl':'$RELAY_BASE','apiKey':open('$BRIDGE_KEY_FILE').read().strip(),'type':'openai-compatible','modelId':'$MODEL_ID'}))")")"
echo "$VALID" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('valid'), d; print('Upstream valid:', True)" \
  || die "upstream validation failed: $VALID"

echo "== 4. combo =="
COMBO_EXISTS="$(api GET /api/combos | python3 -c "
import json,sys
for c in json.load(sys.stdin).get('combos',[]):
    if c.get('name')=='$PREFIX':
        print(c['id']); break
" 2>/dev/null)"
if [ -n "$COMBO_EXISTS" ]; then
  echo "Combo '$PREFIX' already exists: $COMBO_EXISTS"
else
  RESP="$(api POST /api/combos "$(python3 -c "
import json; print(json.dumps({'name':'$PREFIX','models':['$FULL_MODEL']}))")")"
  echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'error' not in d, d; print('Created combo:', (d.get('combo') or {}).get('id'))" \
    || die "combo creation failed: $RESP"
fi

echo "== 5. dedicated API key =="
if [ -f "$API_KEY_FILE" ]; then
  echo "API key file already exists -> $API_KEY_FILE (reusing, not rotating)"
else
  KEY_EXISTS="$(api GET /api/keys | python3 -c "
import json,sys
d=json.load(sys.stdin); ks=d.get('keys',d if isinstance(d,list) else [])
for k in (ks if isinstance(ks,list) else []):
    if k.get('name')=='$KEY_NAME':
        print(k['id']); break
" 2>/dev/null)"
  if [ -n "$KEY_EXISTS" ]; then
    die "a key named '$KEY_NAME' already exists in 9router ($KEY_EXISTS) but its secret is not saved here. Delete it in the dashboard (or pick another KEY_NAME) and re-run."
  fi
  RESP="$(api POST /api/keys "$(python3 -c "import json; print(json.dumps({'name':'$KEY_NAME'}))")")"
  SECRET="$(echo "$RESP" | jget "['key']")"
  [ -n "$SECRET" ] || die "key minting failed: $RESP"
  printf '%s' "$SECRET" >"$API_KEY_FILE"
  chmod 600 "$API_KEY_FILE"
  echo "Minted key '$KEY_NAME' -> $API_KEY_FILE (mode 600). Secret shown ONCE below — save it in your password manager:"
  echo "  $SECRET"
fi

echo "== 6. verify gateway serves the model =="
MODELS="$(curl -s -m 15 -H "Authorization: Bearer $(cat "$API_KEY_FILE")" "$BASE/v1/models")"
echo "$MODELS" | python3 -c "
import json,sys
ids=[m['id'] for m in json.load(sys.stdin).get('data',[])]
assert '$FULL_MODEL' in ids, 'model $FULL_MODEL not in gateway: '+str(ids)
print('Gateway serves: $FULL_MODEL')
" || die "model not exposed via gateway"

echo
echo "OK. Public model id: $FULL_MODEL"
echo "Next: set up the tunnel (INSTALL.md step 6), then: bash $REPO/scripts/write-access-file.sh"
