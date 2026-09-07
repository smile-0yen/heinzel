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
hzl next                  # what it would pick up next, and in which checkout
hzl add "..."             # put a task in the queue
hzl web                   # the same, in a browser, on 127.0.0.1 only
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

## Quick start

Eight steps, about five minutes, and **nothing runs unattended until step 8**. Every step says
what you should see, so if you get something else you can stop there rather than carry on.

### 1. Check the four things it needs

- macOS (developed against 26.6 on Apple silicon)
- `/bin/bash` 3.2 — the stock one; no newer bash required
- [Claude Code](https://claude.com/claude-code), installed and signed in
- `jq`

```sh
sw_vers -productVersion && jq --version && claude --version
```

Three version numbers means you have them. `caffeinate`, `pmset`, `launchctl` and `lockf` are
already on any Mac. There is no Homebrew dependency: notably, Heinzel does **not** require
coreutils' `timeout`, which stock macOS does not ship — it carries its own watchdog. A second
agent CLI, as the reviewer, is optional and off by default.

### 2. Install

```sh
git clone https://github.com/smile-0yen/heinzel.git
cd heinzel && ./install.sh
```

That links `hzl` into `~/.local/bin` and copies `etc/heinzel.conf.example` to
`etc/heinzel.conf`. It does nothing else — no schedule, no privilege, no background process —
and it prints the next four steps back to you. If it warns that `~/.local/bin` is not on your
`PATH`, either add it to your shell profile or link `bin/hzl` into a directory that is; both
work, because `hzl` finds its own libraries through the symlink.

### 3. Say what to work on, and where the queue lives

Two lines in `etc/heinzel.conf`. Both must be **absolute** paths — launchd runs with `cwd=/`, so
a relative path is not a latent bug, it is a certain abort.

```sh
DEFAULT_WORKDIR="/Users/you/projects/alpha"
DEFAULT_BACKLOG="/Users/you/.heinzel/backlog.md"
```

The working directory has to exist already; the backlog file is created for you. Keep the
backlog **outside** the working directory: the sandbox that confines the agent is a path
boundary, so a backlog kept elsewhere is one the agent cannot reach even through a subprocess.

### 4. Check the setup

```sh
hzl doctor
```

Eight numbered sections — prerequisites, configuration, launch agent, session state, power,
working directories, review, posture. Read section 2 and section 6 in particular: they are the
ones about the two paths you just wrote. Sections that are not set up yet say so; what you are
looking for is the absence of `XX`.

### 5. Generate the schedule and the agent's permission file

```sh
hzl install
```

This writes `~/Library/LaunchAgents/local.heinzel.plist` (when the runner wakes) and
`etc/heinzel-settings.json` (what the unattended agent may and may not do), both from your
configuration. **Run it again after changing `DEFAULT_WORKDIR`, `DEFAULT_BACKLOG` or
`HEINZEL_HOURS`** — those values are baked into the two generated files, and nothing else
notices that they have gone stale.

### 6. Write a task

```sh
mkdir -p ~/.heinzel && $EDITOR ~/.heinzel/backlog.md
```

```markdown
## P1
- [ ] the install note says ~/bin, but the installer uses ~/.local/bin
      note: README.md, near the top
```

`- [ ] <the task>` under a `## P1` heading, and that is the whole format you write by hand.
Ids, markers and timestamps are the runner's; indented lines under a task are context and are
passed to the agent word for word. Then:

```sh
hzl next
```

which tells you what would be picked up next, and in which checkout.

### 7. See what starting a session would do, without starting one

```sh
hzl on --dry-run
```

Prints the session it would create — TTL, budgets, working directory, backlog — and changes
nothing. This is also the cheapest way to find a configuration mistake, because it fails on
exactly what a real `hzl on` would fail on.

### 8. Start it

```sh
hzl on --duration 10h
```

The session expires by itself after ten hours; there is a 24-hour ceiling that is not
configurable. From here:

```sh
hzl status          # what is actually true right now
hzl schedule        # when the next run is, and whether it will do anything
hzl off             # stop it, and restore what it changed
```

### In the morning

```sh
hzl report
```

What is blocked, with the one-line request each blocked task carries, and what got done. It
exits `10` when something needs a decision, so it can drive a notification without being
parsed. `hzl take <id>` prints a blocked task together with its instructions.

Expect blocked tasks. A run that cannot verify its work, or that needs a judgement call, a
credential, or anything irreversible, is *supposed* to stop and say why — that is the design
working, not the exception.

### What you have not switched on

`hzl travel` and `hzl remote` change your firewall, screen sharing and sudo policy, and they
refuse to touch anything until you set `HEINZEL_POSTURE=1` deliberately. Review by a second
engine is off until you set `HEINZEL_REVIEW=1`. Neither is needed for any of the above.

`DEFAULT_WORKDIR` also takes several checkouts, one absolute path per line. The queue stays one
backlog and a task picks its checkout by name — `- [ ] (dir:beta) fix the redirect` — with the
first line of the list as the default for tasks that name none. A run works one checkout per
night, whichever the highest-priority task names. `docs/RUNBOOK.md` has the details.

## Prior art

Heinzel merges two personal tools by the same author: `macmode` (the posture switch) and `kobito`
(the unattended-session specification). The lineage, and what changed in making them one publishable
tool, is documented in [`docs/DESIGN.md`](docs/DESIGN.md) §1 and §8.

## License

[Apache License 2.0](LICENSE).
