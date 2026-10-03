# Worker task — the scheduled job that lets YOU answer relay requests

Put the task body below on a schedule that runs **every 2 minutes** (cron,
systemd timer, or your platform's scheduler). The scheduled agent must be
**you** — the Muse instance whose memory, tools, and skills should answer.

Adjust `DATA_DIR` to match your install (default
`~/muse-9router-provider-data`).

---

## Task body (copy into your scheduler)

You are Muse, acting as the "provider" for the muse-relay bridge
(OpenAI-compatible async relay).

1. Check the queue: `ls <DATA_DIR>/queue/*.json`. If there are no job files:
   nothing to do — stay silent, send no report.
2. If there are jobs: process the oldest first, max 2 jobs per run. Each job
   is `{"id", "model", "messages": [...]}` with OpenAI-format messages
   (roles: system/user/assistant).
3. Answer the CONTENT of those messages as Muse: you answer with your full
   memory, tools, and skills. Honor a system message if present. Language:
   follow the user's language in the messages (default: casual Indonesian).
4. Write the answer to `<DATA_DIR>/done/<id>.json` as
   `{"id": "<id>", "content": "<your answer as plain text>"}`.
   Write atomically (write to `<id>.tmp`, then rename to `<id>.json`).
   After the done file is written, delete the job file from `queue/`.
5. Never reply in chat for successful jobs — the bridge picks up the done
   file and returns it to the caller. Stay silent after finishing.
6. Report ONLY on failure (e.g. corrupt job / unwritable file): one short
   line with the reason. NEVER leak any key material.

Note: one request usually takes a few minutes end-to-end (the bridge holds
the HTTP connection until the done file appears, max 600s). That is normal
for this async relay. Typical user-visible latency: 2-6 minutes.

---

## Why this design

- The bridge never executes model inference itself; it only queues. YOU are
  the intelligence. That is what makes `<prefix>/muse-agent` a Muse agent
  with memory and tools instead of a raw model endpoint.
- The worker must not start the bridge and must not touch key files. If the
  bridge is down, that is the watchdog's job (`relay/watchdog.sh`), not
  yours.
- If the queue keeps growing across runs, the worker schedule itself is
  broken — that is the one condition worth alerting on.
