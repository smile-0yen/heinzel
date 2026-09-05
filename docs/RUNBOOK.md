# Heinzel — Runbook

How to operate it. For *why* it is built this way see [DESIGN.md](DESIGN.md);
for what is normatively guaranteed see [SPEC.md](SPEC.md).

## A night, start to finish

```sh
hzl remote                  # machine is on the desk and staying there
hzl on --duration 10h       # start a session; it expires by itself
                            # ... go to bed ...
hzl status                  # in the morning: what happened
hzl take                    # what it could not finish, and why
hzl off                     # stop, and put the sleep settings back
```

`hzl on` asks for your password once, for one command: `pmset -a disablesleep 1`.
That is what keeps the machine awake with the lid closed. Nothing else in the
unattended path uses privilege at all.

## Before you leave the house

```sh
hzl travel
```

Closes screen sharing, blocks inbound traffic, turns off wake-on-LAN, sets the
screen to lock immediately, and removes the relaxed sudo policy. If a session
is running it is stopped first, and you are told so.

You cannot start a session while the machine is in travel posture; `hzl on`
refuses with an explanation. There is no `--force` for that. Run `hzl remote`
when the machine is back on the desk.

## Reading `hzl status`

The `session` line is either `on` with an expiry, or `off` with the reason it
is off. Every reason maps to exactly one row here:

| Reason | What it means | What to do |
|---|---|---|
| `no state file (never started)` | Nothing has been started yet | `hzl on` |
| `state.json is unreadable (permissions - was hzl run under sudo?)` | The state file is owned by root | `sudo chown $(id -un) ~/.heinzel/state.json`, and never run `hzl` under sudo |
| `state.json is corrupt` | Interrupted write, or hand-edited | `hzl on` rebuilds it |
| `mode is normal` | No session. Nothing is wrong | Nothing |
| `halted: auth …` | Credentials failed, so runs stopped | Re-authenticate the engine, then `hzl resume` |
| `halted: consecutive-failures …` | Three failures in a row | Read `hzl logs`, fix the cause, then `hzl resume` |
| `expired (…) - run 'hzl off', sleep settings are still changed` | The TTL ran out | **Run `hzl off`.** Runs have stopped on their own, but restoring `pmset` needs your password, so it did not happen |
| `boot session mismatch (rebooted, or an old state file)` | The machine rebooted | `hzl on` again if you still want a session |
| `the caffeinate marker (pid N) is gone` | The liveness marker died | `hzl on` again. Killing it is also the documented emergency stop |
| `posture is travel` | The machine is closed up | `hzl remote` if it is back on the desk |

The last one is worth knowing on purpose: **killing the `caffeinate` process
stops all further runs immediately**, without a password and without finding
this document.

### `posture: mixed`

The posture components disagree — usually a transition that half-failed, or a
setting changed by hand in System Settings. `hzl doctor` section 8 prints each
component separately. Re-running `hzl travel` or `hzl remote` settles it.

## Reading the logs

```sh
hzl logs             # the most recent run's full log
hzl logs -n 3        # the last three
hzl logs -f          # follow the current one
```

`~/.heinzel/logs/runner.log` is one line per event. The first word is the
classification, and it is the thing to look at:

| Word | Meaning | Your move |
|---|---|---|
| *(no line at all)* | No session was running. Writing nothing is the design | Nothing. `HEINZEL_DEBUG=1` records these too |
| `skip` | A gate closed: outside the window, budget spent, on battery, nothing to do | Usually nothing. For budget messages consider `hzl set`. `hzl run-now` ignores the window and the battery |
| `abort` | A precondition failed: a missing directory, an invalid settings file | Needs you. A relative path in the configuration is the classic one |
| `HALT` | Runs stopped by themselves: auth failure, or three failures running | Fix the cause, then `hzl resume` |
| `ok` | A run finished. Counts, budget, duration and review outcome on one line | — |

`~/.heinzel/logs/runs.jsonl` is one JSON object per run, for anything you want
to graph. `~/.heinzel/logs/<date>/notes.md` is the handover: read that first in
the morning, it is written for a human.

`~/.heinzel/runs/<run-id>/` is one directory per run that got as far as calling
an engine: `workflow.json` says where that run had got to and which task ids it
was holding, and `events.jsonl` says what happened, one line at a time. A run
killed at the deadline leaves a `run.interrupted` line and a snapshot naming the
tasks it was holding — which is how you tell a run that was stopped from one
that finished quietly. A run stopped by `hzl off` leaves more: a
`cancel.intent.json` saying a stop was asked for and why, and, once something has
watched the process go, a `cancel.receipt.json` saying it happened. Those two
files are the difference between "we asked" and "it stopped".

