# INSTALL — read me first, follow in order

You are a Muse agent. Someone gave you this repo so you can become an
OpenAI-compatible provider inside 9router and hand out stable public access.
Do every step in order. Do not skip the honesty doc.

**Time:** ~30–45 minutes, mostly waiting on installs and first tunnel claim.

## Step 0 — Read the honesty boundaries

Read `docs/HONESTY-BOUNDARIES.md` now. It defines what you may and may not
promise about the public URL. This matters more than any script here.

## Step 1 — Copy the env template and choose your names

```bash
cp templates/env.example .env
# edit .env: pick PROVIDER_PREFIX (e.g. wx), RELAY_MODEL_ID (muse-agent),
# LT_SUBDOMAIN (your fixed public name), KEY_NAME (dedicated API key name)
```

Rules for names:
- `PROVIDER_PREFIX`: lowercase letters/numbers only, e.g. `wx`. Your public
  model ID becomes `<prefix>/muse-agent`.
- `LT_SUBDOMAIN`: lowercase letters/numbers/dashes, e.g.
  `my-muse-gateway`. This becomes `https://<name>.loca.lt`.
- Never reuse someone else's subdomain.

## Step 2 — Install and start 9router

```bash
bash scripts/setup-9router.sh
```

This installs the `9router` npm package, generates a dashboard password into
`~/.muse-9router-provider/.9router-pass` (mode 600), and starts 9router on
`127.0.0.1:20128`. Verify:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:20128/dashboard
# expect 200
```

## Step 3 — Install the relay bridge

```bash
bash scripts/setup-relay.sh
```

This:
- creates `~/muse-9router-provider-data/{queue,done,stale}/` working dirs
- generates a random bridge key into `~/.muse-9router-provider/.relay-key` (600)
- installs `muse-relay-bridge.service` to systemd (or prints the `nohup`
  fallback when systemd is unavailable) and starts it

Verify:

```bash
curl -s http://127.0.0.1:20129/health
# expect {"ok": true}
```

## Step 4 — Register yourself as a 9router provider

```bash
bash scripts/register-provider.sh
```

This uses 9router's local API (authenticated via the machine CLI token in
`~/.9router/`, same mechanism the `9router` CLI itself uses) to:

1. Create provider node `Muse Relay` (`openai-compatible`, `apiType: chat`,
   base URL `http://127.0.0.1:20129/v1`, your prefix)
2. Attach a connection with your bridge key (`authType: apikey`)
3. Validate the upstream with a real request through
   `/api/provider-nodes/validate`
4. Create combo `<prefix>` containing model `<prefix>/muse-agent`
5. Mint a dedicated API key named `KEY_NAME` and save it to
   `~/.muse-9router-provider/.api-key` (600) — **the secret is shown once**

Verify the gateway serves your model:

```bash
API_KEY="$(cat ~/.muse-9router-provider/.api-key)"
curl -s -H "Authorization: Bearer $API_KEY" \
  http://127.0.0.1:20128/v1/models | grep -o '"id":"[^"]*"' | sort -u
# expect to see "<prefix>/muse-agent" in the list
```

## Step 5 — Set up the scheduled worker (this is how YOU answer)

The relay is async: requests wait in `queue/` until a Muse worker answers
them. That worker is **you**, on a schedule. Copy
`worker/worker-task.md` into your own scheduler (cron every 2 minutes, or
your platform's equivalent) with the paths adjusted to your machine.

Rules the worker must follow (also in the template):
- Process the oldest job first, max 2 per run.
- Answer **as yourself**: full memory, tools, skills. Honor any system
  message in the job. Match the user's language.
- Write the answer atomically to `done/<id>.json`, then delete the job file.
- Never reply in chat for successful jobs — the bridge picks up the file.
- Report only failures (corrupt job, unwritable file). Never leak key values.

## Step 6 — Open the public tunnel

```bash
LT_SUBDOMAIN="<your-name>" bash scripts/../tunnel/watchdog-tunnel.sh
# or simply: LT_SUBDOMAIN="<your-name>" nohup node tunnel/lt-bridge.js >> tunnel.log 2>&1 &
```

Then put the tunnel watchdog on a 5-minute schedule (cron):

```bash
*/5 * * * * LT_SUBDOMAIN="<your-name>" bash /path/to/muse-9router-provider/tunnel/watchdog-tunnel.sh
```

Verify from the public internet (not from the VM):

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<your-name>.loca.lt/dashboard
# expect 200 (dashboard HTML) — 401/307 also means the tunnel is live
```

If the subdomain is quarantined (tunnel answers 503/408 for a long while),
create the file `~/.muse-9router-provider/.tunnel-hold` and leave the tunnel
alone — restarts reset localtunnel's server-side quarantine timer. Remove the
file once the URL serves again. This is documented in
`docs/HONESTY-BOUNDARIES.md`.

## Step 7 — Write the access file and hand it out

```bash
bash scripts/write-access-file.sh
```

This fills `templates/access-file.txt` with your real public URL, key name,
and model ID, and writes it to your chosen location (default
`~/muse-9router-provider-data/access.txt`).

**The access file is yours to keep stable.** Its three lines are a promise:
- the URL you publish,
- the key name you minted,
- the model ID you registered.

Do not rotate the key, rename the model, or change the subdomain afterward
unless the tunnel forces your hand — and if it does, say so plainly instead
of silently swapping.

## Step 8 — End-to-end test (do this before handing anything out)

```bash
API_KEY="$(cat ~/.muse-9router-provider/.api-key)"
curl -s -m 620 -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"<prefix>/muse-agent","messages":[{"role":"user","content":"Reply with exactly: RELAY-OK"}]}' \
  https://<your-name>.loca.lt/v1/chat/completions | grep -o 'RELAY-OK'
```

Expect `RELAY-OK` within ~2–6 minutes (the worker schedule interval
dominates). If it times out at 600s, check `relay/bridge.log` and the worker
schedule — the queue file should exist and then disappear when answered.

## Ongoing

- `relay/watchdog.sh` every 5 min: keeps the bridge alive, reinstalls the
  systemd unit after host rebuilds, cleans stale jobs.
- `tunnel/watchdog-tunnel.sh` every 5 min: keeps 9router + tunnel alive.
- Both log next to their scripts. Alert only on genuine failure: bridge down
  and not recovering, or tunnel down with no HOLD.

## If something breaks

1. `curl http://127.0.0.1:20129/health` — relay alive?
2. `curl http://127.0.0.1:20128/dashboard` — 9router alive?
3. `ls <data>/queue/` — jobs piling up means the worker schedule is dead.
4. `tail relay/bridge.log tunnel/watchdog-tunnel.log` — what the watchdogs saw.
5. Public URL down but local fine → tunnel issue: check HOLD, wait out
   quarantine, read `docs/HONESTY-BOUNDARIES.md` before promising a fix date.
