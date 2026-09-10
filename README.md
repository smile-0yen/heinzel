# Heinzel

**Let a coding agent work your backlog overnight, on a Mac you left behind — without leaving
anything unsafe switched on.**

> *Heinzelmännchen* — the house gnomes of Cologne, who did the townspeople's work overnight and
> were gone before anyone woke up.

Heinzel is a macOS command-line tool with three modes. Each combines how the
machine is exposed with whether unattended work is running:

```
hzl work --duration 10h   # remote posture + unattended work (the normal mode)
hzl off                   # travel posture + no unattended work
hzl mobile                # travel posture + unattended work; confirms battery use
hzl status                # what is actually true right now
hzl schedule              # when the next run is, and whether it will do anything
hzl budget                # how much of each engine's usage limit is left
hzl next                  # what it would pick up next, and in which checkout
hzl todo                  # every task waiting to be picked up, in that order
hzl add "..."             # put a task in the queue
hzl web                   # the same, in a browser, on 127.0.0.1 only
hzl report                # the morning read: what is blocked, what got done
```

There is deliberately no command for an idle machine left open for remote use.
`work`, `off`, and `mobile` are the three useful combinations; `mobile` is the
exceptional one and requires confirmation because scheduled runs continue on battery.

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
  an authentication failure or a mismatch between the selected mode and observed posture each
  independently drop the session to "do nothing". There is only one direction to fall.
- **Cost is bounded three ways** — tasks per run, tasks per session, wall clock — plus a schedule
  that structurally excludes the working day.
- **When in doubt, it stops.** A task the agent cannot verify, or that needs a human judgement, a
  destructive action, credentials, or anything that leaves the machine, is marked blocked with a
  reason. Only a human can un-block it.