`~/.heinzel/claims/` is who is holding which task, and for which run. The `[~]`
you see in the ledger is a display of it, not the record — the record is here,
where the agent cannot write. If a run is killed, its claims stay until the next
run releases them, and that release names the dead run and touches nothing else.
Nothing in the ledger tells you which run holds a `[~]`; the claim does.

### `ORPHANED`

`hzl off` exits non-zero, `hzl travel` closes the machine up and then exits
non-zero, and the runner log has a `HALT` line naming a run. It means a process
was asked to stop and **nothing could confirm that it did**. It is not a failure
and not a success: it is an unanswered question, and until it is answered that
run's task claims and its writer lease are deliberately kept, so no new run will
touch that checkout.

What to do, in order:

```sh
hzl status                              # what the session thinks
cat ~/.heinzel/runs/<run-id>/cancel.intent.json    # what was asked, and when
ps -p $(jq -r .target_pid ~/.heinzel/runs/<run-id>/cancel.intent.json)
```

If the process really is gone, the barrier lost a race and the run is over;
deleting `~/.heinzel/workspace-leases/` and the run's entries under
`~/.heinzel/claims/` releases the checkout. If it is still there, it is still
writing to your working directory — stop it yourself before anything else, and
do not start a run until you have.

Those records carry a `schema_version`, and so do `state.json` and each run's
`result.json`. A file without the field is version 1 and is read as one — by
this build and by anything you wrote against it. Nothing rewrites a record it
only read, so a state file you carried back from a newer build still opens, and
graphs written against the old fields keep working: every version so far only
adds. `hzl doctor` prints the version it found.

## The backlog

The ledger lives wherever `DEFAULT_BACKLOG` points, and it is the only place
you and the unattended runner meet. Keep it **outside** the working directory:
`hzl doctor` warns if it is not, and moving it means `hzl install` again,
because the path is baked into the agent's permission file.

The agent never sees this file. Each run gets a *worksheet* instead — the two
or three `[ ]` lines that run is allowed to work on — and the runner merges the
result back here afterwards. Two things follow that are worth knowing when you
are reading the file in the morning:

- Everything you see was written by the runner, including the timestamps and
  the `run:` ids. The agent's report is what goes in the handover notes; it is
  not what moved anything here.
- A run cannot touch a line that was not on its worksheet. That is enforced by
  a list the agent cannot reach, not by the prompt asking it nicely.

```markdown
## P1
- [ ] (id:h-0007) refresh the unused-disk report
      note: last one is in reports/2026-05.md
- [x] (id:h-0003) add tests <!-- done:2026-08-18T17:42:00+09:00 run:20260818-174200 -->
- [!] (id:h-0009) needs cloud credentials <!-- blocked:2026-08-18T18:10:00+09:00 reason:permission-denied -->
```

Write tasks as `- [ ] some task` under a `## P1` heading. Everything else is
managed for you:

- **Do not write ids by hand.** The runner allocates them. Hand-written ids
  collide, and the `run:` field on a completed line has to stay unambiguous —
  it is what lets a review revert its own run's work and nobody else's.
- **Do not edit the markers or the `<!-- ... -->` comments by hand.** Use the
  commands; then the format cannot go wrong.
- Indented lines under a task are context, and they are passed to the agent
  verbatim. This is the place to put "the last one is in X" or "don't touch Y".

| Command | Effect |
|---|---|
| `hzl next` | What would be picked up next, and why. When nothing is free it lists what is in progress and which run holds it, rather than reading as an empty backlog |
| `hzl take` | Everything blocked, with priorities |
| `hzl take <id>` | A prompt to paste into an interactive session |
| `hzl done <id> "note"` | Close it out by hand |
| `hzl block <id> "reason"` | Park it. The reason is required |
| `hzl unblock <id>` | Put it back in the queue |
| `hzl archive` | Run the sweep by hand: closed and blocked out, unblocked back in |
| `hzl report` | The morning read: what is blocked, what got done |

Priority order is all of P1 before any of P2, and top to bottom within a
section. Only `[ ]` lines are ever picked up: a blocked task stays blocked
until you move it, which is deliberate — and it waits in `backlog.blocked.md`
rather than in the queue, because the queue is what happens next.

**Expect blocked tasks to accumulate.** The agent is told that when a task
needs a judgement call, a credential, or anything irreversible, the right
answer is to stop and say why. `hzl report` in the morning is the normal way to
use this, not an exception.

### What the machine cannot pick up leaves the file

