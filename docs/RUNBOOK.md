# Heinzel — Runbook

How to operate it. For *why* it is built this way see [DESIGN.md](DESIGN.md);
for what is normatively guaranteed see [SPEC.md](SPEC.md).

## A night, start to finish

```sh
hzl work --duration 10h     # remote posture + work; expires by itself
                            # ... go to bed ...
hzl status                  # in the morning: what happened
hzl take                    # what it could not finish, and why
hzl off                     # stop, restore sleep, and close remote access
```

`hzl work` asks for your password for `pmset -a disablesleep 1` and, when
posture management is enabled, for the posture transition.
That is what keeps the machine awake with the lid closed. Nothing else in the
unattended path uses privilege at all.

## Before you leave the house

```sh
hzl off
```

Closes screen sharing, blocks inbound traffic, turns off wake-on-LAN, sets the
screen to lock immediately, removes the relaxed sudo policy, and stops any
session that is running.

If Heinzel really must keep working while it travels, use `hzl mobile`. It
applies the same closed posture but lets scheduled runs continue on battery,
so it warns and asks for confirmation. Non-interactive use must say
`hzl mobile --yes` explicitly. Use `hzl work` when the machine is back on the
desk.

## Reading `hzl status`

The `mode` line is `work` or `mobile` with an expiry, or `off` with the reason.
Every off reason maps to exactly one row here:

| Reason | What it means | What to do |
|---|---|---|
| `no state file (never started)` | Nothing has been started yet | `hzl work` |
| `state.json is unreadable (permissions - was hzl run under sudo?)` | The state file is owned by root | `sudo chown $(id -un) ~/.heinzel/state.json`, and never run `hzl` under sudo |
| `state.json is corrupt` | Interrupted write, or hand-edited | `hzl work` rebuilds it |
| `mode is normal` | No session. Nothing is wrong | Nothing |
| `halted: auth …` | Credentials failed, so runs stopped | Re-authenticate the engine, then `hzl resume` |
| `halted: consecutive-failures …` | Three failures in a row | Read `hzl logs`, fix the cause, then `hzl resume` |
| `expired (…) - run 'hzl off', sleep settings are still changed` | The TTL ran out | **Run `hzl off`.** Runs have stopped on their own, but restoring `pmset` needs your password, so it did not happen |
| `boot session mismatch (rebooted, or an old state file)` | The machine rebooted | `hzl work` again if you still want a session |
| `the caffeinate marker (pid N) is gone` | The liveness marker died | `hzl work` again. Killing it is also the documented emergency stop |
| `<mode> mode does not match <posture> posture` | A mode transition partly failed, or an OS setting moved afterwards | Re-run the intended `hzl work`, `hzl mobile`, or `hzl off` transition |
| `unknown operating mode: …` | The state file was written by an incompatible build or edited | Run `hzl off`, then choose `hzl work` or `hzl mobile` |

The last one is worth knowing on purpose: **killing the `caffeinate` process
stops all further runs immediately**, without a password and without finding
this document.

### `posture: mixed`

The posture components disagree — usually a transition that half-failed, or a
setting changed by hand in System Settings. `hzl doctor` section 8 prints each
component separately. Re-running `hzl off`, `hzl work`, or `hzl mobile` settles it.

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

`hzl off` closes the machine up but exits non-zero, and the runner log has a
`HALT` line naming a run. It means a process
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

## Watching a run that is still going

`hzl logs -f` follows the *runner*: the gates it walked, the worksheet it
handed over, the review at the end. It says nothing about what the agent is
doing in the half-hour in between, because that is not the runner's log. That
is the agent's own output, in the run's exec directory. Every supported
executor writes JSONL as the work happens:

```sh
ls -dt ~/.heinzel/logs/*/exec-*/ | head -1     # the run in progress
tail -f ~/.heinzel/logs/2026-09-08/exec-030001/raw
```

One JSON object per line, appended as it goes. Raw it is unreadable at speed;
through `jq` it is a commentary:

```sh
tail -f ~/.heinzel/logs/2026-09-08/exec-030001/raw |
  jq -r --unbuffered '
    if .type == "assistant" then
      (.message.content[]? |
       if .type == "text" then .text
       elif .type == "tool_use" then "· " + .name
       else empty end)
    elif .type == "result" then
      "— " + (.subtype // "done") + "  $" + (.total_cost_usd // 0 | tostring)
    elif .type == "text" then .part.text
    elif .type == "tool_use" then "· " + .part.tool
    elif .type == "step_finish" then
      "— step  $" + (.part.cost // 0 | tostring)
    else empty end'
```

`--unbuffered` is the flag that matters. Without it `jq` holds its output in a
buffer and the commentary arrives in bursts, several minutes behind the run.

Three things this is not:

- **Not a way to intervene.** It is a read of a file. The run holds the working
  directory and there is nothing to type into. To stop one, `hzl off`.
- **Not a stable format.** Each CLI owns its event stream, and an upgrade may
  change it. Heinzel normalises the engine-specific fields into `result.json`;
  that file beside `raw` is the form to write anything durable against.
- **Primarily for the executor.** Claude reviews and repair passes write one
  object only when they end. Codex and OpenCode use JSONL for every role, but
  those shorter passes are normally observed through the runner log. It is the
  long unattended executor pass that is worth following. `docs/SPEC.md` §9
  says which role writes which.

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
| `hzl todo` | Every task waiting to be picked up, in the order runs take them |
| `hzl take` | Everything blocked, with priorities |
| `hzl take <id>` | The task and its steps, as a prompt to paste into an interactive session |
| `hzl done <id> "note"` | Close it out by hand |
| `hzl block <id> "reason"` | Park it. The reason is required |
| `hzl unblock <id>` | Put it back in the queue |
| `hzl steps` | Which blocked tasks have instructions for you, and which do not |
| `hzl steps <id>` | Start the instructions for one, from a form |
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

### A blocked task is a request, and it comes with steps

Blocking is how an unattended run hands a task to you, so the agent is told to
write the block as a request rather than as a report: `reason:` is one line, in
the imperative, saying the first thing for you to do. Everything that does not
fit on one line goes in a file of its own:

```
~/.heinzel/blocked/h-0009.md
```

named for the task and sitting beside the ledger. It is written for somebody
who was not there and is not necessarily an engineer: what is needed from you,
why it stopped, the steps in order with the commands written out in full, what
you should see when each one works, and how to hand the task back.

```
hzl report        every blocked task, its one-line ask, and where its steps are
hzl take <id>     the task and the whole steps file, ready to paste into a session
hzl steps         which of them have steps and which do not
hzl steps <id>    start the steps for one, from a form, and fill it in yourself
```

Nothing points at the file from inside the ledger: the name follows from the
id, so a task line and its instructions cannot drift apart. A task blocked
before any of this — or parked by hand with `hzl block` — has a reason and no
steps, and `hzl steps <id>` is how it gets some. Unblocking leaves the file
where it is; it is what was asked of you, not a mistake.

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

What is set up here is a **Claude scheduled task**, `heinzel-morning-report`,
which runs `hzl report --days 1` every morning at 07:00 and writes the summary
in the language the blocked notes are written in. It is a task of the Claude
desktop app, not a launchd job and not a cloud routine: the ledger is a local
file under `HEINZEL_HOME` and a cloud agent has no way to reach it. It lives in
`~/.claude/scheduled-tasks/heinzel-morning-report/`, is listed under
"Scheduled" in the app, and runs while the app is open — if the app was closed
when it was due, it runs at the next launch. Nothing in `hzl` knows about it, so
removing it is removing that directory and nothing else.

The one thing its prompt must say, and does, is that **exit 10 is not a
failure**: `hzl report` exits 10 exactly when something is blocked, which is the
morning it matters most.

## 画面で見る

```sh
hzl web
```

`http://127.0.0.1:3151/` を開く。読み込んだときに一度だけ集めて、あとは右上の
**更新** を押したときだけ取り直す。止めるのは ctrl-c。