- **It cannot touch a real environment, unless you say it may.** Safe mode is on by default and
  denies the commands that reach a cluster, a cloud account, a registry, a package index or
  another host — `gcloud`, `kubectl`, `terraform`, `helm`, `ssh`, `docker push`, `npm publish` and
  the rest. A run that needs one blocks the task instead, which is the point: a deploy at three in
  the morning is the action nobody is there to take back. `HEINZEL_SAFE_MODE=0` turns it off, all
  at once and deliberately; with it on, a run whose permission file does not carry the denials
  aborts rather than proceed believing itself confined.
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
- one supported agent CLI, installed and signed in: [Claude Code](https://claude.com/claude-code)
  (the default), [Codex](https://developers.openai.com/codex/cli/) or
  [OpenCode](https://opencode.ai/docs/cli/)
- `jq`

```sh
sw_vers -productVersion && jq --version
claude --version       # or: codex --version / opencode --version
```

Three version numbers means you have them. `caffeinate`, `pmset`, `launchctl` and `lockf` are
already on any Mac. There is no Homebrew dependency: notably, Heinzel does **not** require
coreutils' `timeout`, which stock macOS does not ship — it carries its own watchdog. A second
agent CLI, as the reviewer, is optional and off by default.

To use OpenCode, set these in `etc/heinzel.conf` and run `hzl doctor`:

```sh
HEINZEL_EXECUTOR_ENGINE="opencode"
HEINZEL_OPENCODE_MODEL="anthropic/claude-sonnet-4-5"  # required provider/model
HEINZEL_OPENCODE_VARIANT="high"                       # optional, provider-specific
```

The same `opencode` value may be used for `HEINZEL_REVIEWER_ENGINE`; Heinzel launches a separate
read-only OpenCode agent for that role. OpenCode's executor confinement is permission-layer rather than the OS-level
boundary used by Claude/Codex; read the explicit limitation in `SECURITY.md` before leaving it
unattended.

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

### 7. See what work mode would do, without starting it

```sh
hzl work --dry-run
```

Prints the session it would create — TTL, budgets, working directory, backlog — and changes
nothing. This is also the cheapest way to find a configuration mistake, because it fails on
exactly what a real `hzl work` would fail on.

### 8. Start it

```sh
hzl work --duration 10h
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

The posture half of `hzl work`, `hzl off`, and `hzl mobile` changes your firewall, screen sharing
and sudo policy only after you set `HEINZEL_POSTURE=1` deliberately. Until then the OS posture is
reported as unmanaged, while the unattended-session half still works. The read-only planner and
reviewer are both off on a fresh install; enable their role defaults with `HEINZEL_PLANNER=1` and
`HEINZEL_REVIEWER=1`.

Planner, executor, and reviewer each have their own engine, model, and effort setting. For example,
`HEINZEL_PLANNER_MODEL="claude-opus-5"` can plan for an executor using
`HEINZEL_EXECUTOR_MODEL="claude-sonnet-5"`. The planner runs first without write or shell tools,
and its final answer is inserted verbatim into the executor prompt.

The one switch that is on already is safe mode, and it is on because nobody would think to look
for it: an unattended run may not call `gcloud`, `kubectl`, `terraform`, `ssh`, `docker push`,
`npm publish` or anything else that reaches past this machine. It blocks the task instead.
`HEINZEL_SAFE_MODE=0` in `etc/heinzel.conf`, followed by `hzl install`, turns it off —
`docs/RUNBOOK.md` says what you are taking on.

`DEFAULT_WORKDIR` also takes several checkouts, one absolute path per line. The queue stays one
backlog and a task picks its checkout by name — `- [ ] (dir:beta) fix the redirect` — with the
first line of the list as the default for tasks that name none. A run works one checkout per
night, whichever the highest-priority task names. `docs/RUNBOOK.md` has the details.

A task can also replace the three role defaults: `(roles:planner,executor)` plans and implements
without review, while `(roles:executor,reviewer)` skips planning and keeps the review gate. The
directive names the complete enabled set. Tasks with different effective role sets are put in
different runs. At least planner or executor must be enabled, and reviewer requires executor
because it reviews the executor's workspace changes rather than the planner's prose.

## Tutorial: one night, end to end

The Quick Start got it installed. This is the same machine one night later, in full: what to put
in the queue, what a run does with it, what it leaves behind, and what to do in the morning with
what you find. Allow about twenty minutes.

Throughout, `~/projects/alpha` is the checkout and `~/.heinzel/backlog.md` is the queue — the two
paths you put in `etc/heinzel.conf`. Substitute yours.

### 1. Write tasks a run can finish on its own

This is the part that decides whether unattended work is worth anything, and it is entirely on
your side of the line. A task suits a run that nobody is watching when all four are true:

1. **It is verifiable by running something.** The agent is told that work it cannot verify is not
   done, and that it must block instead. A task with no way to check it comes back blocked.
2. **It lives in one checkout.** A run works in a single workspace — the one the highest-priority
   task names — so a task that spans two is two tasks.
3. **It needs nothing from outside.** No credential, no account, nothing sent anywhere. Those are
   block conditions by design, not accidents.
4. **It has one right answer.** Anything that turns on taste — which name, which of two acceptable
   designs — is a decision the run will hand back to you rather than take.

| A run can do this | It will block on this |
| --- | --- |
| `hzl report --json` is documented but the flag is never parsed — make it work, with a test | make the reporting better |
| `parse_duration` accepts `25h`; it should refuse anything over the 24h ceiling | tighten up the duration handling |
| the install note says `~/bin`, the installer uses `~/.local/bin` | fix the docs |
| drop `lib/ui.sh`'s unused colour helper and its callers | tidy the codebase |

The right-hand column is not a list of bad ideas. It is a list of things to decide first and
queue second: each one becomes a fine task the moment you say what "better" means.

Two ways in. The command:

```sh
hzl add --priority 1 "hzl report --json is documented but the flag is never parsed"
hzl add --dir beta "the login page forgets the redirect after sign-in"
hzl add "drop lib/ui.sh's unused colour helper and its callers"
```

`--priority` is 1..99 and defaults to 99, so the first of those is worked first. `--dir` names a
checkout by its last path component, and matters only if `DEFAULT_WORKDIR` lists several.

Or the file, which is the same thing:

```markdown
## P1
- [ ] hzl report --json is documented but the flag is never parsed
      note: cmd_report in bin/hzl. There is a --json branch; nothing reaches it.
      note: the exit code must stay 10 when something is blocked.
```

Indented lines under a task are notes, and they are handed to the agent word for word — this is
where the context you have and the agent does not goes. Markers, ids and timestamps are the
runner's; never write them yourself.

Then ask what is next:

```sh
hzl next
```

It prints the id (or `(id assigned at the next run)` for a line you typed), the priority, the
workspace with its absolute path, the task and its notes. If the workspace is one this machine
does not have configured, it says so here — worth knowing now rather than as a blocked task in the
morning.

### 2. Do the first run while you are watching

You do not have to wait for 03:00, and for the first one you should not.

```sh
hzl work --duration 2h --max-tasks 1 --dry-run
```

Prints the session it would create and changes nothing. When it looks right, drop `--dry-run`:

```sh
hzl work --duration 2h --max-tasks 1
```

Starting a session kicks a run immediately (`--no-kick` if you would rather wait for the
schedule). `--max-tasks 1` is deliberate for a first night: one task is enough to see the whole
shape of the thing, and the per-run budget is the cheapest of the three ceilings to change later.

To run one on demand at any point, from inside a session:

```sh
hzl run-now            # ignores the schedule window; the other gates still apply
hzl run-now --dry-run  # everything up to the engine, then stop
```

### 3. Watch it

```sh
hzl logs -f
```

The log opens with what the run decided before spending anything — run id and what triggered it,
the working directory, the budget for this run and for the session, the engine, model and effort,
whether the machine is on AC, and how many tasks were waiting.

Most runs never get that far, and that is the design working. Eight things are asked in order,
each of them before the engine is called:

| # | The run stops when | Notes |
| --- | --- | --- |
| 1 | there is no live session | silent for launchd; `hzl run-now` says so out loud |
| 2 | the hour is outside `HEINZEL_HOURS` | manual runs are exempt |
| 3 | the last run started less than `HEINZEL_MIN_RUN_GAP_SEC` ago | this is what stops a wake-up replay firing every slot the machine slept through |
| 4 | the session's task budget is spent | `hzl set max-total N` raises it mid-session |
| 5 | the machine is on battery | a manual run warns and carries on; a scheduled one stops |
| 6 | there is less time left in the session than a run may need | so a run is never started that cannot finish |
| 7 | a precondition fails | a workspace that is not there, a backlog that is not writable, no engine, or a permission file that is missing, malformed or still holding placeholders |
| 8 | there is nothing to do | the last gate, immediately before the engine |

Number 7 is the one to read twice. `claude --print` ignores a malformed settings file without a
word, so a run whose permission file will not parse **aborts** rather than running with no deny
list at all.

### 4. What a run leaves behind

Four things, in four places:

- **The worksheet**, `~/projects/alpha/.heinzel/worksheet.md` — the tasks this run was given, and
  only those. The agent never sees the backlog; the runner merges the worksheet back afterwards
  and is the ledger's only writer, so a run cannot close, revert or reword a task it was not
  handed.
- **The run log**, `~/.heinzel/logs/<date>/run-<time>.log`, beside the prompt that was actually
  sent and the engine's own output.
- **Commits in your checkout.** The agent is told to finish a task that changed the repository
  with the release ritual in that repository's `docs/RELEASING.md` — changelog entry, version
  bump, one commit, `git push origin`, tag. If your project has no such file, you get the commit
  without the ceremony; if you want a particular ritual, that is the file to write. The push is
  the *only* thing a run is allowed to send anywhere, and a refused push is recorded as
  `push pending` rather than treated as failure.
- **A request, if it stopped.** The agent writes `~/projects/alpha/.heinzel/blocked/<id>.md`, and
  the runner carries it to `blocked/<id>.md` beside your backlog, where `hzl report` points at it
  and `hzl take` reads it back.

### 5. The morning

```sh
hzl report
```

Blocked tasks first, each with the one-line ask the run wrote for you and the path to its steps;
then what was completed since yesterday; then how many are still to do. It exits `10` when
anything is blocked, so it drives a notification without being parsed:

```sh
hzl report --quiet || osascript -e 'display notification "heinzel needs you"'
```

For one of them:

```sh
hzl take h-0007
```

which prints the `cd` to the right checkout, the task, its notes and the whole of the steps file —
written to be pasted into an interactive session. If the run left no instructions, `hzl steps
h-0007` starts a form to fill in as you work, so the next person begins where you finished.

Closing the loop, once you have done it or decided it:

```sh
hzl done h-0007 "parsed --json in cmd_report; added a test"   # you finished it
hzl unblock h-0007                                            # it can go back in the queue
hzl block h-0009 "needs the staging credential"               # park one yourself
hzl archive                                                   # sweep closed and blocked out of the backlog
```

`hzl archive` is what keeps the backlog readable: what is done goes to the completed archive, what
is blocked to the blocked file, and the file you open stays the queue and nothing else. It runs on
its own at the start of every run; the command is for when you want it now.

Then read the work itself. It is a commit like any other:

```sh
git -C ~/projects/alpha log --oneline -5
git -C ~/projects/alpha show <sha>
```

### 6. Set the pace

Three independent ceilings, and none of them is a suggestion:

```sh
hzl set                  # what this session's limits are
hzl set max-tasks 2      # per run
hzl set max-total 6      # per session
hzl set timeout 5400     # wall clock per run, seconds
```

`hzl set` changes the live session; `etc/heinzel.conf` changes the defaults every future session
starts from. For the schedule:

```sh
hzl schedule             # when the next run is, and whether it will do anything
```

`HEINZEL_HOURS` in `etc/heinzel.conf` decides the hours, and **`hzl install` must be re-run after
changing it** — the plist is generated from that value and nothing else notices it has gone stale.
The default `1 2 3 4 5` excludes the working day structurally rather than by convention.

When you are done for the night, or want the machine back:

```sh
hzl off
```

Stops the session, restores what it changed, applies the closed travel posture when posture
management is enabled, and exits non-zero if it could not confirm a run had stopped — which is
your signal to look, not to shrug.

### 7. When something looks wrong

```sh
hzl doctor               # eight sections; you are looking for the absence of XX
hzl status               # exits 0 when no session is running, 10 when one is
hzl status --json        # the same, for a script
hzl logs -n 3            # the last three run logs
hzl resume               # clear a halt, once you know why it halted
```

`hzl doctor` is the first thing to run and it catches the two mistakes that actually happen: a
`DEFAULT_WORKDIR` or `DEFAULT_BACKLOG` that moved without `hzl install` being re-run, and a
permission file that no longer names the backlog it is supposed to keep the agent out of.

## Prior art

Heinzel merges two personal tools by the same author: `macmode` (the posture switch) and `kobito`
(the unattended-session specification). The lineage, and what changed in making them one publishable
tool, is documented in [`docs/DESIGN.md`](docs/DESIGN.md) §1 and §8.

## License

[Apache License 2.0](LICENSE).
