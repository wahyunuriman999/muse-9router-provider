# muse-9router-provider

**Turn a Muse agent into an OpenAI-compatible provider inside 9router, and hand out stable public API access.**

If you are a Muse instance and someone gave you this repo, start at
[INSTALL.md](INSTALL.md) and follow it top to bottom. Everything you need is
in this repo — no guessing, no missing steps.

## What this builds

```
 Internet
    |
    |  public tunnel (localtunnel, fixed subdomain)
    v
 9router  (OpenAI-compatible gateway, :20128)
    |  node "Muse Relay" -> http://127.0.0.1:20129/v1
    v
 muse-relay bridge  (OpenAI-compatible async relay, :20129)
    |  queue/  ->  scheduled Muse worker answers with full
    v             memory, tools, and skills (2-6 min per request)
 done/<job>.json
```

End users get one access file with three lines that never change on your side:

- **Base URL** — your public tunnel URL + `/v1`
- **API key** — a dedicated 9router key you mint once
- **Model ID** — `<prefix>/muse-agent` (e.g. `wx/muse-agent`)

## Repo layout

| Path | What it is |
|---|---|
| `INSTALL.md` | Step-by-step the receiving Muse must follow, in order |
| `docs/HONESTY-BOUNDARIES.md` | **Read this.** What "stable/permanent" honestly means here, and the upgrade path to a truly permanent URL |
| `scripts/setup-9router.sh` | Install + start 9router locally |
| `scripts/setup-relay.sh` | Generate bridge key, install systemd service, start relay |
| `scripts/register-provider.sh` | Register node + connection + combo + API key in 9router via its local API |
| `relay/bridge.py` | The OpenAI-compatible async relay server |
| `relay/watchdog.sh` | Keeps the relay alive across restarts (systemd bootstrap) |
| `relay/muse-relay-bridge.service.template` | systemd unit template |
| `tunnel/lt-bridge.js` | localtunnel bridge (custom client: proxy-optional, fixed-subdomain retries) |
| `tunnel/watchdog-tunnel.sh` | Keeps 9router + tunnel alive; HOLD mode for quarantine waits |
| `worker/worker-task.md` | The scheduled-worker instructions that let Muse answer queued jobs |
| `templates/access-file.txt` | Template of the 3-line access file you hand to users |
| `templates/env.example` | All knobs in one place |

## Design rules (why this repo is trustworthy)

1. **No secrets in the repo.** Keys are generated at install time and stored in
   `600` files outside the repo. Nothing here will ever leak your keys.
2. **Self-healing, not self-praising.** systemd owns the relay (a process
   started from a scheduler gets killed when the scheduler's run times out —
   this repo never does that). Watchdogs only restart what is actually down,
   with grace periods and HOLD mode so they don't churn a recovering tunnel.
3. **Honest about limits.** A free localtunnel subdomain is *requested and
   held*, not *owned*. See `docs/HONESTY-BOUNDARIES.md` before you promise
   anyone the word "permanent".
4. **Async relay, honestly labeled.** This is Muse-the-agent answering with
   memory and tools — typical latency 2–6 minutes per request, HTTP held open
   up to 600s. It is not a synchronous raw-model API, and the access file
   says so.

## Requirements

- Linux VM/host you control (systemd preferred; without it, use the
  `nohup` fallback documented in INSTALL.md)
- Node.js 18+ and Python 3.10+
- `9router` npm package (installed by `scripts/setup-9router.sh`)
- For the public URL: outbound HTTPS (the tunnel registers via
  `https://localtunnel.me`)

## License

MIT — do what you want, keep the honesty docs intact.
