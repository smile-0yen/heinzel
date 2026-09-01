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
| `hzl next` | What would be picked up next, and why |
| `hzl take` | Everything blocked, with priorities |
| `hzl take <id>` | A prompt to paste into an interactive session |
| `hzl done <id> "note"` | Close it out by hand |
| `hzl block <id> "reason"` | Park it. The reason is required |
| `hzl unblock <id>` | Put it back in the queue |

Priority order is all of P1 before any of P2, and top to bottom within a
section. Only `[ ]` lines are ever picked up: a blocked task stays blocked
until you move it, which is deliberate.

**Expect blocked tasks to accumulate.** The agent is told that when a task
needs a judgement call, a credential, or anything irreversible, the right
answer is to stop and say why. `hzl take` in the morning is the normal way to
use this, not an exception.

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
