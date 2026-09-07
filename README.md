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
hzl schedule              # when the next run is, and whether it will do anything
hzl report                # the morning read: what is blocked, what got done
```

The two axes are independent: you can open the machine without starting a session, and you can run
a session on a machine that is not exposed. What you cannot do is run one while the machine is in
travel posture — that combination is refused rather than merely discouraged.

## Status

**Early, and honest about it.** The whole system is implemented and its parts
have been exercised by hand, but **no run has yet called a real engine** — every
run so far has been a dry run. `docs/SPEC.md` §15 lists exactly what has been
verified and what has not; nothing there is rounded up.

- [`docs/DESIGN.md`](docs/DESIGN.md) — why it is built this way; the judgements and the traps
- [`docs/SPEC.md`](docs/SPEC.md) — what is normatively true: interfaces, schemas, limits
- [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — how to operate it, and what to do when it stops
- [`docs/VERIFICATION.md`](docs/VERIFICATION.md) — the manual test plan for everything SPEC §15 lists as unverified

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
- **The backlog stays short, and what needs you is loud.** What is closed and what is blocked are
  swept into files beside the backlog, so the file you open is the queue and nothing else — and
  what needs a decision is a file of its own rather than a marker to spot.
  `hzl report` is the morning read — what is blocked, with reasons, and what got done — and it
  exits 10 when something needs a decision, so it can drive a notification without being parsed.
- **The agent never gets the backlog.** Each run is handed a worksheet holding only the tasks it is
  allowed to work on; the runner merges the result back and is the ledger's only writer. A run
  cannot close, revert or reword a task it was not given, and that is checked against a list the
  agent cannot reach rather than asked for in a prompt.

## Requirements

- macOS (developed against 26.6 on Apple silicon)
- `/bin/bash` 3.2 — the stock one; no newer bash required
- [Claude Code](https://claude.com/claude-code) for the unattended session
- `jq`
- Optionally a second agent CLI as the reviewer

No Homebrew dependency: notably, Heinzel does **not** require coreutils' `timeout`, which stock
macOS does not ship. It carries its own watchdog.

## Installation

```sh
git clone https://github.com/smile-0yen/heinzel.git
cd heinzel && ./install.sh
```

That links `hzl` into `~/.local/bin` and copies the example configuration.
Then edit `etc/heinzel.conf` (at minimum `DEFAULT_WORKDIR` and
`DEFAULT_BACKLOG` — keep the backlog outside the working directory), and:

```sh
hzl doctor          # check the setup
hzl install         # generate the launchd agent and the permission file
hzl on --dry-run    # see what starting a session would do
```

Nothing runs unattended until you run `hzl on`, and `hzl travel` / `hzl remote`
refuse to touch anything until you set `HEINZEL_POSTURE=1` deliberately.

## Prior art

Heinzel merges two personal tools by the same author: `macmode` (the posture switch) and `kobito`
(the unattended-session specification). The lineage, and what changed in making them one publishable
tool, is documented in [`docs/DESIGN.md`](docs/DESIGN.md) §1 and §8.

## License

[Apache License 2.0](LICENSE).