出るもの: いまの判定（開いているか、次はいつか、走っても何もしないのか）、
セッションの設定、あなた待ちの一覧とその理由、待ち行列、チェックアウト、
そして運行図表 — 破線が launchd の予定の枠、実線が実際に走った run で、
枠だけあって線が無いところが gate で止まった回。理由は `runner.log` の skip 行。

`backlog に積む` フォームがこのページで唯一書き込む場所で、書き込みは `hzl add`
を通る。だから run が merge している最中でも backlog のロックの内側に入るし、
id の採番も run と同じ。

`127.0.0.1` にしか出ない。LaunchAgent ではないのも意図で、backlog を書ける常駐
サービスは、誰も見ていない時間帯もずっと動き続け、`hzl off` を通り抜けて
listen し続ける唯一のものになる。ページを開いている間だけ開いていればいい。

python3 が要るのはこのコマンドだけで、`hzl doctor` はそう書く。無人で動く経路は
python3 が無くても何も変わらない。

```sh
hzl add --priority 1 --dir heinzel "hzl schedule の出力に色を付ける"
hzl dashboard --days 7 | jq .        # 画面と同じものを JSON で
```

## Several checkouts

`DEFAULT_WORKDIR` takes more than one, a line each:

```sh
DEFAULT_WORKDIR="/Users/you/projects/alpha
/Users/you/projects/beta"
```

The queue is still one backlog. A task picks its checkout by name — the last
component of the path — at the front of the line:

```markdown
## P1
- [ ] (dir:beta) the login page forgets the redirect
- [ ] this one has no (dir:), so it goes to alpha
```

The first line of `DEFAULT_WORKDIR` is the default: a task with no `(dir:)` is
worked there. `hzl next` prints the workspace of the task it would pick, and
`hzl take <id>` prints the `cd` for the checkout the task is about.

A run works in **one** checkout — whichever the highest-priority task names —
and takes only that checkout's tasks. So a night moves through one tree at a
time, and the per-run limit counts within it. That is not a policy choice: an
agent runs with one working directory, and the sandbox that confines it is
rooted there.

Run `hzl install` after adding a checkout. The agent's permission file names
every configured workspace and is generated from this value; `hzl work` refuses a
`--workdir` that is not one of them, so the session and the installed rules
cannot disagree.

Two checkouts may not share a last path component — `~/a/api` and `~/b/api` —
because `(dir:api)` would then mean either. Every command refuses the pair by
name rather than picking one.

To run a session against only some of them:

```sh
hzl work --workdir beta                  # just this one
hzl work --workdir alpha --workdir beta  # these two, alpha the default
```

## When it runs

```sh
hzl schedule
```

The whole answer in one screen: the next slot as a clock time, the four after
it, whether the launch agent is actually loaded, whether the plist installed
matches the configuration on disk, and — the line worth reading first —
`will it run`, which walks the runner's gates in order and names the first one
that is shut. A slot inside a session that has less than one wall clock left
before it expires is a slot that fires and does nothing; that is the case
reading `HEINZEL_HOURS` by eye gets wrong every time, and it is the case this
line is for. `hzl status` carries the next slot on one line, and `hzl status
--json` as `next_run`.

`HEINZEL_HOURS` in `etc/heinzel.conf` is the schedule, and `hzl install` writes
it into the LaunchAgent:

```sh
HEINZEL_HOURS="1 2 3 4 5"   # 01:00 to 05:00, on the hour
HEINZEL_HOURS="all"         # every hour, whenever the session is on
```

`all` is the word, not `*`: the value is split by the shell, and `*` would
become the names of whatever files were nearby. Run `hzl install` after changing
it — the plist is generated from this value, and so is the runner's own guard.

Every hour means the agent may work while you are at the machine. Nothing else
changes: it still runs only in `work` or `mobile`, refuses scheduled battery use
in `work`, requires travel posture in `mobile`, and stops at the session budget.
What it does mean is that it may be writing in the working directory
while you are, so `all` suits a checkout the agent owns better than one you are
also editing.

