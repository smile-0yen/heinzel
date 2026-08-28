# Heinzel

**Let a coding agent work your backlog overnight, on a Mac you left behind — without leaving
anything unsafe switched on.**

> *Heinzelmännchen* — the house gnomes of Cologne, who did the townspeople's work overnight and
> were gone before anyone woke up.

Heinzel is a macOS command-line tool with two jobs:

- **posture** — flip the machine between *travel* (locked down for the bag) and *remote*
  (open for remote use from elsewhere).
- **session** — run Claude Code unattended against a `backlog.md` on a schedule, with the sleep
  suppression, budget and stop conditions that makes safe.

```
hzl travel                # lock it down: screen sharing off, firewall closed, sudo policy reset
hzl remote                # open it up:   screen sharing on, wake-on-LAN, read-only sudo helpers
hzl on --duration 10h     # start an unattended session (expires by itself)
hzl off                   # stop it, and restore what it changed
hzl status                # what is actually true right now
```

The two axes are independent: you can open the machine without starting a session, and you can run
a session on a machine that is not exposed. What you cannot do is run one while the machine is in
travel posture — that combination is refused rather than merely discouraged.

## Status

**Design phase — not yet implemented.** The design is written down in full first:

- [`docs/DESIGN.md`](docs/DESIGN.md) — why it is built this way; the judgements and the traps
- `docs/SPEC.md` — what is normatively true (interfaces, schemas, limits) — *pending*
- `docs/RUNBOOK.md` — how to operate it — *pending*

See [`docs/DESIGN.md` §9](docs/DESIGN.md) for the phase plan.

## What it is careful about

Running an LLM agent unattended on your own machine is the interesting part, and most of the
design is about bounding it.

- **Privilege is used only when a human is present.** The unattended lane — launchd → runner →
  engine — has no path to root at all. Not a narrowed one; an absent one. No `sudoers` entry that
  can write anything.
- **State is a composed function, not a stored flag.** Expiry, a reboot, a dead liveness marker,
  an authentication failure or the machine going into travel posture each independently drop the
  session to "do nothing". There is only one direction to fall.
- **Cost is bounded three ways** — tasks per run, tasks per session, wall clock — plus a schedule
  that structurally excludes the working day.
- **When in doubt, it stops.** A task the agent cannot verify, or that needs a human judgement, a
  destructive action, credentials, or anything that leaves the machine, is marked blocked with a
  reason. Only a human can un-block it.
- **It never degrades silently.** An invalid permission file aborts the run rather than running
  without the denials. A truncated diff says so. A misspelled effort level is rejected at startup.
- **Its output gets read back.** Changes made by the executor can be reviewed by a second,
  read-only engine before the ledger is allowed to close a task.

## Requirements

- macOS (developed against 26.6 on Apple silicon)
- `/bin/bash` 3.2 — the stock one; no newer bash required
- [Claude Code](https://claude.com/claude-code) for the unattended session
- `jq`
- Optionally a second agent CLI as the reviewer

No Homebrew dependency: notably, Heinzel does **not** require coreutils' `timeout`, which stock
macOS does not ship. It carries its own watchdog.

## Installation

Not yet. Phase 1 will add `hzl install`.

## Prior art

Heinzel merges two personal tools by the same author: `macmode` (the posture switch) and `kobito`
(the unattended-session specification). The lineage, and what changed in making them one publishable
tool, is documented in [`docs/DESIGN.md`](docs/DESIGN.md) §1 and §8.

## License

[Apache License 2.0](LICENSE).
