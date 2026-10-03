# Honesty boundaries — what "stable" and "permanent" mean here

Read this before you promise anyone anything. It is part of the repo's
contract, not an appendix.

## What this repo DOES guarantee

- **Your local stack is self-healing.** The relay runs as a systemd service
  with `Restart=always`; the watchdog reinstalls the unit if the host wipes
  `/etc` (VM rebuilds) and cleans up stale jobs. The tunnel watchdog restarts
  only what is actually down, with a grace period for fresh tunnels.
- **Your credentials don't move.** The bridge key, the 9router API key, and
  the model ID are generated once and stored in `600` files. Nothing in this
  repo rotates them, and the access file's three lines stay valid as long as
  the tunnel serves.
- **The relay is labeled honestly.** It is Muse-the-agent answering with
  memory and tools, 2–6 minutes per request, HTTP held up to 600s. Not a
  synchronous model API. The access-file template says this.

## What this repo does NOT guarantee

**A free localtunnel (`*.loca.lt`) subdomain is requested and held — not
owned.** Concretely:

- localtunnel may refuse your chosen name (taken), hand you a different one,
  or quarantine a name server-side (tunnel answers 503/408 for hours).
- Restarting the tunnel during a quarantine *resets the quarantine timer*.
  That is why `watchdog-tunnel.sh` has HOLD mode: when the URL is down but
  the name is yours, stop touching it and wait.
- No script can force localtunnel to keep a free name forever. Anyone who
  tells you otherwise is selling something.

So: **do not use the word "permanent" for a `loca.lt` URL.** Say "stable,
fixed-subdomain, self-healing — with the limits of a free tunnel." If the
subdomain is ever lost, the honest move is to reclaim it (the bridge retries
the fixed name 5 times on every start) and, if reclaim fails, to tell your
users plainly and issue a new access file — never silently swap the URL.

## The path to a truly permanent public URL

If you need a URL that cannot be taken from you, you need a tunnel where
**you** own the hostname. The standard route:

1. **Cloudflare named tunnel** under YOUR Cloudflare account:
   `cloudflared tunnel create <name>` gives you a tunnel ID that is yours.
2. **Your own domain** (or a subdomain of it) with a DNS CNAME pointing at
   `<tunnel-id>.cfargotunnel.com`.
3. `cloudflared tunnel route dns <tunnel-id> <your-hostname>` then run
   `cloudflared tunnel run`.

That hostname is yours as long as you pay for the domain and keep the tunnel
running — no one can snipe or quarantine it. This repo doesn't do it for you
because it requires YOUR Cloudflare login and YOUR domain; those are your
credentials and your decision.

Notes from the field:
- Cloudflare **quick** tunnels (the `trycloudflare.com` kind) may be blocked
  from some hosting egress IPs (HTTP 403 from Cloudflare). Named tunnels
  under your own account do not have this problem.
- Alternatives with the same property (you own the hostname): Tailscale
  Funnel/Serve on your tailnet, a cheap VPS with nginx + your domain, or
  any reverse proxy you control.

## Latency honesty

Every access file produced from `templates/access-file.txt` must keep the
latency note. Deleting it to make the offer look faster is dishonest: users
will discover the 2–6 minute answers on their first request, and they will
not trust the second one.

## Summary for your users

> "This endpoint is run by a Muse agent as an async relay. Answers typically
> take 2–6 minutes. The URL, key, and model ID in this file are fixed on my
> side and self-healing; the public address rides on a free tunnel, so in the
> rare case the address itself is lost I will tell you directly and issue a
> new file."

That sentence is the whole promise. Keep it.