A backlog that keeps everything it ever served is a log wearing a queue's
format, and it costs you twice: the file you open to add a todo is mostly
history, and the `[!]` lines that actually need you sink into a month of `[x]`.

So the ledger is three files, split by whose move it is:

```
backlog.md             the queue:            [ ]  [~]
backlog.blocked.md     waiting on you:       [!]
backlog.completed.md   the record:           [x]
```

Same format, same ids, same priorities; the two derived names are fixed, not
configured. The runner sweeps at the top of each run; `hzl archive` does it on
demand, and `hzl block` / `hzl unblock` do it as part of the command so a task
never sits in the wrong file while you are looking at it.

`backlog.md` is now exactly what happens next, and `backlog.blocked.md` is a
file whose entire contents are addressed to you — which is a thing you can read
on its own with `hzl report` or `hzl take`.

You do not have to think about this, with three exceptions:

- **All three files are the ledger.** Ids are allocated across the set, so an
  archived `h-0007` is never handed out again. Do not renumber or delete ids in
  the other two files.
- **The blocked file is live, and the way back is a marker.** Change a `[!]`
  there to `[ ]` (or run `hzl unblock <id>`) and the task returns to the backlog
  at its old priority on the next sweep. Moving the line by hand also works —
  the marker is what decides, not which file it is sitting in.
- **Back them up together.** The archive is where the record of what was done
  lives; the backlog on its own no longer answers "what happened last month".

### The morning

```
hzl report            what is blocked and what got done since yesterday
hzl report --days 7   the week
hzl take <id>         a prompt for the one you want to unblock
```

`hzl report` exits **10** when something is blocked and **0** when nothing is,
so it can drive a notification without anything parsing its output:

```sh
hzl report --quiet || osascript -e 'display notification "heinzel needs you"'
```

`--json` gives the same content as `{since, backlog, blocked_file, archive,
todo, blocked[], completed[]}`, which is the shape to hand to something that
writes you a summary.

Scheduling that is **yours to set up, deliberately**. Heinzel installs exactly
one launchd job, the one that runs the nightly session, and it does not grow a
second one for a report — a tool that quietly adds background jobs is a tool you
stop being able to reason about. A `crontab` line or your own LaunchAgent is the
whole of it.

## The budget

Three ceilings, all independent:

```sh
hzl set                     # show them
hzl set max-total 5         # tasks for the whole session
hzl set max-tasks 2         # tasks per run
hzl set timeout 1800        # wall clock per run, seconds
```

Changes apply to the running session without re-authenticating. The effective
per-run limit is `min(max-tasks, max-total − done so far)`, so the session
total always wins.

A session that has spent its budget skips the rest of its slots in a fraction
of a second, without calling anything.

## When it costs money, and when it does not

Only one thing in the whole system costs money: the engine call. Eight gates
stand in front of it, and the last one — *is there anything to do?* — is
immediately before it. An empty backlog, a spent budget, being on battery,
being outside the window, or having no session all cost a fraction of a second
and zero tokens.

Actual spend per run is in `runs.jsonl` as `cost_usd`. To cap it directly
rather than by task count, set `HEINZEL_MAX_BUDGET_USD`.

## Common situations

**"It did nothing all night."** `hzl status` first. Most likely the session
expired, the machine went onto battery, or the backlog had no `[ ]` lines.
Scheduled runs skip on battery deliberately; `hzl run-now` does not, so it is
the way to check whether anything else is wrong.
`grep skip ~/.heinzel/logs/runner.log` shows which gate closed and when.

**"It stopped after a few runs."** Look for `HALT`. Three consecutive failures
or an authentication failure stop everything on purpose; `hzl resume` after
fixing the cause.

**"The machine will not sleep any more."** A session expired without `hzl off`.
`hzl status` warns about exactly this. Run `hzl off`.

**"It marked something done that is not done."** Turn the review on:
`HEINZEL_REVIEW=1` with a second engine configured. A rejected review reverts
that run's completions to blocked, and only that run's.

**"I need to reboot it remotely."** With FileVault on, an ordinary reboot stops
at the unlock screen and you cannot reach it. Use
`sudo fdesetup authrestart`, which unlocks the disk on the way back up.
Heinzel cannot help with this; it is how the OS works.

## Emergency stop

In order of escalation:

```sh
kill $(cat ~/.heinzel/caffeinate.pid)   # every later run no-ops. No password
hzl off                                 # stop cleanly and restore settings
hzl uninstall                           # remove the launchd agent entirely
```

The first works because the liveness marker is one of the seven conditions a
session is judged by. It needs no privilege and no working `hzl`.