`HEINZEL_MIN_RUN_GAP_SEC` (default 3000) is the least time between two runs,
measured from when the last one **started**. An hourly schedule never reaches
it. What it is for is the wake-up: launchd replays the calendar events it missed
while the machine was asleep, and with `all` every one of them is inside the
window — without a gap, opening the lid at nine would fire every hour you slept
through, one after another. `hzl run-now` is never gated by it.

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

## How much of the account's limit is left

```sh
hzl budget
```

Not the task budget above: this is the subscription's own usage limit, for
each engine a switched-on role uses (planner, executor, reviewer), as
percentage left and when it resets. It asks each CLI the way you would -
`claude -p /usage` for Claude, and for Codex the app-server call behind the
interactive `/status` - so Heinzel never reads a key or calls a provider's
host itself. `codex exec /status` is deliberately not used: `exec` hands the
text to the model as a prompt, which spends a turn and returns no numbers.

Limits belong to the account, not to a model, so they are grouped by engine; a
model with a limit of its own (`week (Fable)`, `5h (GPT-5.3-Codex-Spark)`) is a
line of its own, named the way the CLI names it. OpenCode has no such question
to ask and says so. `hzl budget` exits 1 if any engine could not be read, with
the CLI's own reason on that engine's line.

## When it costs money, and when it does not

Only one thing in the whole system costs money: the engine call. Eight gates
stand in front of it, and the last one — *is there anything to do?* — is
immediately before it. An empty backlog, a spent budget, being on battery,
being outside the window, or having no session all cost a fraction of a second
and zero tokens.

Actual spend per run is in `runs.jsonl` as `cost_usd`. To cap it directly
rather than by task count, set `HEINZEL_MAX_BUDGET_USD`.

## Safe mode: what a run may not touch

On unless you turn it off. It denies the commands that reach something which is
not this machine and not a file — `gcloud`, `kubectl`, `terraform`, `helm`,
`ssh`, `rsync`, `docker push`, `npm publish` and the rest of the list in
`docs/SPEC.md` §13.1 — so a run that would have deployed instead blocks the
task and leaves you a request. `git push origin` is not on the list: the
release ritual needs it, and the sandbox already admits only `github.com`.

The run log says which mode it was in, on the `safe` line of the header, and
`hzl doctor` section 2 says whether the installed permission file agrees with
your configuration. If they disagree with the setting on, a run **aborts** — a
control believed to be on and absent is worse than one that was never claimed.

To turn it off, in `etc/heinzel.conf`:

```sh
HEINZEL_SAFE_MODE=0      # then: hzl install
```

`hzl install` is not optional there. The rules live in the generated permission
file, so until it is regenerated the setting says one thing and the run gets the
other: the commands stay denied and `hzl doctor` remarks on the disagreement.
The reverse — turning safe mode back on and not reinstalling — is the one that
**aborts** the next run, because that is the direction where a control is
believed to be on and is not.

It is all of them or none of them. If you want a run that may reach exactly one
cluster and nothing else, safe mode is the wrong tool: leave it on, do that
task with `hzl take <id>` in an interactive session, and close it with
`hzl done`.

## Common situations

**"It did nothing all night."** `hzl status` first. Most likely the session
expired, the machine went onto battery, or the backlog had no `[ ]` lines.
`hzl schedule` would have said so the evening before: its `will it run` line
answers for the next slot, and the same gates decided every slot overnight.
Scheduled runs skip on battery deliberately; `hzl run-now` does not, so it is
the way to check whether anything else is wrong.
`grep skip ~/.heinzel/logs/runner.log` shows which gate closed and when.

**"It stopped after a few runs."** Look for `HALT`. Three consecutive failures
or an authentication failure stop everything on purpose; `hzl resume` after
fixing the cause.

**"The machine will not sleep any more."** A session expired without `hzl off`.
`hzl status` warns about exactly this. Run `hzl off`.

**"It marked something done that is not done."** Turn the review on:
`HEINZEL_REVIEWER=1` with a second engine configured. A rejected review reverts
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
