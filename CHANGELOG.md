# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.1] - 2026-09-08

A run in progress can now be watched from a terminal. The executor is launched
with `--output-format stream-json --verbose`, so its `raw` file is written a
line at a time as the agent works instead of appearing whole when the run is
already over, and `tail -f` on it is a live commentary.

A patch bump. `raw` has always been "the engine's own output", never a format
this project defines or promises - `result.json` is the interface, and it is
unchanged, field for field. But anything you wrote that reads `raw` directly
needs to know: for the claude **executor** it is now JSONL, so `jq .` becomes
`jq -s .` or a read of the last line. The reviewer's `raw` is untouched.

### Changed
- **The claude executor streams.** `--output-format stream-json --verbose`;
  `--verbose` is required rather than decorative, because the CLI refuses
  `stream-json` under `-p` without it.
- **The claude reviewer deliberately does not.** Whether `--json-schema`
  survives being combined with `stream-json` is unknown, and a reviewer whose
  schema was silently dropped would return prose where the runner parses a
  verdict - a worse failure than a review nobody can watch. It stays on
  `--output-format json`, an argv assertion holds it there, and the open
  question is written down in `docs/SPEC.md` §15 for a live run to settle.
- **One reader for both shapes.** The verdict and the telemetry come from the
  object the CLI marks `"type": "result"` - the last line of a stream, or the
  whole of the reviewer's single object - so nothing outside `lib/engines.sh`
  has to know which role wrote the file it is holding. It reads the file twice
  where it has to: `jq -s` first, which handles a pretty-printed object spread
  over several lines and every record written before this release, then line by
  line dropping what will not parse. The second reading is what saves a run cut
  off at the deadline, where one half-written last line would otherwise make
  `jq` reject the hundred complete events before it.
- **A run that reported nothing records nothing**, rather than a zero. No
  result object means `cost_usd: null`, no turns and no text - and `last.txt`
  is now empty rather than holding the single newline an empty message used to
  render as, so a run cut off before it spoke is not recorded as having said
  one blank line.

### Added
- **18 regression assertions** over three fixed JSONL samples - a stream that
  finished, one whose result line says `is_error`, and one cut off mid-line
  with no result line at all. They check the normalised result, the verdict,
  what a failed run still recorded spending, that `raw` really is one parseable
  object per line, and the `cost_usd` that reaches `runs.jsonl` in all four
  cases including codex's null. The projection out of `result.json` is
  replicated from `bin/hzl-run` and pinned to its source, so the replica cannot
  quietly stop matching the runner. No real engine is called.
- **`docs/RUNBOOK.md`, "Watching a run that is still going"** - where the file
  is, the `jq` filter that turns it into a commentary, why `--unbuffered`
  matters, and three things this is not: not a way to intervene, not a stable
  format, not available for the reviewer.
- **`docs/VERIFICATION.md` phase 3** gains the three checks a fake engine
  cannot make: that lines arrive during the run, that `claude` did not refuse
  the flag pair, and that the last line is the result object.

### Documentation
- **`docs/SPEC.md` §9** now states that `raw`'s format depends on the role as
  well as the engine, as a table, with a normative note that `raw` is evidence
  and not an interface. §15 gains two unverified rows: the streamed launch
  against a real `claude`, and the `--json-schema` question.

## [0.4.0] - 2026-09-08

Three intent-based modes replace the independent posture and session commands.

The minor bump is the point: this is the first release that breaks something on
purpose, and `docs/RELEASING.md` now says that is where a breaking change goes.
The two before it, multiple workspaces and the web UI, were features shipped on
the patch digit, which under-reported them.

### Breaking

- **`hzl on`, `hzl remote` and `hzl travel` are gone.** Each exits 1 naming its
  replacement rather than doing something approximate. `hzl remote` followed by
  `hzl on` becomes `hzl work`; `hzl travel` becomes `hzl off`.
- **`hzl status --json` reports `mode` as `work`, `mobile` or `off`**, not
  `heinzel` / `normal`. A script testing `.mode == "heinzel"` now reads false in
  every mode. The exit codes are unchanged: 10 live, 0 not, 1 error.
- **`state.json` is schema v3.** This build reads a v1 or v2 file as `work`,
  which is the only live mode those files could describe. An older build reads
  a v3 file and ignores `operating_mode`, which is the direction that loses the
  posture interlock — roll the state file back with the build.
- **`HEINZEL_TICKET_TIMEOUT` is no longer read.** A `heinzel.conf` that sets it
  still loads; it is an unused key now, not an error.
- **`sudoers.d/heinzel-ticket` is never installed.** A machine carrying one from
  an earlier build has it removed by the next transition, and sudo over VNC goes
  back to the stock per-terminal, tty-scoped ticket.

### Changed

- **`hzl work`** combines remote posture with a live unattended session.
- **`hzl off`** stops the session, restores sleep, and applies travel posture.
  The posture transition still runs when the stop barrier reports an ORPHANED
  process, and the command preserves that non-zero result.
- **`hzl mobile`** combines travel posture with a live session. It warns on
  every invocation and requires interactive confirmation or `--yes`, because
  the recorded mode permits scheduled runs to continue on battery.
- **Mode transitions stop an existing session before switching posture.** The
  mode/posture pair is checked by `effective_mode`; either mismatch and an
  unknown stored mode fail closed. Schema v3 carries the choice as
  `operating_mode`.
- **The dashboard reads the same public mode values**, and the internal
  `state.mode` stays `heinzel`/`normal`: liveness is a separate question from
  which mode asked for it, and keeping them apart is what lets an older build
  still read the file.
- **Posture management remains opt-in.** With `HEINZEL_POSTURE=0`, the session
  half of each mode still works and the OS posture is reported as unmanaged.
- **Switching modes says that the task counter resets**, as `hzl on` did when it
  reconfigured a live session. `hzl doctor` names the mode on both branches.
- **40 regression assertions** cover command dispatch, dry-run UX, old-state compatibility,
  both valid live pairs, both mismatches, invalid stored values, the mobile
  battery decision, the retired sudo ticket window, and `--yes` being refused by
  `work`. The non-interactive `mobile` assertion reads from `/dev/null`: without
  it the suite inherits the developer's terminal and blocks on the confirmation
  prompt it is trying to prove exists.

### Removed

- **The write-capable sudo ticket window.** `sudoers.d/heinzel-ticket` was
  allowed only under remote posture with the session off, and none of the three
  modes is that pair. `etc/sudoers-ticket.in`, `HEINZEL_TICKET_TIMEOUT` and the
  code that installed them are gone; `posture_install_sudoers` knows one
  template and it is the read-only one. Removal stays — a machine upgraded from
  a build that installed the file still has it, so both postures take it away
  and invalidate outstanding tickets. Sudo over VNC is now per-terminal, with
  the stock tty-scoped ticket. See DESIGN §4.3.

## [0.3.24] - 2026-09-08

Safe mode: an unattended run may not call the commands that reach a cluster, a
cloud account, a registry, a package index or another host. On by default,
because the unattended lane is exactly where a `terraform apply` would happen
with nobody there to take it back.

**Upgrading takes one command.** The rules live in the *generated* permission
file, and nothing regenerates it on its own, so on an existing install the
setting says `1` and the file does not carry it - which is the mismatch the
runner aborts on. Run `hzl install` once and `hzl doctor` section 2 goes green.
Until you do, every scheduled run aborts at gate 6 and says why in
`~/.heinzel/logs/runner.log`.

### Added
- **`HEINZEL_SAFE_MODE`, default `1`** - the only opt-*out* switch in the
  configuration, the others all being off until asked for. `1` generates two
  deny rules per command in `hzl_safe_mode_commands` (`lib/common.sh`) into
  `etc/heinzel-settings.json`: `gcloud`, `gsutil`, `bq`, `aws`, `az`, `doctl`,
  `kubectl`, `kubeadm`, `eksctl`, `helm`, `oc`, `terraform`, `terragrunt`,
  `tofu`, `pulumi`, `ansible`, `salt`, `serverless`, `flyctl`, `heroku`,
  `vercel`, `netlify`, `wrangler`, `railway`, `firebase`, `supabase`, `ssh`,
  `scp`, `sftp`, `rsync`, `docker push`, `docker login`, `podman push`, and the
  publish commands of npm, pnpm, yarn, cargo, gem, twine, poetry, maven and
  gradle. Both `Bash(x *)` and `Bash(x:*)`, because a rule in one syntax only is
  accepted and then never consulted. A run that needs one of them is refused and
  blocks the task, which is the intended outcome.
- **The runner aborts when the setting and the file disagree** (gate 6), naming
  how many rules are missing and the first three. A control believed to be on
  and absent is the worst shape available, so this direction stops the run; the
  opposite one - the setting off, the file still carrying the rules - is a
  `hzl doctor` remark and nothing more.
- **`hzl doctor` section 2 reports safe mode**, and the run log's header carries
  a `safe` line on every run, including the runs where it is on: "was safe mode
  on that night?" is asked of a log after the fact, and the answer has to be in
  it rather than inferred from a missing line.
- **The prompt is told which mode it is in**, both ways
  (`{{SAFE_MODE_NOTE}}`). Not because a sentence enforces anything - the deny
  list does - but because an agent that knows a command will be refused blocks
  with a request a person can act on, where one that finds out by being refused
  writes a worse one. With the mode off the instruction stands and the
  enforcement does not, and the prompt says exactly that.
- **28 assertions**, including the two that carry the feature: the rules are
  generated with `HEINZEL_SAFE_MODE` *unset*, which is what an existing
  configuration looks like, and `git push` is not on the list, because the
  release ritual is built on it. Plus a check that every `{{PLACEHOLDER}}` in
  the run prompt has a `render` behind it in `bin/hzl-run` - the same failure
  the settings-template check exists for, in the other generated artefact.

### Notes
- **`git push origin` is deliberately not denied.** The release ritual needs it,
  the sandbox already admits only `github.com`, and `--force`/`--mirror`/
  `--delete` stay denied. `docs/SPEC.md` §13.1 says what else is off the list
  and why: `curl`/`wget` (the sandbox's domain allowlist is the control there,
  and denying them would deny testing a local server), the database clients (a
  rule cannot tell a local test database from a production one), and
  `docker build`/`run` (local - only what moves something *out* is listed).
- **The rules are built in `bin/hzl`, not in
  `etc/heinzel-settings.json.in`.** `etc/` is denied to the unattended agent -
  every file in it is control surface - so a run improving Heinzel can change
  the list and cannot change the template. The generated file is identical
  either way, and a human moving the block into the template later loses
  nothing.
- **`etc/heinzel.conf.example` does not document the new key yet**, for the same
  reason: written by run `20260908-030004`, which could not edit `etc/`. The
  block to paste is in `docs/RUNBOOK.md` under "Safe mode: what a run may not
  touch".
- **It is a permission-layer control, not a sandbox.** It governs the agent's
  own Bash tool; a subprocess that invokes `kubectl` itself is stopped by the
  sandbox and its domain allowlist, not by this. `SECURITY.md` states both
  limits.

## [0.3.23] - 2026-09-08

A tutorial in the README, below the Quick Start and doing the other half of the
job: the Quick Start gets it installed, this walks one night end to end. A patch
bump - documentation only, no behaviour changed.

### Added
- **`## Tutorial: one night, end to end`.** Seven sections, in the order a
  person meets them. What makes a task workable unattended, as four conditions
  and a table of four real tasks beside the four vaguer wishes they came from -
  the point being that the vague column is a list of things to decide first and
  queue second, not a list of bad ideas. Both ways to add one (`hzl add` and the
  file), what an indented note is for, and `hzl next`. Doing the first run while
  you watch, with `--max-tasks 1` and `--dry-run` first. The eight gates as a
  table, in the order `bin/hzl-run` asks them, with what each one lets through -
  including that a manual run is exempt from the window, the gap and the battery
  check but nothing else, and that a permission file which will not parse aborts
  the run rather than relaxing it. The four things a run leaves behind and where
  each lives: the worksheet in the checkout, the log under
  `~/.heinzel/logs/<date>/`, the commits (and the `docs/RELEASING.md` in *your*
  repository that decides the ritual), and the blocked steps file the runner
  carries out to sit beside the backlog. The morning: `hzl report` and its exit
  code driving a notification, `hzl take`, `hzl steps`, `done`/`unblock`/`block`,
  and what `hzl archive` is for given that every run sweeps on its own way in.
  Then the three ceilings through `hzl set` versus `etc/heinzel.conf`, the
  reminder that `HEINZEL_HOURS` needs `hzl install` after it changes, and a
  short "when something looks wrong" list.

  Every command, flag and path in it was read out of `bin/hzl` and
  `bin/hzl-run` rather than remembered: the gate order and their exemptions from
  the gates themselves, the log header from the block that writes it, the sweep
  happening on the way in, and the exit codes from `cmd_status` and
  `cmd_report`. No terminal output is quoted that was not generated by the code
  that prints it.

## [0.3.22] - 2026-09-08

A Quick Start in the README: eight steps, about five minutes, and nothing runs
unattended until the last one. A patch bump and not a minor one: the minor is
reserved for the task that completes a phase of `docs/RUNTIME-BACKENDS.md`, and
this completes none.

### Added
- **`## Quick start`, replacing `## Requirements` and `## Installation`.**
  Every step says what you should see, so a reader who gets something else can
  stop there rather than carry on: three version numbers from one line for the
  prerequisites, the four steps `install.sh` prints back, the two absolute
  paths in `etc/heinzel.conf` and why relative ones are a certain abort, the
  eight sections `hzl doctor` prints and which two are about the paths you just
  wrote, what `hzl install` generates and when it goes stale, the whole of the
  backlog format a person writes by hand, and `hzl on --dry-run` before
  `hzl on`. It ends with the morning — `hzl report`, its exit code, and the
  sentence that matters most to someone starting out: **expect blocked tasks.**
  A run that needs a judgement call or anything irreversible is supposed to
  stop and say why; that is the design working, not the exception. Followed by
  what has deliberately *not* been switched on, because posture and review are
  both opt-in and neither is needed for any of the above.

  Written by the unattended run `20260908-013305`, which then blocked its own
  task rather than claim it: it had noticed a second writer in the same
  checkout and asked for a person to decide whether to keep the work. Every
  factual claim in it was checked against the code before this commit — the
  doctor sections are eight and in that order, `doc_bad` does print `XX`,
  `install.sh` does print those four steps and that PATH note, `report` does
  exit 10, and the 24-hour ceiling is `MAX_DURATION_SEC`.

## [0.3.21] - 2026-09-08

A web UI, modelled on the 運行図表 (smile-monitor): what the session is doing,
what is waiting on a person, what is queued, and a form that puts a task in the
queue. Everything is fetched once at load and again when the refresh button is
pressed. A patch bump and not a minor one: the minor is reserved for the task
that completes a phase of `docs/RUNTIME-BACKENDS.md`, and this completes none.

### Added
- **`hzl web`.** Serves the dashboard on `127.0.0.1` for as long as the terminal
  that started it holds it. Deliberately not a LaunchAgent: everything else
  Heinzel installs runs unattended and is confined for it, while this is a
  window a person opens while they are sitting there — a resident service that
  can write the backlog would run all day whether or not anyone was looking, and
  would be the one thing still listening through `hzl travel`. The page follows
  smile-monitor's design rubric: three state colours and none for ordinary
  running, every state carrying a glyph and a word as well as a colour, the
  judgement in the largest text on the screen with its evidence beneath it, and
  a freshness stamp that greys the whole page out rather than showing an old
  answer with a fresh face. The 運行図表 itself is the spine: the dashed lines
  are launchd's scheduled slots and the solid ones are the runs that actually
  happened, traced through queued → engine → review → merge → end, so a slot
  with no line against it is a night that fired and did nothing.
- **`hzl add [--priority N] [--dir NAME] <text>`.** The ledger's writer in a
  person's hands. Tasks were added by opening `backlog.md` in an editor, which
  is fine at the machine and impossible for anything else — a form, a script, a
  phone. This is the same edit, made under the backlog lock through the same
  insertion the merge uses, so a task added while a run is merging lands cleanly
  instead of racing a rename. The id is allocated with the runner's own
  allocator, so whoever added a task is told what it is called. A task already
  in the ledger word for word exits 4 and writes nothing: two identical tasks
  are worked twice and the second finds nothing to do, and a double-submitted
  form is the ordinary way to produce that pair.
- **`hzl dashboard [--days N]`.** One JSON document: the session, the schedule
  and its slots either side of now, the workspaces and whether each still
  exists, every task in the live ledger plus the archive inside the window, the
  recent runs with their own event trails, and the tail of `runner.log`. It
  exists so the page has one thing to fetch and no parser of its own.
- **`HEINZEL_WEB_PORT`** (default `3151`), validated like every other setting.

### Changed
- **`backlog_scan` carries the trailing comment as a seventh field, and
  `ledger_blocked` stopped parsing task lines a second time.** That second copy
  had already fallen behind: `(dir:)` routing was taken off the text by
  `backlog_scan` and left on it by the copy, so the morning report and
  `hzl take` showed a tag the ledger no longer considered part of the task.
  One parser, and every reader of a task's metadata now reads the field it
  produces. Tabs inside a comment become spaces on the way in — this is a TSV,
  and a comment nobody expected to contain one would shift every field after it.
- **`hzl doctor` reports python3**, as needed by `hzl web` and by nothing else.
  A warning rather than a fault: every unattended path runs without it, and
  macOS ships `/usr/bin/python3` with the Command Line Tools.

### Fixed
- **String comparison in `awk` is wrong for multibyte text on this platform,
  and two comparisons depended on it.** Measured 2026-09-08:

      printf 'a\tログイン\nb\tデフォルト\n' |
        awk -F'\t' -v t=デフォルト '$2 == t {print $1}'
      a
      b

  BSD awk under a UTF-8 locale reports two different multibyte strings as equal.
  The worksheet's workspace filter and `hzl add`'s id lookup both compared text
  through it, so a checkout with a Japanese name would have collected another
  workspace's tasks, and `hzl add` printed the id of an unrelated task. Both run
  under `LC_ALL=C` now, which compares bytes — and byte equality is exactly what
  they want, since nothing in this program sorts or folds case on task text. The
  bug is invisible while the ledger is in English, which this one is not, so the
  regression test is pinned on a Japanese workspace name.
- **`hzl dashboard` no longer appends `null` to a perfectly good document.**
  `status --json` exits 10 when a session is live — that code is its answer, not
  a failure — and `$(cmd_status --json || echo null)` took it as one, producing
  invalid JSON exactly when a session was running, which is the case the page is
  for.

## [0.3.20] - 2026-09-08

`DEFAULT_WORKDIR` takes more than one checkout. Before this a session was one
working directory, so the only tasks that could be queued were the ones about
that one repository — and a task about any other was picked up in the wrong
tree and blocked, which is exactly how `h-0041` was lost. The queue stays one
backlog; a task says which checkout it is about, and a run works one of them.
A patch bump and not a minor one: the minor is reserved for the task that
completes a phase of `docs/RUNTIME-BACKENDS.md`, and this completes none.

### Added
- **Several working directories.** `DEFAULT_WORKDIR` holds one absolute path
  per line. One line is one workspace — which is what this setting has always
  been, so no configuration written before this changes meaning — and several
  lines are several. The separator is a newline and not a space because a path
  may contain one and this is not a list of integers like `HEINZEL_HOURS`; a
  space-separated list would halve such a path at 03:00 and the run would fail
  on a directory nobody wrote. The first line is the default. A workspace is
  named by its last path component, and there is deliberately no second setting
  mapping names to paths: a name kept in step with a path by hand goes stale,
  and the last component is already what a person calls the checkout. The cost
  is that two checkouts cannot share one, and that pair is refused by name
  rather than left to make `(dir:x)` mean either of them.
- **`(dir:<name>)` on a task.** A sixth field in the ledger's parse, taken off
  the front of the line the way the id is, so what reaches the worksheet, the
  prompt and the ledger reads as a person wrote it. It goes after the id, or at
  the front of a line that has no id yet — a person writes one and the runner
  puts the id in front of it later, and both orders parse, or a task would
  route correctly only after the run that numbered it. Only a leading tag
  routes: one written mid-text stays text, or a task *about* the syntax would
  reroute itself by being written down. Absent means the default workspace,
  which is most tasks and is why nothing has to be written at all when there is
  only one checkout.
- **A run works one checkout, chosen by the queue.** Past gate 7 the run reads
  the highest-priority `[ ]` in the order of attack and takes that task's
  workspace as its own, then works only that workspace's tasks — the per-run
  limit counts within it. Not a policy choice: an engine launch has one working
  directory and the sandbox that confines the agent is rooted there, so a
  worksheet spanning two would list tasks the agent could not reach half of.
- **`hzl on --workdir` is repeatable, and must name a configured workspace.**
  By name or by path; each occurrence adds one and the first is the session's
  default; given none, the session gets all of them. Refusing an unconfigured
  path closes the sharpest edge the tool had: `hzl install` generates the
  agent's permission file from `DEFAULT_WORKDIR`, so a session pointed
  elsewhere used to start, run, and have every write refused by rules naming a
  tree it was no longer in — with nothing saying so, in `hzl doctor` or
  anywhere else. `state.json` gains `workdirs`; a file written by an earlier
  build carries only `workdir` and reads as the one-workspace list it
  describes, so a session started last night keeps its working directory when
  this build's runner picks it up at 03:00.
- **Where a task is going, in the commands that answer questions.** `hzl next`
  prints the workspace of the task it would pick, and says so plainly when that
  workspace is one the session does not have. `hzl take` marks the workspace in
  its list and opens the pasted prompt with the `cd` that gets there — the
  first thing a person needs and the easiest to get wrong, since a task pasted
  into a session opened in the wrong tree is worked on the wrong tree.
  `hzl status`, `hzl schedule` and `hzl install` name every workspace, and
  `hzl doctor` checks each one exists rather than only the first: a checkout
  that has moved is a class of tasks that cannot be worked, and the run that
  would otherwise find out is whichever one a task naming it eventually
  reaches.

### Changed
- **The agent's permission file names every configured workspace.** The two
  allow rules per workspace are generated, the way the plist's calendar is,
  because the number of them is a function of configuration and `sed` replaces
  a placeholder with a value rather than with a list. One installed file serves
  every workspace, so the allow list is wider than any single run needs — and
  it is the sandbox that makes that acceptable, since it roots at the run's own
  working directory and leaves the other rules inert for the whole of that run.
  The layer it does cost is the inner one: were the sandbox off, an agent could
  reach every configured workspace rather than one. Which is the argument for
  listing checkouts you are willing to have worked on unattended, and not every
  checkout on the disk. Recorded in the generated file's own comment.
- **A run holds the writer lease on every workspace its session has.** The
  order is forced and there is no other: the workspace is chosen from the
  queue, the queue is read after the sweep, and the sweep is a ledger write the
  run must already own the checkouts to make. Taken in the session's recorded
  order, which is fixed, so two runners racing for the same set contend on the
  same first entry rather than half way into each other's; a run that loses
  gives back what it took before standing down. It costs nothing that was
  previously possible — a session had one workspace and one lease — and it buys
  "the checkout takes one writer" holding with six checkouts exactly as with
  one, with no window between choosing a workspace and owning it. Stale claims
  left by a killed run are now released across all of them, rather than waiting
  for a run that happens to pick that checkout again.
- **A task the agent splits off keeps the workspace it was written in.** The
  merge prepends `(dir:<name>)` to a new task when the worksheet came from a
  workspace that is not the default. The name is taken from where the worksheet
  lives — `<workdir>/.heinzel/worksheet.md` — and not from an argument, because
  the merge is reached through four callers and one of them is the recovery
  path, which finishes a commit a dead run left and has only the files that run
  wrote. Nothing is prepended for the default workspace, which is what an
  untagged task already means, nor for a name no configuration knows: a
  follow-up routed to a workspace that has never existed is a task blocked for
  a reason nobody can act on.
- **A task naming a workspace the session does not have is blocked, not
  skipped.** Skipping is the quieter failure and by far the worse one: the task
  stays at the head of the queue, is chosen again every night after, and each
  of those runs reports "nothing to do" about a backlog with work in it. The
  block says which name was not found and which names were.

## [0.3.19] - 2026-09-08

"When does this next run?" had no command behind it. `HEINZEL_HOURS` is the
shape of the schedule, not a time; `hzl install` printed the hours once, at
install; and whether a slot would actually do anything was spread across seven
gates in the runner. `hzl schedule` answers all of it in one screen, and `hzl
status` carries the next slot on one line. Cuts the three fixes that had been
sitting unreleased since v0.3.18 along with it. A patch bump and not a minor
one: the minor is reserved for the task that completes a phase of
`docs/RUNTIME-BACKENDS.md`, and this completes none.

### Added
- **`hzl schedule`.** The next slot as a clock time and the four after it, the
  hours, the minimum gap, launchd's throttle, the label, the plist, the runner,
  and the budget, timeouts, paths and engines a run would use — the settings of
  a live session when there is one, and the defaults the next `hzl on` would
  start with when there is not. Two of those lines are asked of the system
  rather than read out of the configuration, because they are the ones that go
  wrong: `launchctl` says whether the agent is really loaded, and the installed
  plist is diffed against what this configuration generates, so a schedule
  edited and never installed is named as such instead of being reported back as
  fact. The line to read first is `will it run`, which walks the runner's gates
  in the runner's own order and names the first one that is shut — no agent, no
  session, a slot past the session's expiry, **a slot inside the session with
  less than one wall clock left before it** (gate 5 refuses a run it cannot
  finish, and this is the case that reading an hours list by eye gets wrong
  every time), a spent budget, or battery. When none of them is shut it says so
  and says what is still unknowable until the slot arrives: an empty backlog, a
  sleeping machine.
- **`next run` in `hzl status`, and `next_run` in `hzl status --json`.** One
  line, in the command people already run. It is the schedule's answer, so it
  is printed whether or not a session is live — with the reason nothing will
  come of it when that is true: `nothing runs until 'hzl on'` outside a session,
  `too little session left to run` when the slot falls past the expiry or too
  close to it. The JSON field is ISO 8601 with an offset, like `expires_at`
  beside it, and is null only when the schedule names no hour at all.
- **`next_slot_epoch` and `rel_dur` (`lib/common.sh`).** The next firing is
  derived from `hours_normalised` — the same function `StartCalendarInterval`
  is generated from — so there is still one source of truth for the schedule
  and the plist is never parsed back. The search starts at the top of the hour
  following its argument and steps an hour at a time, re-reading the local hour
  each step: rounding an epoch down to a multiple of 3600 would land on `:30`
  in a zone offset by half an hour, and would carry a DST change into a wrong
  answer. The minutes and seconds already spent are subtracted rather than
  rounded away, which is why the tests pin `09:09:09` — a leading zero read as
  octal fails silently, on eight minutes of every hour.

### Fixed
- **The live ledger stays readable.** A sweep appends, and appending opens a
  `## P<n>` heading at the destination and leaves an emptied one behind at the
  source — so every block and every unblock added a heading to each live file
  and removed none. Nothing read it wrong: priority is the nearest heading above
  a line, so each repeated heading was still true. But a machine that blocks a
  few tasks a night turned `backlog.md` into a run of single-task sections under
  repeated `## P1`s, with the empty shells of the original sections stranded
  above them, and a person could no longer open the file and see their own
  queue — which is the only reason the ledger is Markdown and not a database.
  Both sweeps now end with `backlog_normalize` over the live files: one heading
  per priority, ascending, tasks in the order they were written. It is
  presentation only — no task moves between files, no marker changes, and the
  order of attack (priority ascending, then position) is exactly what it was.
  A heading a person wrote is kept word for word (`## P1 - this week`), a
  priority they left empty stays as their placeholder, a `## P<n>` inside a
  fence is still documentation, and the file is rewritten through the same
  rename as every other ledger write and only when the result differs, so a
  ledger already tidy is not touched at all. The archive is deliberately left
  alone: its repeated headings are the record of when things moved. The tidy
  does not report a status — a sweep's status is about whether the tasks moved,
  and a heading that could not be straightened is not a move that failed.
- **A new task goes into the section it belongs to, even when that section is
  empty.** `backlog_insert_at_priority` looked for the priority's last *task*,
  so `## P3` with nothing under it — a person's placeholder, or a section the
  sweep had just emptied — counted as a section that did not exist: the task got
  a second `## P3` at the foot of the file, below every other section, under a
  heading the reader had already scrolled past. The same defect as above,
  arriving by another door, and this one a person sees the moment they type
  `hzl add`. The empty heading is now found and the task written directly under
  it; only a priority with no heading anywhere still gets a new one. A `## P<n>`
  inside a fence is documentation and is never inserted into.
- **CI is green again.** shellcheck 0.11.0 reports warnings the version before
  it did not, and the `shell` job had been failing on every push to `main` for
  some time — which also meant the test step, which runs after it, was never
  reached. Nothing here changes behaviour. `--argjson done` needed quoting so
  that shellcheck stops reading the flag's name as the `done` keyword (SC1010);
  a `h-0900` on the right of an assignment needed quoting so that it is a task
  id and not `h - 0900` (SC2100); `ls | grep -c` became `find -name` (SC2010);
  and `_sc`, assigned through an `eval` shellcheck cannot see, is declared
  (SC2154).
- **A run id could not be drawn under a parent that ignores SIGPIPE.**
  `runstore_new_id` drew its suffix as `tr -dc 'a-z0-9' </dev/urandom |
  head -c 6`. That pipeline ends only when `head` exits and the write that
  follows kills `tr` — and SIGPIPE is inherited, so under a parent that ignores
  it the write returns EPIPE, BSD tr carries on, and the pipeline reads
  /dev/urandom for ever at full tilt. Node ignores SIGPIPE and so does
  everything it starts, which is how this was found: with the shellcheck step
  fixed, the test step ran in CI for the first time in a while and hung there
  until the job was cancelled, leaving an orphaned `tr` behind. Every run asks
  for an id before it does anything else, so under such a supervisor the whole
  program would hang on the first thing it did. The randomness is now bounded
  at the source by `dd`, so `tr` ends at EOF: nothing here depends on a signal
  arriving. Same shape, same alphabet, same fallback when the draw is short.
- **`t_true` and `t_false` in the test suite.** Sixteen assertions were a
  `[ ... ]` on one line and `$?` on the next. That is the status of the
  condition above — until somebody inserts a line between the two, when it
  silently becomes the status of *that*, and an assertion that reads as a check
  on a file is a check on the last `printf`. shellcheck names the shape
  (SC2319). The two new helpers take the condition itself, so there is nothing
  in between to get wrong. Assertion count and outcome are unchanged: 738
  passed, 0 failed, before and after.

## [0.3.18] - 2026-09-07

A session that is on can be allowed to work at any hour, not only in the
overnight window. A patch bump and not a minor one: the minor is reserved for
the task that completes a phase of `docs/RUNTIME-BACKENDS.md`, and this
completes none.

### Added
- **`HEINZEL_HOURS="all"`.** Every hour, expanded in one place — `hours_normalised`
  — so the LaunchAgent's calendar, the runner's own window guard and the count of
  slots left before a session expires cannot drift apart. It is the word `all`,
  never `*`: the value is read with an unquoted expansion, and a `*` in it would
  become the names of the files in whatever directory the reader happened to be
  in. `hzl_validate_conf` refuses `*` by name and says which spelling works,
  rather than letting it fail later as "'CHANGELOG.md' is not an integer".
  `hours_display` is what a person is shown, because twenty-four numbers on one
  line is a worse answer to "when does this run" than three words.
- **Gate 2b, a minimum gap between runs** (`HEINZEL_MIN_RUN_GAP_SEC`, default
  3000). It is what is left of the window guard when the window is every hour.
  Gate 2 exists because launchd replays the calendar events it missed while the
  machine was asleep; with `all` every one of those replays is inside the window,
  so opening the lid at nine would fire every hour slept through, one after
  another. The gap is measured from the last run that **actually ran** — a run
  stopped at a gate writes no `runs.jsonl` record, so a closed gate never pushes
  the next slot out — which means an hourly schedule never reaches the default
  and a replay of six missed slots runs one of them. `hzl run-now` is not gated
  by it, as it is not gated by the window. A record whose epoch is in the future
  is treated as long enough ago: a clock that moved must not stop the machine
  working until it catches up.

`docs/SPEC.md` §3.2 and §7 carry the contract, `docs/RUNBOOK.md` a section on
what "every hour" costs — the agent may be writing in the working directory
while you are. Twenty-four new assertions, mutation-checked.

## [0.3.17] - 2026-09-07

The last of the review findings against h-0020, closed. The third of them had
already gone with 0.3.14.

### Fixed
- **A ledger file is replaced, never emptied.** Six writers — `backlog_set_state`,
  `backlog_add_note`, `backlog_reset_inprogress`, `backlog_assign_ids`,
  `backlog_insert_at_priority` and the source rewrite in `ledger_move_marked` —
  built the new file in `$TMPDIR` and then did `cat "${tmp}" >"${f}"`: a
  truncate followed by a write. Between those two the ledger is empty on disk,
  and a crash there loses every task in it, the ones nobody had started
  included — the whole queue, to move one marker. They all now build the
  replacement in a scratch file beside the target and rename it over, through
  one new helper, `ledger_tmp`, which knows both halves of why: the same
  directory, because across filesystems `mv` falls back to copy-then-unlink and
  the hole comes back; and the target's mode, because `mktemp` makes a private
  file and a ledger a person cannot read is not a ledger. `worksheet_merge`,
  which grew its own copy in 0.3.16, uses the same helper now.

  Twenty-four assertions, one set per writer, each checked against the unfixed
  code: a hard link taken before the write still holds the whole file
  afterwards, the inode changed, and the mode survived. Two of them are
  structural, so that a seventh writer added later cannot reintroduce the hole
  quietly.

### Added
- **A morning report that runs itself.** The request behind h-0020 asked for a
  Claude routine that reports `blocked` and `completed` each morning, and that
  half was never built. It is a Claude scheduled task now,
  `heinzel-morning-report`, running `hzl report --days 1` at 07:00 daily and
  summarising it in the language the blocked notes are written in — including
  reading each blocked task's steps file for what it actually asks of the
  reader. Deliberately not a second launchd job: `hzl install` still installs
  exactly one, and this one is the app's, removable by deleting its directory.
  Deliberately not a cloud routine either — the ledger is a local file and a
  cloud agent cannot reach it. `docs/RUNBOOK.md` says where it lives and that
  `hzl report`'s exit 10 is not a failure, which is the one thing its prompt has
  to know.

## [0.3.16] - 2026-09-06

The three review findings left open against h-0012, closed. The first of them
was a decision rather than a defect, and the decision was to keep the deferral.

### Fixed
- **The ledger changes once per merge, by rename.** `worksheet_merge` applied
  each candidate to the ledger in place, so a merge of six candidates was six
  rewrites of the file — and `backlog_set_state` rewrites by truncating and
  writing, so a crash between two of them left a ledger holding some of the
  run's work and not the rest, or half a line of it, while the receipt written
  afterwards described a ledger that had never existed. Every candidate is now
  applied to a copy in the same directory, and the copy replaces the ledger in a
  single rename. The copy is made with `cp -p`, so the ledger keeps its own mode
  rather than inheriting `mktemp`'s private one, and a merge that changed
  nothing does not replace the file at all. A ledger that cannot be written is
  refused before any of it is computed.
- **Recovery cannot count the same completions twice.** `finalize_recover`
  moved `tasks_done_total` and then wrote the receipt. The two are separate
  files, so a crash in between left the counter moved, the receipt missing and
  the run still pending — and the next recovery added the same completions
  again. Reversing the order would have lost them instead, because a run with a
  receipt is never recovered. The counter now carries its own evidence: the run
  id goes into `counted_runs` in the same `state.json` update that moves the
  total, and a run already named there is not counted again. `state_run_counted`
  is new and absent means "no run", which is what every state file written
  before the field says.

### Decided
- **The ledger commit stays ahead of the review until Phase 4.** The finding is
  real — `bin/hzl-run` commits the ledger before `hzl-review` runs, so a revise
  verdict rolls back a ledger that has already been written while the receipt
  saying it was written is not rolled back. It is the deferral CHANGELOG 0.3.0
  recorded with its reasons, the rollback works, and swapping the order is a
  restructuring of the run, not a fix. `docs/RUNTIME-BACKENDS.md` Phase 4 now
  names the swap explicitly instead of leaving it to be inferred.

`docs/SPEC.md` §4 documents `counted_runs` and §11.4 both normative rules. Ten
new assertions, each checked against the unfixed code: the merged ledger is a
new inode and the file it replaced is intact byte for byte, the mode survives,
a no-op merge does not replace the file, and a recovery whose receipt is
removed — the exact crash — counts nothing the second time round.

## [0.3.15] - 2026-09-06

The review finding split out of h-0021 as h-0022, closed. It is the one the
nightly run could not do itself: the file it needed to edit is the one that
defines what the nightly run may edit, and `etc/` is denied to it.

### Fixed
- **All three ledger files are denied to the agent, not just the backlog.** The
  ledger became three files in h-0020, and the generated permission list still
  named one. An agent that can edit `backlog.completed.md` can mark its own work
  done; one that can edit `backlog.blocked.md` can unblock the task it was told
  to leave alone. `Read` is denied alongside `Edit` for the same reason it
  always was on the backlog: what the agent is given is the worksheet, and a run
  that could read the whole ledger could work on a task nobody put on it.
  `etc/heinzel-settings.json.in` gains four rules and `generate_settings` the
  two substitutions behind them.

  The two paths are derived with `ledger_blocked_file` and `ledger_archive`,
  which are pure string functions, rather than listed with `ledger_files`, which
  answers with the files that exist. The rule has to hold before the file does:
  a blocked file is created by the first sweep that has something to put in it,
  and a list built from what exists would leave the agent free to edit its own
  blocked queue until that sweep ran.

  The suite now lifts `generate_settings` out of `bin/hzl` and runs it against a
  copy of the template in the temp tree, so the assertions are about the
  substitutions the installer really performs: each of the three files is denied
  for both tools, no placeholder survives, and — the other direction — every
  placeholder in the template has a substitution behind it. A rule added to the
  template with nothing behind it now fails here rather than at three in the
  morning, where it would be valid JSON that matches nothing.

`docs/SPEC.md` §8.0 states it normatively.

## [0.3.14] - 2026-09-06

The four review findings left open against h-0021, closed.

### Fixed
- **A sweep that failed is no longer reported as a sweep with nothing to do.**
  `backlog_archive_done` and `backlog_sweep_blocked` print a count *and* return
  a status, and a failure prints `0` — which is exactly what a sweep with
  nothing to move prints. Every caller read the number and threw the status
  away. `hzl block` and `hzl unblock` said the task had moved when it had not;
  `hzl archive` said "nothing to sweep"; the runner logged nothing at all.
  `set_state_and_sweep` now returns **5**, the half-done status — the marker is
  set, the move did not happen — and `hzl block` / `hzl unblock` say which half
  stands and that `hzl archive` finishes it. `hzl archive` fails outright. The
  runner records a `skip`, because housekeeping must not cost a night's work,
  and names the consequence that actually bites: a task somebody unblocked
  before bed stays in the blocked file, and the worksheet is built from the
  backlog, so this run cannot pick it up.
- **The sweep's crash repair no longer duplicates notes onto another task.** A
  task already at the destination is residue from a crash between the append and
  the rewrite, and dropping it from the source is the repair. The task line was
  dropped and the continuation lines under it were not: the awk stayed in
  `archive` mode, so the notes were written to the destination a second time,
  where they landed under whichever task had been written there last and read as
  that one's. The whole task goes now, notes included.
- **Recovery writes wherever the task is, and counts only what it wrote.**
  `finalize_recover` resolves every id across the three ledger files with
  `ledger_marker_of_id` and then wrote with `backlog_set_state`, which only ever
  writes the backlog. A completion for a task that had reached the blocked file
  — a person who saw the run die can block it by hand and sweep before the next
  run recovers — could not be written, while `tasks_done_total` and the receipt
  moved on as though it had been. All three writes go through
  `ledger_set_state`, and a completion is counted when it was already applied or
  when this recovery applied it, never when the write failed.

`docs/SPEC.md` §3 documents statuses 4 and 5, §8 the two sweep rules, and §11.4
the recovery contract. Ten new assertions, each checked against the unfixed
code: the note is not written twice and the task after it is unharmed, a sweep
that cannot write its destination says so while still printing `0 0`, every
sweep call in `bin/` reads the status, and recovery lands a completion on a task
in the blocked file while counting nothing for an id the ledger no longer has.

## [0.3.13] - 2026-09-06

The three review findings left open against h-0017, closed. All three are
places where a ledger mutation could be lost, overwritten, or reported as
having happened when it had not.

### Fixed
- **The fallback merge takes the backlog lock.** When a run's store cannot be
  created there is nowhere to put a finalize intent, so `bin/hzl-run` merges the
  worksheet directly instead of going through `finalize_commit`. That path
  called `worksheet_merge` bare. `finalize_commit` takes the lock inside itself,
  so the fallback was the one ledger mutation in the program that raced: a
  `hzl done` typed while it ran would have been read, rewritten and overwritten
  by whichever of the two finished last. Losing the receipt is what the fallback
  is supposed to cost; losing the single writer was not. It is now
  `with_backlog_lock worksheet_merge`, and a merge that cannot take the lock
  says so in the run log rather than being reported as an unreadable worksheet.
  A structural test asserts that every `worksheet_merge` call site in `bin/` is
  spelled under the lock, and that the library's only caller is the one already
  holding it — the suite does not drive `bin/hzl-run` end to end, and an
  unguarded call would otherwise show itself only on exactly the night the
  fallback exists for.

- **A task closed between being chosen and being claimed is no longer
  reopened.** `worksheet_write` reads the ledger without the backlog lock — it
  is choosing what to propose, not writing — and the claim that follows takes
  the lock and wrote `[~]` unconditionally. `hzl done` and `hzl block` take that
  same lock, so a human's edit lands wholly inside that window or wholly
  outside it; landing inside it, their `[x]` was turned back into `[~]`, the
  finished task was put in front of the agent, and the merge closed it a second
  time. That is not work lost so much as work reopened, which is worse: the
  ledger then disagrees with the person who wrote it and nothing says so. The
  new `worksheet_claim_refusal` re-reads each id inside the lock and refuses any
  marker that is not `[ ]`, including a task that has left the backlog entirely
  because `hzl block` moved it. An unrecognised marker is refused rather than
  allowed, so a marker added later arrives here as a refusal instead of a task
  silently claimed on a state nobody considered.

- **`hzl done <id> "what changed"` no longer says `done` when the note was
  lost.** The `backlog_add_note` call ended a `&&` list whose status an
  unconditional `return 0` discarded, so the command reported success whether or
  not the reason reached the ledger. The note is the entire point of the
  argument — the marker says a task ended, not what came of it — and a ledger of
  completions nobody can account for is what that silence produces. The
  transition moved to `ledger_close_with_note` in `lib/common.sh`, beside the
  other ledger mutations and therefore testable, and returns status 4 when the
  marker was set and the note was not. `cmd_done` reports that state precisely:
  the task is closed, the reason is not recorded, and here is how to add it. The
  marker is deliberately not rolled back — the work really was done, and undoing
  the true half to conceal the missing half would be the worse trade.

### Changed
- `worksheet_claim_refusal` and `ledger_close_with_note` are new in
  `lib/common.sh`. Both were lifted out of `bin/hzl-run` and `bin/hzl` so the
  rules could be tested directly: the suite sources the libraries and never
  runs the binaries as subprocesses, and it should not start — `hzl_load_conf`
  reads the operator's real `etc/heinzel.conf`, so a binary driven from a test
  resolves the real ledger.

## [0.3.12] - 2026-09-06

The three review findings left open against h-0010, closed. All three are in
`lib/claims.sh`, which had not been touched since that task wrote it.

### Fixed
- **A workspace reached through a symlink is the same workspace.**
  `claims_workspace_identity` built its identity with `abspath`, which
  canonicalises the parent and keeps the last component as written. A workdir
  reached as itself and through a symlink to it was therefore two identities
  with two claims directories, and neither could see the other's claims — one
  workspace claimed twice at once, which is the single thing a claim exists to
  prevent. The identity is now the physical path (`cd -P`), which resolves every
  symlink on the way including the last one. A workdir that is not there still
  falls back to `abspath`: naming a workspace and requiring it to exist are
  different questions.
- **A claim is created, not written over.** `claims_acquire` read the claim file
  and then wrote it, so two runs that both found a task free could both succeed,
  and the second would overwrite the first's record of holding a task they were
  both working on. It now writes the record into a temp file in the same
  directory and `ln`s it into place — link refuses an existing name, so the
  refusal is the filesystem's and exactly one of any number of racers ends up
  holding the task. (`_lock_take` in `lib/locks.sh` has always done it this way;
  the technique is spelled out again rather than shared, because locks.sh
  already depends on claims.sh for the workspace hash.) That the short locks
  happen to serialise today's only caller is not the claim keeping its own
  promise. Sixteen concurrent acquirers now assert it, and the assertion fails
  on the old code every time.
- **The fencing generation survives a release.** It lived in the claim file, so
  releasing the claim took the counter with it and the next holder was issued
  generation 1 again — the same number the previous holder had, which is exactly
  what a fencing check has to be able to tell apart. It moves to
  `<task>.generation` beside the claim, the way `lib/locks.sh` has kept its
  lease generation all along, and is bumped before the claim is taken; a run
  that loses the race consumes a number, because generations must be unique and
  increasing rather than gapless. `claims_generation` still reports the standing
  claim's number, and 0 when nothing holds the task.

## [0.3.11] - 2026-09-06

The four review findings left open against h-0014, closed. All of them are in
the Phase 0 Herdr spike, which is a document and a bookkeeping script for a
spike a person runs by hand; none of them changes any code that runs.

### Fixed
- **`na` no longer counts as a passed gate.** `gate_verdict` looked only for
  `fail` and `todo`, so a step recorded `na` left its gate reading `pass`. `na`
  is the honest record of a step that *could not be run* — the step it depended
  on failed, the platform has no such feature — and every one of those reasons
  leaves the safety question the step was asking still open. The whole table
  exists to stop a gate passing on the strength of checks nobody performed, and
  it was doing the opposite. `na` is now `incomplete`, exactly like `todo`, on
  every class of gate rather than only the ones someone thought to special-case.
  `docs/HERDR-SPIKE.md` says so in both places a reader would look: the verdict
  rules and the results-table legend.

- **D3 no longer fails the correct configuration.** The step asked for
  `git push origin HEAD` to be refused and called an unattended writer that can
  push "the worst outcome available in this document". But
  `etc/heinzel-settings.json.in` allows a plain push on purpose — `github.com`
  is the one outbound domain the sandbox permits, so that the release ritual in
  `docs/RELEASING.md` can push commits and tags — and denies privilege (`sudo`,
  `su`, `doas`) and history rewriting (`--force`, `-f`, `--mirror`, `--delete`).
  A spike run against a correctly configured pane would have recorded a `G-SEC`
  failure, and one against a pane that refused everything would have passed. D3
  now checks the list that is actually generated: `sudo`, a force push, and a
  force push laundered through a subprocess must be refused, a plain push must
  succeed, and a *refused* plain push is its own finding — the pane is applying
  some profile other than the attested one, and a confinement you cannot
  predict is one that will surprise a release at night.

- **`G-VERIFY` is `no-success`, not `critical`.** Its documented consequence is
  that `exec_verifier` returns `verifier_unavailable` and no run reaches
  `SUCCESS` — a backend that gets built and then declines to call anything done.
  Classed `critical`, a `G-VERIFY` failure printed "do not implement the
  unattended Herdr backend" over a result that says no such thing, which is the
  kind of overstatement that gets a gate argued away later. It is now its own
  class, outranked by `critical` and outranking `required-review`, with an
  outcome paragraph that states the real consequence.

- **D6 does not edit the operator's own agent configuration.** The step set a
  distinctive value in the real `~/.claude/settings.json` and the real Codex
  user config to see whether it overrode the launch arguments, and gave no way
  back — in a spike whose defining property is that teardown is a delete, and
  which kills agents mid-turn two stages later. D6 now establishes each engine's
  config-location redirect first and puts the distinctive value in a file under
  the spike root, with a control step that confirms the redirected file is
  actually read: without it, "the launch arguments won" cannot be told apart
  from "the file was never read", and the second reads as a pass while proving
  nothing. Where no redirect exists the answer is `na` with the reason — which,
  after the first fix above, correctly leaves `G-SEC` incomplete rather than
  passed. The copy-aside fallback is documented for an operator who decides the
  answer is worth it, and its restore and digest re-check are part of the step:
  a D6 that does not print two equal digests is a `fail` whatever the override
  question answered. A new safety rule states outright that the spike modifies
  nothing outside its own root.

## [0.3.10] - 2026-09-06

The review finding left open against h-0009, closed.

### Fixed
- **A run store is created, never reopened.** `runstore_init` made the run's
  directory with `mkdir -p`, which succeeds on a directory that is already
  there. A run id handed out twice would therefore have reopened the first
  run's store and appended this run's lines to its `events.jsonl` — one audit
  trail that is a faithful record of neither run, with nothing in the file to
  say so. It now uses plain `mkdir` and fails if the directory exists; only the
  shared `runs/` parent is still created with `-p`, because every run shares it
  and its existence carries no information. `runstore_new_id` also checks
  (`runstore_id_free`, new and exported for that reason) and re-mints before
  handing an id out, bounded at eight tries — the cheap half of the guarantee,
  for the case the exclusive `mkdir` would otherwise have to catch. A run whose
  store cannot be created keeps no durable record of itself, which the runner
  already handles and reports; the log line now says so, and says it wrote into
  no other run's. `docs/SPEC.md` §11.1 states it normatively.

  The id is not re-minted at `runstore_init`: by then it has already keyed the
  workspace writer lease and the run lock, and changing it there would release
  a lease under a name nothing holds.

## [0.3.9] - 2026-09-06

The review finding left open against h-0008, closed.

### Fixed
- **A run goes to the backend its session recorded.** `hzl on` writes
  `runtime_backend` into `state.json` — that field was h-0008's own addition —
  and then nothing read it. `engine_run`, the run snapshot's `runtime_backend`
  and the backend reported for a run with no `result.json` each read
  `HEINZEL_RUNTIME` instead, defaulting to `local`. A run starts at 03:00 from
  launchd, which passes `PATH`, `HOME` and `LANG` and nothing else (§14), so at
  the one moment it mattered the environment variable could only ever say
  `local`, whatever the session had asked for — and the run would then record a
  backend it had not used. All three now go through one new function,
  `runtime_selected`, which answers with the session's recorded backend
  whenever there is a state file and reads `HEINZEL_RUNTIME` only when there is
  not: a run started by hand, or `hzl on` deciding what to write down in the
  first place. A state file naming a backend this build does not have still
  fails the run at `runtime_run_batch`; it is not fallen back from. A v1 state
  file, written before the field existed, answers `local` as it always meant
  to. `docs/SPEC.md` §9.0 states it normatively, and nine assertions cover both
  directions — a session that recorded an unknown backend fails the run without
  starting anything here, and one that recorded `local` runs here even when the
  environment asks for something else.

## [0.3.8] - 2026-09-06

The two review findings left open against h-0007, closed.

### Fixed
- **The local runtime carries a launch environment instead of refusing one.**
  `docs/RUNTIME-BACKENDS.md` §8.4 has the LocalRuntime pass a validated env as
  `env KEY=VALUE ... command`, but `lib/runtimes/local.sh` failed any launch
  whose `env` was not empty, and a test held that refusal in place as the
  contract. Nothing writes a non-empty `env` yet — `engine_build_launch` still
  writes `{}` — so the refusal cost nothing today and would have cost the next
  backend the seam it is supposed to inherit. The environment is now restored
  NUL-delimited, name and value alternating, the same way argv already was, and
  prepended as `env KEY=VALUE ...`; `env` execs the command in place, so the pid
  the watchdog holds and the process group it signals are unchanged. Nothing is
  prepended when there is no environment to carry.
- **A launch that cannot be represented in a process is refused.** An argument
  holding a NUL byte was silently split in two: NUL is the delimiter the restore
  reads on, so `jq` emitted one and the loop read two arguments where the spec
  said one. §8.4 asks for that to be rejected at the spec, and it now is —
  together with a NUL in an environment value, an environment name outside
  `[A-Za-z_][A-Za-z0-9_]*`, and a non-string in either array. The check runs
  before anything is started, so a refused launch leaves no process and no
  `collected.json`. `docs/SPEC.md` §9.0 states it normatively. Seven assertions
  cover the carried environment (values holding a space, a newline and an `=`,
  read back out of the process NUL-separated) and each refusal.

## [0.3.7] - 2026-09-06

The review finding left open against h-0006, closed.

### Fixed
- **A run that never starts can no longer report the previous run's success.**
  `engine_run` emptied `raw`, `last.txt` and `stderr` before each launch but
  left `collected.json` and `result.json` where they were. An `<outdir>` may be
  reused, and the launch can fail before the backend observes anything at all —
  an unregistered `HEINZEL_RUNTIME`, a launch spec with no executable or an
  empty argv, a `cwd` that cannot be entered. In that case the readability
  check on `collected.json` found the *previous* run's record, normalised it,
  and wrote this attempt a `result.json` saying `verdict: ok` for a process
  that was never started. Both files are now removed before anything is built,
  so the honest state — nothing collected — is the one a reader finds
  (`docs/SPEC.md` §9). Three new assertions run a clean run and a refused one
  in the same directory and check that nothing of the first survives.

## [0.3.6] - 2026-09-06

The revise the reviewer asked for on 0.3.5, and the gap it listed closed.

### Fixed
- **Recovery finds the steps of a run that was stopped politely.** 0.3.5 made
  it normative that `finalize_recover` installs a blocked task's steps "from
  the source the intent recorded", and recorded the working-directory copy. But
  a run stopped by a signal — the deadline, `hzl off`, a closed lid — runs its
  trap, and the trap's `stash_steps` had already moved that copy to
  `exec-*/blocked/` and removed it from the working directory. So the guarantee
  held for a run killed with SIGKILL and failed for one stopped with SIGTERM,
  which is the one `hzl off` sends. Recovery now reads the intent's source
  first and the copy the run kept second, found through the `exec_dir` in the
  run's own snapshot (`docs/SPEC.md` §8.0.2, Recovery). And `stash_steps` no
  longer removes a copy it could not keep: it may be the only one a person has
  not read yet. Four new assertions cover the trap-then-recover path.
- `hzl take <id>` on a task with no steps file now says to start one with
  `hzl steps <id>` — the command that creates the directory and the form —
  rather than telling the reader to write into a path that may not exist.
- `hzl steps <id>` refuses to write over a steps file that exists but cannot
  be read, instead of treating "unreadable" as "absent" and truncating it with
  the blank form. The file is somebody's; the fix is its permissions.

### Closed
- The known gap of 0.3.5 — the tasks already in `backlog.blocked.md` had no
  steps — is closed the way it said it would be: from an interactive session,
  one task at a time, with each file written against the reviewer's findings
  as they stand in this tree, and each `reason:` rewritten as the one thing
  the reader should do.

  527 pass.

## [0.3.5] - 2026-09-06

### Added
- **The steps a blocked task asks for** (`docs/SPEC.md` §8.0.2). Blocking is
  how an unattended run hands a task to a person, and almost everything that
  ends up in `backlog.blocked.md` needs a person to do something. What the
  ledger said about it was one line, written the wrong way round: *"needs a
  decision on retention"*, *"permission denied"* — a report on what stopped the
  run, addressed to nobody, for a reader who did not see the run, did not write
  the code, and may not be an engineer at all.

  So a block is a request now. The prompt asks for `reason:` in the imperative
  and addressed to the reader — *"decide how many days of runs to keep, then
  write the number under the task"* — and for everything that does not fit on
  one line to go in a file of its own:

  ```
  ~/.heinzel/blocked/h-0009.md
  ```

  written to a fixed shape: what is needed from you, why it stopped here, the
  steps in order with every command written out in full, what you should see
  when each one worked, and how to hand the task back. The prompt spells out
  what that register means — absolute paths, no `<placeholders>` inside a
  command, no jargon that is not explained in the same sentence, and a
  recommendation whenever there is a choice to make.

  The agent writes its copy at `<workdir>/.heinzel/blocked/<id>.md`, the only
  place it can write, and the merge carries it out beside the ledger *before*
  the marker moves: a `[!]` a person can see and instructions they cannot open
  yet reads as "there is nothing more to say". `finalize_recover` installs them
  too, from the source the intent now records, so a commit finished by a later
  run is not finished without them. The run's copy is kept in `exec-*/blocked/`
  and taken out of the working directory, for the reason the worksheet is: a
  copy left behind is one the next run's block would install as its own.

  **Nothing about the file is recorded on the task line.** The name follows
  from the id, so §8's format is exactly what it was and a stored path cannot
  drift out of step with the line that carries it. Existence is the whole
  record, which is also why a steps file written days later — by a person, or
  by `hzl steps <id>` — is found by the same read.
- `hzl steps` — which blocked tasks have instructions for you and which do not;
  `hzl steps <id>` starts one from a form for a task that has none. It never
  writes over a file that exists: once it is there it belongs to whoever wrote
  it.

### Changed
- `hzl report` prints the steps path under each blocked task, or the command
  that starts one. `--json` gains `steps` on each blocked entry, `null` when no
  file was written.
- `hzl take <id>` pastes the whole steps file into the prompt rather than a
  path — what goes into a session has to carry the instructions with it, or the
  session is left guessing at them the way the run that stopped was.
- `hzl block` says how to start the steps; `hzl unblock` says where the ones it
  just answered still are. Nothing deletes them: a later block on the same task
  writes its own file over it.
- `ledger_blocked_rows` is the human-facing read (five fields, the steps
  resolved); `ledger_blocked` is unchanged at four, so every existing reader of
  it is too.

  21 new assertions; 523 pass.

### Known gap
- The tasks already sitting in `backlog.blocked.md` have no steps files. They
  cannot get them from an unattended run: the ledger is outside every run's
  sandbox by design, and this one could not read it to see what each of them is
  waiting for. `hzl steps` and `hzl take <id>` are the two commands that close
  that gap from an interactive session, one task at a time.

## [0.3.4] - 2026-09-06

### Added
- **The blocked file** (`docs/SPEC.md` §8.0). Sweeping `[x]` out of the backlog
  was half the job, and it left the other half visible: a `[!]` line is not
  work the runner can pick up either. It sat in the queue being read past by
  every run, so the file called the backlog still was not a list of what
  happens next, and the lines that are addressed to a person were mixed in
  with the ones addressed to the machine.

  So the ledger is three files sharing one format, split by whose move it is:
  `backlog.md` is the queue (`[ ]`, `[~]`), `backlog.blocked.md` is what waits
  on a person (`[!]`), `backlog.completed.md` is the record (`[x]`). Both
  derived names come from the backlog's own, never from configuration, for the
  reason the archive already had: every reader has to find the set from the one
  path `state.json` carries. The sweep runs where it ran before — top of a run,
  after recovery, before the worksheet — and appends to the destination before
  rewriting the source, so a crash leaves a task in two files rather than none.

  The blocked file is **live**, and that is its one difference from the
  archive. `[x]` is terminal; `[!]` is not. So its sweep runs both ways: `[!]`
  leaves the backlog, and a line that is no longer `[!]` — `hzl unblock`, or a
  person with an editor — goes back to the backlog at the priority it left
  with. One-way would strand an unblocked task in a file no worksheet is ever
  built from, which is losing work quietly. `hzl block` and `hzl unblock` sweep
  as part of the command, because an unblock you cannot see in `hzl next` until
  the next run is not an unblock.

  Two more questions turn out to be about *the ledger* rather than one of its
  files. `ledger_count` is what "how many are blocked" now asks: counted off
  the backlog alone the answer is zero, and that is the one answer that must
  never be wrong. `ledger_file_of_id` is what every mutation asks first, so
  `hzl done`, `hzl block` and `hzl take` work on a task wherever it is sitting.
  It deliberately looks in the live files only: a mutation that reached the
  archive would rewrite the record, and `hzl done` on an id closed last month
  should say "no such id" rather than close it a second time.

  47 new assertions; 502 pass.

### Changed
- `hzl archive` runs the whole sweep, not just the completions, and says which
  way each task moved. A hand sweep that left the backlog in a state no run
  ever leaves it in was a way to be surprised later.
- `hzl report --json` gains `blocked_file` beside `backlog` and `archive`.
- The `swept` log event now covers all three files.

### Known gap
- The generated permission deny-list still names only `backlog.md`, so
  `backlog.blocked.md` and `backlog.completed.md` are not denied to the agent
  by name (under the default layout they are still inside the denied
  `HEINZEL_HOME` for `Edit`, and outside the sandbox's working directory for
  everything else). Adding them to `etc/heinzel-settings.json.in` was refused
  by the sandbox this run; it is on the backlog.

## [0.3.3] - 2026-09-06

### Added
- **The completed archive, and a morning report** (`docs/SPEC.md` §8.0, §8.0.1).
  The backlog kept every task it ever served. Two things followed, and both
  were felt by the person and not by the machine: the file you open to add a
  todo was mostly history, and the `[!]` lines that are the one part actually
  addressed to you sank into a month of `[x]`. The ledger is the surface a
  human and the runner share, and half of it had stopped being readable.

  So the ledger becomes two files sharing one format. `backlog.md` holds what
  is live — `[ ]`, `[~]`, `[!]` — and every completion is swept into
  `backlog.completed.md` beside it, appended in the order things closed, each
  run of them under the `## P<n>` heading it came from. The path is derived
  from the backlog's own name rather than configured: a second setting is a
  second thing to get wrong, and every reader has to find the pair from the one
  path `state.json` carries.

  The sweep is deliberately *not* part of the ledger transition. It runs at the
  top of a run, after any interrupted commit is recovered and before the
  worksheet is built, so the intent and receipt of §11.4 still digest one file
  at the moment they are written, and a run's own completions survive in the
  backlog long enough for the review gate to revert them. Within a sweep the
  archive is appended to first and the backlog rewritten second: a crash
  between the two leaves a task in both files, which the next sweep repairs by
  dropping it from the backlog. The other order loses the task. Duplication is
  visible and self-healing; loss is neither.

  Two questions turn out to have been about *the ledger* all along, and asking
  only the backlog is now a defect. `ledger_max_id_num` is what allocation
  uses, because an archived id is spent and reissuing it would put two
  different tasks behind one `run:` attribution; `ledger_marker_of_id` is what
  finalize recovery asks, because "no marker here" from a swept backlog would
  re-apply a completion that had already landed.

- **`hzl report`** — what is blocked, and what got done. `hzl status` answers
  whether the machine is doing the right thing; this answers whether anything
  is waiting on *you*, which is a different question and was previously only
  answerable by reading the ledger. Blocked comes first, with the `run:` id
  stripped off the reason — correct in a record, wrong in a sentence somebody
  reads over breakfast — and completions are read across both files, so a task
  swept overnight still appears in the report for the morning it closed.

  It exits **10** when something is blocked and **0** when nothing is, so
  `hzl report --quiet || notify` needs nothing to parse its output, and
  `--json` gives the same content to something that writes the summary for you.
  Scheduling it is left to the operator on purpose: Heinzel installs exactly
  one launchd job, and a tool that quietly grows a second one is a tool you
  stop being able to reason about.

- **`hzl archive`** — the same sweep, on demand, for the first run against an
  existing backlog and for tidying by hand.

## [0.3.2] - 2026-09-03

### Added
- **`docs/HERDR-SPIKE.md` — the Phase 0 spike, written down** (`docs/RUNTIME-
  BACKENDS.md` §20). §20 gates the whole Herdr backend behind a live spike, and
  §22 rates three risks **High** whose entire mitigation is that gate. What §20
  actually gave the person who has to run it was thirteen bullet points. This
  is the same spike as 41 steps in seven stages, each with the command to run,
  what a pass looks like, and — the half that was missing — the fail-closed
  consequence when it is not a pass. Every one of those consequences was
  already a decision somewhere in §§8–19; the spike only finds out which branch
  we are on.

  Steps belong to gates, and gates decide, in three classes. A failed
  **critical** gate (`G-SEC` launch parity, `G-ATTEST` resume attestation,
  `G-VERIFY` verifier isolation) means the unattended backend is not built.
  `G-INDEP` is its own class because §18.2's failure is narrower than "stop":
  a Herdr reviewer sharing the writer's trust domain still runs, it just never
  counts as a `required` review. The remaining thirteen turn a capability off
  and report it `false` in the `CapabilityReport`, which is §8's rule that a
  missing capability is an explicit refusal rather than a quiet change of
  meaning.

  A gate with a step still `todo` is **incomplete**, and incomplete is treated
  as failed. That is the point of a fail-closed gate: not having looked and
  having looked and seen nothing are the same answer.

  Every `herdr` command in it is marked as a sketch. They come from §10 and the
  public 0.8.2 documentation, nothing in this repository has ever run one, and
  a runbook that hands an operator invented flags with a straight face is worse
  than one that admits what it is. Correcting them is part of the spike's
  output.

- **`tools/herdr-spike-probe.sh`** — the bookkeeping half. It knows the step
  list and the gate table, reports what is installed, keeps the results, and
  renders the section that goes into `docs/VERIFICATION.md` with the verdict
  already computed. Its `run` subcommand is a stub that exits 3 and will stay
  one: a security gate a machine can mark `pass` without a human reading the
  screen does not produce evidence, it produces a table that looks like
  evidence. Nothing in it starts a server, launches an agent, or installs
  anything — a test holds it to that with a stand-in `herdr` that answers
  `--version` and writes down anything else it is asked to do.

- **`docs/VERIFICATION.md` — the section the results land in.** §20 says record
  the outcome there with the measured versions, so the destination exists now
  rather than being created by whoever is holding the results at 1am. It also
  says out loud that its own "Phase 0" and the Herdr one are different things
  that share a number.

- **22 assertions holding the document and the script together.** The operator
  works the document while the verdict is computed from the script, so a step
  in one list and not the other is a gate nobody notices is missing. The tests
  check both directions — every step has a procedure, every gate has a step
  that can fail it — and walk all three verdict branches in precedence order.

`herdr` is not installed on this machine and installing it is not a step of the
spike. This release prepares the gate; it does not walk through it.

## [0.3.1] - 2026-09-03

### Removed
- **The global `run.lock`** (`docs/RUNTIME-BACKENDS.md` §14.3; `docs/SPEC.md`
  §7, §11.3). `hzl-run` re-executed itself under `lockf -t 0 -k run.lock` and
  held it from the first gate to the last line — the last thing left spelling
  "another runner is running", and the thing that cannot survive a run
  outliving the process that started it. Nothing replaces it, because three
  narrower statements were already true and each is about the thing it actually
  protects: every ledger and session mutation goes under the short backlog lock
  (0.2.8), the workspace writer lease refuses a second run on the same checkout
  (0.2.1), and `state.json` holds exactly one workdir. A second runner now walks
  as far as the lease and `skip`s there, before it has claimed or spent
  anything. Eight gates became seven.

### Fixed
- **`run.pid` is written after the writer lease, not before it.** It is the file
  `hzl off` kills by. Written at the old gate 2 it was safe only because the
  global lock meant no second runner ever reached it; without that lock a second
  runner would put its own pid in the file and then delete it on the way out,
  leaving the live run running and unreachable by the one command meant to stop
  it. The EXIT trap now removes the file only if this process wrote it *and* it
  still names this process.
- **The blanket `[~]` reset needs the lease.** `backlog_reset_inprogress`
  returns every in-progress marker in the ledger to `[ ]`, whoever set it. In the
  EXIT trap that was unconditional, so a runner that skipped at the lease would
  have released the live run's markers on its way out — the "blanket rollback
  cannot coexist with two runs" of §14.3, reachable for the first time.
- **A workspace with no identity is an abort.** It used to mean "no lease, carry
  on", which was survivable only while the global lock was underneath it: a run
  that cannot name its workspace cannot take the lease that stands for it, and
  would be the second writer nothing had refused.

## [0.3.0] - 2026-09-03

The Phase 2 slice on the local backend, completed: the three fault transitions
that were left over, and the durable cancel intent all three of them needed
(`docs/RUNTIME-BACKENDS.md` §20 Phase 2).

### Added
- **A durable cancel intent, a stop barrier, and a workspace freeze**
  (`lib/cancel.sh`; `docs/RUNTIME-BACKENDS.md` §9.2, §13.2, §14.4, §14.5;
  `docs/SPEC.md` §3.2, §11.5). `hzl off` sent a signal, waited thirty seconds,
  sent a stronger one, printed a summary and returned `0`. Nothing checked that
  the process had gone, nothing recorded that a stop had been *asked for*, and
  what the run was holding was given back by its own EXIT trap — which does not
  run when the run is killed outright. One mechanism closes all three: an intent
  written before anything is signalled, a bounded stop that ends in an
  observation, and a receipt that is the only thing saying the stop happened.
- `cancel.intent.json` / `cancel.receipt.json` in the run store, the same shape
  as the finalize pair and for the same reason: an intent with no receipt beside
  it is the only record that a thing was asked for and may not have happened. An
  intent that already exists is left alone — the first cause is the true one, and
  a later request that overwrote it would turn the record of *why* into the
  record of what happened last.
- `quiesce.json`: the working directory as it stood at the moment the writer was
  confirmed gone. Content and not timestamps — `.git` answers with `HEAD` and its
  porcelain status, everything else with `cksum`, and the build, cache and
  `.heinzel` directories are never walked into. A digest that moved every time a
  test wrote a `.pyc` would report every review as stale.
- `runstore_set_state <run-id> <state>`, which moves the one field and leaves the
  rest of the snapshot as the run wrote it. `hzl off` settles a run it has just
  stopped and does not know that run's task ids or exec directory; a snapshot
  rebuilt from outside would quietly drop what recovery reads.
- `runner_state` gained `cancelling`, `cancelled` and `orphaned`. `cancelling` is
  checked against its pid like the other working states, because a run asked to
  stop is still running until something says otherwise. `runstore_prune` sweeps
  `cancelled` with `ended` and keeps the other two: §14.7 counts a stop in
  progress and a stop that could not be confirmed as active, and a store swept out
  from under an orphan takes with it the only record of what is still holding the
  checkout.

### Changed
- **`hzl off` confirms the process is gone before it releases anything.** A
  durable cancel intent goes down for every active run, then the barrier, and
  only on the strength of an observed stop are that run's task claims, its `[~]`
  markers and its writer lease released. A run killed outright never ran its own
  trap, so this is the only thing that will.
- **A stop that cannot be confirmed is `ORPHANED`.** Not a failure and not a
  success but an unanswered question: the claims, the worksheet and the writer
  lease all stay where they are so no new writer is started into a checkout that
  may still have one, a `HALT` line names the run, and `hzl off` exits non-zero.
  Setting `mode = "normal"` is no longer reported as though it were a stop.
- **`hzl travel` applies the posture whatever the barrier said, and then exits
  with the barrier's status.** A machine going into a bag is closed up even when
  a process will not die — a firewall left open is the worse of the two failures
  — but an unconfirmed stop is not reported as a success either.
- **The runner runs the same barrier against its own engine.** Its EXIT trap used
  to send one `TERM` to the engine tree and release the writer lease in the next
  breath, which is a lease given back while the writer it stands for is still
  editing the checkout. The barrier now comes first and ownership is conditional
  on it. On the ordinary path the engine has already been waited for, so nothing
  about a normal run changes.
- **Verification evidence is not reused after the workspace moved under it**
  (§13.2). The review's verdict describes the tree that was frozen at the
  quiesce; if something changed it while the review was running, the verdict is
  about a state that no longer exists and is discarded in *both* directions —
  not the approval, which is not evidence that what is there now passes, and not
  the rejection, which would revert real work on the strength of a reading of
  something else. The work stands, `review.verdict` is `stale`, and the handover
  says the review did not conclude. A fix pass is a new writer, so the barrier
  and the freeze run again and the re-review is evidence about a new generation.
- An engine that outlives its own watchdog stops the run before the merge rather
  than after it: verification and a ledger commit do not happen on the far side
  of an unconfirmed stop.
- `hzl off` reads the backlog path while the session is still live. Step 1 sets
  the mode to `normal`, and `cur_backlog` answers with the compiled-in default
  from that moment on — so the rollback would have moved no markers, and the
  "blocked, needs you" line has been counting the wrong file, usually no file at
  all.

### Not in this change
- The `FINALIZING` intent does not yet carry the frozen workspace digest. §9.2
  asks it to, but the merge runs *before* the review in this runner, so the
  digest is trivially fresh there and the field would be recorded and never read.
  It belongs with the reordering in Phase 4, not ahead of it.
- There is no automatic way out of `ORPHANED`. §9.2's `ORPHANED -> CANCEL_PENDING`
  retry needs a reconcile loop that outlives the command that found the orphan,
  and that is the controller, later in the phase. `docs/RUNBOOK.md` documents the
  manual path.

### Fixed
- **`hzl status` counts all four markers, not three.** The backlog line read
  `todo / blocked / done` and left `[~]` out, so a task a run had just claimed
  left `todo` and arrived nowhere: three tasks disappeared from a line whose
  numbers a human is meant to be able to add up. `hzl on` prints that block and
  launchd starts the run about a minute later, which is exactly long enough for
  `3 todo` and a `hzl next` that finds nothing to look like the two commands
  disagreeing about the same file. The counts now partition the ledger.
- **`hzl next` says what is in progress instead of "nothing to do".**
  `backlog_next_row` only ever returns a `[ ]`, so an empty answer meant both
  "the ledger is finished" and "a run has claimed everything that was left",
  and it reported the first either way. It now lists the `[~]` tasks with the
  run holding them, read from the claim rather than from the marker's trailing
  comment — claims are the authority and the marker is display
  (`docs/RUNTIME-BACKENDS.md` §13.4). A `[~]` with no claim behind it is the
  residue of a run that died holding one, and is named as such: only the next
  run releases those.

## [0.2.8] - 2026-09-02

### Changed
- **Every ledger and session mutation goes under the short backlog lock**
  (`docs/RUNTIME-BACKENDS.md` §14.3, `docs/SPEC.md` §11.3). `lib/finalize.sh`
  took the lock for the ledger commit and nothing else did: the claim loop, the
  rollbacks, the id allocation, the review's reverts, the follow-up task, every
  `state_update` in the runner, and every one of `hzl on`, `off`, `resume`,
  `set`, `done`, `block` and `unblock` wrote with nothing held at all. A human
  typing `hzl done` while a run merged its worksheet were two writers of one
  file, each reading it, filtering it and renaming the result over the top.
- `with_backlog_lock <cmd…>` is the one spelling, so that "is this mutation
  guarded" is a question about one name rather than about whether a caller
  remembered the right lock and the right timeout. Session state goes under the
  same lock as the ledger and not a second one: a completion counted in
  `state.json` but not in the ledger is the same bug either way round.
- Several mutations that belong together became one transaction rather than one
  lock per line — the claim loop, the cleanup rollback, `hzl done`'s marker and
  its note, the post-merge reset and id allocation, and the review's revert of
  what this run closed. A ledger read between the halves of any of those shows
  something that was never true.
- A refusal is loud and the mutation does not happen. Ten seconds is far longer
  than a ledger write, so a caller that cannot take the lock is not waiting for
  one; a mutation that silently did not happen is how a completion goes missing.
- The runner's `EXIT` trap releases its own backlog lock first. A run killed
  inside a mutation is otherwise holding the lock against itself, and the
  rollback that returns its `[~]` markers would wait out the timeout and then
  not happen.

### Not in this change
- **The global `run.lock` at gate 1 stays**, and the task's remainder is back on
  the backlog. Retiring it is a separate change with a prerequisite this one
  did not touch: `run.pid` is written at gate 2, before the writer lease is
  taken, so a second runner would overwrite it and its own EXIT trap would then
  delete the live run's pid file — the file `hzl off` kills by. The lease
  already refuses a second run on the same checkout, and `state.json` holds one
  workdir, so the ordering is the whole of what is left.

## [0.2.7] - 2026-09-02

### Added
- **Retention for the per-run store** (`docs/RUNTIME-BACKENDS.md` §14.7,
  `docs/SPEC.md` §11.1). `~/.heinzel/runs/` gained a directory per run in 0.2.1
  and no prune to go with it: one run a night, growing for as long as Heinzel is
  installed. `runstore_prune [days]` now runs at the end of a run, beside the log
  prune it was missing a counterpart to, and keeps a store for the same
  `LOG_RETENTION_DAYS` window — the two are halves of one record, and a reader
  holding one without the other is worse off than a reader with neither.
- Three separate things stop a store being swept, each checked on its own. The
  **shape**: only `r-<stamp>-<suffix>`, so a directory a human left under
  `runs/` is not housekeeping's to delete. The **state**: only `ended` — every
  state from `queued` to `merging` is a run that is still working, and
  `interrupted` is a run that stopped without settling, both of which §14.7
  counts as active. The **commit**: a run holding a `finalize.intent.json` with
  no receipt beside it stays whatever its snapshot says, because that intent is
  the only record that a ledger transition may not have happened.
- A store with no readable snapshot is kept as well. A run that cannot be shown
  to have ended has not been shown to have ended — the same rule
  `runstore_runner_state` already applies in the other direction.
- `runstore_is_run_id` — the id shape as a predicate rather than as a comment.
  The path handed to `rm -rf` is rebuilt from the validated id and never taken
  from `find`'s output.

### Not in this change
- An interrupted run's store is now kept indefinitely, which is what §14.7 asks
  for and is also a leak with no upper bound if runs are killed often. Closing
  it needs somewhere for such a run to *go* — the reconcile that reads a stale
  store, decides the run is over and settles it — and that is the recovery work
  later in Phase 2, not a retention policy.
- `etc/heinzel.conf.example` still describes `LOG_RETENTION_DAYS` as the log
  window only. The file is outside this run's write permissions; `docs/SPEC.md`
  §13 carries the corrected description.

## [0.2.6] - 2026-09-02

### Changed
- **The worksheet is rebuilt from the claims a run holds** (`docs/SPEC.md` §8.1,
  §11.2; `docs/RUNTIME-BACKENDS.md` §13.4). The worksheet is written from the
  ledger before any claim exists, so a task another run got to first was still
  on it: no `[~]`, a line in the runner log, and otherwise indistinguishable
  from work the agent was invited to do. Only the global `run.lock` and the
  reconcile in front of it made that path unreachable, and both are on their way
  out. Once the claims are taken the worksheet is now written again from the ids
  this run actually holds, and `worksheet-ids.txt` — the scope the merge checks
  against — is replaced with the same set, so the two cannot disagree.
- The per-run task budget in the prompt is lowered to the number of tasks
  claimed. An agent told it may close three tasks, on a worksheet holding two,
  is being told something untrue by its own prompt.
- A run that could claim none of its tasks `skip`s before the engine is called,
  rather than sending an agent a worksheet it may not touch a line of.

### Added
- `worksheet_render <ledger> <ids-file> <out>` — the writing of a worksheet,
  from an explicit list of ids rather than from a budget. `worksheet_write` is
  now that function over the first *n* todos, so there is one renderer and not
  two. The render consults the id list and not the ledger's marker: by the time
  a run rebuilds, its own tasks read `[~]`, and what the agent is handed is
  always a todo.
- `exec-*/claimed-ids.txt`, alongside `worksheet-ids.txt`: what the run asked
  for and what it got, kept apart so a refusal is legible after the fact.

## [0.2.5] - 2026-09-02

### Added
- **A run does not settle by being killed** (`docs/RUNTIME-BACKENDS.md` §9.2,
  §21.1). The snapshot is written by the run it describes, so the last one a
  killed run managed to write says it was working — and it was, right until it
  was not. A reader that took that at face value would find a run that has been
  `running` since Tuesday, and a recovery that trusted it would wait for a
  process that is not there. The snapshot now carries the `pid` that wrote it,
  and `runstore_runner_state` checks a working state against that process:
  gone, or no pid to check at all, reads `interrupted`. A run that cannot be
  shown to be working is not working.
- A terminal state is returned as it stands. A run that finished is finished,
  and its process being gone afterwards is what is supposed to happen — the
  check is only ever applied to `queued`, `running` and `merging`.
- The runner's EXIT trap writes an `interrupted` snapshot as well as the
  `run.interrupted` event, so `workflow.json` — which is what recovery reads —
  says what happened rather than what was happening.

### Not in this change
- This is the first of the four fault transitions the task names. The **cancel
  barrier** (`hzl off` confirming the process is gone before it releases claims),
  **`ORPHANED`** (a stop that cannot be confirmed keeps ownership rather than
  releasing it) and **stale evidence** (verification not reused after the
  workspace digest moved under it) are still to write, and they are what
  completes the Phase 2 slice on the local backend — so this is a patch release
  and not the minor one. They need `hzl off` and the runner to gain a cancel
  intent they do not have yet; asserting them today would be asserting about
  behaviour that is not there.

## [0.2.4] - 2026-09-02

### Added
- **`lib/finalize.sh`: the ledger commit is four steps and a crash boundary**
  (`docs/RUNTIME-BACKENDS.md` §13.4, §9.2). The merge was one motion — parse a
  line, apply it, parse the next — so a process killed in the middle left half a
  merge and nothing saying so. Now: the worksheet is **parsed** into candidates
  and **checked** for scope while nothing is written; an **intent** naming them,
  digesting the worksheet they came from and the ledger they are about to be
  applied to, is saved *before* the ledger is touched; the **transition** is
  applied once under the backlog lock; and a **receipt** digesting the ledger it
  produced is written after. The transition itself is the same
  `worksheet_merge` it always was — separating the parse from the commit is not
  a reason to have a second thing that moves markers.
- **Recovery, exactly once, at both crash points.** An intent with no receipt is
  a run that stopped inside the commit, and the intent's digest of the ledger it
  was about to change says where: a ledger that still digests to it was never
  written; one that does not was written at least in part. On the first path the
  whole intent is applied; on the second every id is checked and only the ones
  that did not land are. A marker is a setting, not an increment, so re-applying
  one is harmless — counting it twice is not, and a run with a receipt is never
  recovered.
- **`tasks_done_total` moves with the receipt.** A run that stopped between the
  intent and the receipt stopped long before its own counter, so its completion
  was in the ledger and missing from the total. Recovery counts it, once, and
  records how many in the receipt.
- The runner finishes any interrupted commit for its own backlog on the way in —
  after it holds the writer lease, before it writes the ledger itself — and asks
  gate 4 again afterwards, because a completion recovered there is spent budget.
- The backlog lock has its first caller: the transition is applied under it.

### Changed
- New tasks are the one part of a commit that is not idempotent, since inserting
  a line is not a setting. On the moved-ledger recovery path one is inserted only
  if no line with exactly that text is in the ledger already; the first
  application is unchanged, so a run that completes normally behaves exactly as
  it did.
- A ledger that moved between the intent and the lock is recorded
  (`ledger_moved`) and applied anyway. The check that protects the ledger is
  scope, enforced line by line; refusing to record a finished run's work because
  somebody closed an unrelated task by hand would lose the work to protect the
  record of it.

### Not in this change
- A run that survives still counts its own completions after the review gate,
  which is where they have to be counted — the gate can revert them. So a crash
  between the receipt and that counter still loses the count. Closing that
  window means moving the review gate in front of the commit, which is the open
  question already recorded in `docs/SPEC.md` §15.
- Without a run store there is nowhere to put an intent, so the merge runs on
  its own and the runner logs that it left no receipt. The store is not
  load-bearing, and a run must not lose its work because its own bookkeeping
  failed.

## [0.2.3] - 2026-09-02

### Added
- **`lib/locks.sh`: the one global lock comes apart into three**
  (`docs/RUNTIME-BACKENDS.md` §14.3). `run.lock` has been saying three things at
  once — *another runner is running*, *the ledger is being written*, and *this
  checkout has a writer*. That is fine while there is exactly one synchronous
  run; it stops being fine as soon as a run outlives the process that started
  it. So: a **backlog lock** held around one ledger mutation and released
  immediately, a **per-run lock** so that one run has one advancer, and a
  **writer lease** per `workspace_identity`, durable and carrying a fencing
  generation.
- **The writer lease, in the runner.** Taken between gates 7 and 8, before
  anything is written; released by the EXIT trap, last and after the engine has
  been signalled to stop — a lease released while its writer is still running
  would let the next run into a working directory that has one. A workspace held
  by a live run is a `skip` naming the run that holds it.
- **A lease left by a dead run is recoverable, and a lease held by a live one is
  not.** Recovery is by exactly one rule — the holding pid is not alive — and it
  is a deliberate call that names the run it took the lease from, never a side
  effect of somebody wanting the lease. The runner does it on the way in, the
  way it already recovers stale claims. The test kills a real holding process
  and reaps it first, because a zombie still answers `kill -0`.
- **A fencing generation that only goes up**, per workspace rather than per
  lease, so it survives the lease being released or broken. A counter that reset
  would hand the run taking over a number that had already been issued, and the
  two holders would be indistinguishable. Retaking your own lease moves it on; a
  renewal is a heartbeat and does not, because a renewal that bumped it would
  fence the holder out of its own lease.

### Changed
- Locks and leases are created by an atomic create — the record written whole
  into a temp file beside the target, then `ln`, which fails if the target
  exists — and never by an overwrite. There is no moment when a lock exists
  without naming its holder. This is deliberately not `lockf(1)`: lockf holds
  its lock for the lifetime of a command it *execs*, and every section being
  guarded here is a shell function in the calling process. Gate 1 is still
  lockf and is unchanged.

### Not in this change
- **Gate 1 stays.** The backlog lock has no callers yet: putting every ledger
  and session mutation in `hzl-run` and `hzl` under it is what lets the global
  `run.lock` go, and that is the next task. Until then nothing is less protected
  than it was — the global lock still covers the whole run, and the lease and
  the per-run lock are held underneath it.
- The runner's own lease wiring is checked by `bash -n` and by the unit tests of
  the primitives it calls. Running `bin/hzl-run` end to end against a temporary
  `HEINZEL_HOME` was refused by the sandbox this run worked under, so the
  ordering — reclaim, acquire, release from the trap — is read and not observed.

## [0.2.2] - 2026-09-02

### Added
- **`lib/claims.sh`: the record of who is working on what moves out of the
  ledger** (`docs/RUNTIME-BACKENDS.md` §13.4). The `[~]` marker had been doing
  two jobs — telling a human what is being worked on, and *being the record of
  it* — and it cannot do the second: it lives inside the agent's write radius,
  it carries no run id anything checks, and rolling it back was all-or-nothing.
  A claim now lives in `~/.heinzel/claims/<workspace-hash>/<task-id>.json`,
  which the agent is denied, and names the workspace, the task, the run holding
  it and a fencing generation. The marker stays, as its display.
- **Every operation is scoped to one run id.** Acquiring refuses a task another
  run holds; releasing refuses a claim this run does not hold; reconciling
  releases *exactly* the run it was given and reports how many. This is the
  difference the blanket `[~]` pass could not express, and the reason a release
  is now attributable to a run.
- **The kill case, with assertions.** A run killed mid-run leaves its claims
  standing — nothing it ran could have tidied them — and the next run releases
  them one run id at a time. The test holds three runs' claims in two
  workspaces, reconciles one dead run, and checks that its two claims went and
  that the other run's claim and the other workspace are exactly where they
  were.
- A workspace identity is `<short hostname>:<canonical absolute path>`, so two
  spellings of one directory are one workspace — a workdir reached through a
  symlink would otherwise get its own claims directory and the two would never
  see each other's claims.

### Changed
- The runner claims each worksheet id before the engine starts, and its
  rollbacks are run-scoped: on the way in it releases the claims of runs that
  have stopped, one at a time; after the merge and in the EXIT trap it releases
  its own and nobody else's. A rollback returns only `[~]` to `[ ]` — a task the
  merge marked `[x]` or `[!]` keeps that marker, because the work happened and
  releasing a claim is not a reason to undo it.
- `backlog_reset_inprogress`, the blanket pass, is unchanged and still called.
  It is the legacy path, and it is what puts back a `[~]` that no claim ever
  covered — one written by hand, or by a build older than the claims directory.

### Not in this change
- A task whose claim is refused keeps its place on the worksheet. It gets no
  `[~]`, because displaying a claim this run does not hold would be a false
  statement about the ledger, and the refusal is logged — but the id is still in
  front of the agent. Removing it means rebuilding the worksheet after the
  claims are taken, which belongs with the workflow state machine. Under the
  global run lock, and after the reconcile that runs before it, there is no
  path that reaches it today.

## [0.2.1] - 2026-09-02

### Added
- **`lib/runstore.sh`: one durable directory per run under `HEINZEL_HOME`**
  (`docs/RUNTIME-BACKENDS.md` §14.1). `workflow.json` is the recovery snapshot —
  what is true now — and `events.jsonl` is the append-only trail of what
  happened. Two files because they answer two questions: a snapshot that grew a
  history would eventually be too big to rewrite atomically, and a log that had
  to be rewritten to answer "where is this run" would stop being an audit trail
  the first time it was compacted. `HEINZEL_HOME` is the point of the location:
  the agent is denied that path wholesale, so a record kept there is one the
  thing being recorded cannot edit.
- **Sortable run ids** (§14.2): `r-20260902T031500-k7w3m2`. Fixed-width
  timestamp first, so plain string order is chronological order; a random
  suffix, because two runs can begin in the same second and a store keyed by
  the second alone would put the later one on top of the earlier one; and a
  shape the ledger's `<letters>-<digits>` id allocator cannot match, so a run
  id can never be counted as the highest task number ever issued. There is an
  assertion for exactly that.
- The runner writes the store alongside everything it already wrote. The
  second-precision `RUN_ID` is unchanged and still what the ledger's `run:`
  provenance and `runs.jsonl` are written in; the snapshot records it as
  `legacy_run_id`. The exec directory contains what it contained.
- A `run.interrupted` event from the EXIT trap. A run killed at the deadline or
  by `hzl off` now leaves a snapshot naming the task ids it was holding and a
  line saying nobody finished — which is what makes a stopped run recognisable
  as one afterwards, rather than as a run that ended quietly.
- Thirty assertions, against a temp `HEINZEL_HOME`. The one the task was for:
  a snapshot that does not parse is refused *before* anything is replaced, so
  with no snapshot yet the target file does not exist at all rather than
  existing and being broken, and with a snapshot already there the old one is
  byte-identical afterwards. The temp file is made in the same directory as the
  target — which is what makes the rename atomic rather than a copy — and none
  survives either path.

### Changed
- `runner_state` in the snapshot is lowercase (`queued`, `running`, `merging`,
  `ended`) and `workflow_state` / `workflow_outcome` are present and null. The
  uppercase states of §9.2 belong to a state machine this runner is not yet, and
  a legacy run labelling itself `RUNNING` would be claiming to be one. The two
  reserved fields mean the shape does not change when that machine fills them.

### Not in this change
- Nothing reads the store to decide anything. A run whose store cannot be
  written is a run that still happens, and says so with a `skip` line in the
  runner log — a run must not fail because its own bookkeeping did.
- Retention (§14.7). The store grows without bound today; the log tree's
  14-day prune has no counterpart here yet, and adding a delete was left as its
  own task rather than folded into the one that created the directories.

## [0.2.0] - 2026-09-02

Phase 1 of `docs/RUNTIME-BACKENDS.md` is complete: the characterization tests,
the Agent Driver, the LocalRuntime behind a registry, and now the schema
versions that let a second backend write records these ones can still read.

### Added
- **`schema_version` on the three records that outlive a run** — `state.json`,
  each attempt's `result.json`, and every row of `runs.jsonl` (§13.7, §14.1).
  All three are at 2, and every version so far only adds fields: a reader that
  knows only version 1 finds every field it knew, in the same place, meaning
  the same thing.
- **A file with no version field is version 1, and is read where it lies.** The
  half of "additive" that fails silently is the reading half, so it is the half
  with assertions on it: a v1 `state.json` and a v1 `result.json` are read as
  fixtures and compared byte for byte afterwards. Nothing migrates a record it
  only read. `hzl status` and `hzl doctor` report the version they found and
  leave the file alone — a status command that repaired what it printed would
  make a rollback to the previous build unreadable, and nothing would say so
  until the rollback.
- `state.json` gains `runtime_backend`, recorded by `hzl on` from
  `HEINZEL_RUNTIME`. A key the registry does not know now fails `hzl on`
  outright, rather than being written into a session whose every run then
  aborts at 03:00 with nobody awake to read it. Absent means `local`.
- `result.json` gains `backend`, `runtime_state`, `native_exit_code` and
  `attempt_outcome`. `native_exit_code` is null when the watchdog ended the run:
  124, 137 and 125 are Heinzel's numbers, not the command's, and a record that
  reported one as the engine's own status — or invented a 0 — would be a
  fabrication (§13.7). A dry run says `NOT_STARTED` and reports no process.
- **`attempt_outcome`, which cannot be read as a claim about the work.**
  `verdict: ok` has always meant "the attempt ran and its output was collected",
  but at a glance it reads like a statement that the task was done, which no
  runtime is in a position to make — the observation vocabulary has no
  `success` in it for the same reason (§8.3). The same judgement is now also
  written down as `COLLECTED` / `TIMED_OUT` / `AUTH_FAILED` / `FAILED` /
  `UNKNOWN`, none of which mean the work was right. `workflow_outcome`, the
  field that does judge that, is Phase 4's and is a separate field.
- `engine_result_schema_version`, `engine_result_backend` and
  `engine_result_attempt_outcome`: readers that accept a `result.json` of
  either schema, so a v1 record in the log tree stays readable. An old record
  with no outcome field has its outcome derived from the verdict it does have.
- Thirty-two assertions on all of it, including that a version field which is
  not a number reads as 1 rather than reaching shell arithmetic, and that a
  version *higher* than this build's is read for the fields this build knows
  rather than refused.

### Changed
- `engine_normalize_result` takes the backend as an optional fourth argument.
  It is the one fact that cannot be read back out of the launch or the collected
  record — it is the caller's choice of where to run — and it defaults to
  `local` for the three-argument form.
- `HEINZEL_VERSION` is 0.2.0: the minor bump marks the completed phase, not the
  size of this change. The 113 assertions from 0.1.6 pass unmodified, which is
  the claim that v2 is additive stated as a test result rather than as a
  sentence.

### Not in this change
- `work_session_id` (§14.1) and `workflow_outcome` (§9.3, §13.7) are named in
  the design and are deliberately absent here. Both are Phase 2 and Phase 4
  fields with no consumer yet, and a field nothing reads is a field nothing
  keeps true.

## [0.1.6] - 2026-09-02

### Added
- **`lib/runtimes.sh`, the runtime backend registry**, and
  **`lib/runtimes/local.sh`**, which owns process start, the watchdog and
  output collection. A backend is now a key, a file and a registration. Nothing
  outside `lib/runtimes/` branches on the key: dispatch is by constructed
  function name, so the second backend is an addition and not an edit to the
  code that dispatches to it (`docs/RUNTIME-BACKENDS.md` §8.4).
- `engine_run` delegates to the registry. `HEINZEL_RUNTIME` names the backend
  and defaults to `local`; a name the registry does not know fails the run
  rather than quietly running the job here. There is no fallback to local,
  because a run that was asked to happen somewhere else and happened here is
  not the run that was asked for.
- `run.json`: where to run, how long to allow, and where the three streams go.
  It is a separate file from `launch.json` because they answer separate
  questions — what to start, and under what conditions — and a backend that is
  not this shell needs both without needing an output directory layout.
- Fourteen assertions on the registry: an unregistered backend is refused,
  registering twice is idempotent, a key that is not a plain name is refused,
  the exit status and the collected record come back from the backend, the temp
  file it renamed from is gone, and a launch environment the local backend
  cannot carry is refused rather than dropped.

### Changed
- `lib/engines.sh` is the Agent Driver and nothing else now: it knows engines
  and no longer knows how to start a process. `bin/hzl-run` and `bin/hzl-review`
  source `lib/runtimes.sh` alongside the libraries they already sourced.
- Behaviour, exit codes and `result.json` are unchanged, which is what the
  0.1.4 characterization tests are there to say: all 99 of them pass
  unmodified across the move.

## [0.1.5] - 2026-09-02

### Changed
- **`lib/engines.sh` is now an Agent Driver and a supervisor with a line
  between them** (`docs/RUNTIME-BACKENDS.md` §7). Above the line is everything
  Heinzel knows about agent CLIs — subcommands, flag order, which tools are
  withheld, which sandbox is asked for — and it knows nothing about processes.
  Below it is code that starts what a launch spec names, under the watchdog,
  and knows nothing about engines. `engine_run` is unchanged from the outside:
  same arguments, same exit status, same `result.json`. `bin/hzl-run` and
  `bin/hzl-review` did not have to change.
- **The launch is structured data, not a command string.** `launch.json` holds
  an `executable`, an `argv` array and an `env` object, and supervision restores
  the argv NUL-delimited through process substitution — never split on newlines,
  never rebuilt with `eval`. NUL is the separator because it is the one byte an
  argument cannot contain. This is what makes a runtime that is not this shell
  possible at all (§8.4).
- `engine_run` now also leaves `launch.json` and `collected.json` in the output
  directory. The runner reads neither; they are the seam a backend plugs into.
  `docs/SPEC.md` §9 records them.

### Added
- `engine_build_launch` and `engine_normalize_result` as named functions, and
  `security_profile` recorded in the launch spec — named, not enforced, so that
  a later phase's launch attestation has something to compare against.
- Six assertions on the launch spec itself: the shape of the record, that
  `argv` is an array rather than a string, that it does not repeat the
  executable, and that a multi-line prompt is still one element. An io mode the
  driver cannot build is refused rather than quietly served as batch.
- The 92 characterization tests from 0.1.4 were not touched: they pass
  unmodified against the split. That was the point of writing them first.

## [0.1.4] - 2026-09-02

### Added
- **Characterization tests for the engine layer**, the safety net Phase 1 of
  `docs/RUNTIME-BACKENDS.md` asks for before `lib/engines.sh` is split into an
  Agent Driver and a LocalRuntime. They pin what the code does today, so the
  extraction can be judged by whether anything observable moved.
- The launch is compared **argument for argument**, as a NUL-separated byte
  stream rather than a line per argument: the reviewer's `--json-schema` is a
  whole file, and a comparison that split on newlines would stay green while
  the real argv fell apart into thirty arguments. Covered: `claude` executor
  and reviewer, `codex` executor and reviewer, `ignore_user_config`, a budget
  cap, and a prompt whose trailing newline `$(cat ...)` strips before the
  engine sees it.
- `hzl_timeout`: exit status passed through, 124 on the wall clock, 137 for a
  child that ignores `TERM`, 125 for a missing command or a non-numeric
  timeout, and — the reason the child is never wrapped in a subshell — a
  grandchild that dies with the process group instead of surviving and billing.
- `engine_run` against a fake engine: exit codes propagated to the caller, and
  `result.json` normalised for `ok`, `error`, `auth` and `timeout`, including
  the two cases that are easy to lose in a refactor — `claude` reporting a
  failed run inside a zero exit, and an unparseable body degrading to empty
  fields rather than to a broken result.
- `engine_is_auth_error` per engine: a `codex` MCP transport 401 is not an auth
  failure, not being logged in is, and a run that exited 0 is never one.

### Changed
- The fake `claude` / `codex` the tests use is a shell script on a temporary
  `PATH`, dropped there by the suite. No real engine is started, so the suite
  is still free and still works offline. `--live` stays refused with exit 2:
  its message now says the engine tests use a fake engine, rather than that no
  engine test exists.

## [0.1.3] - 2026-09-01

### Added
- **`tests/test.sh`, the first regression suite**, covering the two functions
  the whole run loop is built on. `worksheet_write`: only this run's ids reach
  the worksheet, continuation lines come with them, priority headings come with
  them, fenced examples and already-closed tasks do not, and a task beyond the
  run's budget is left in the ledger. `worksheet_merge`: `[x]` closes with
  `done:` and the run id, `[!]` records the reason taken from the trailing
  comment, an untouched task goes back to `[ ]` with its metadata cleared, an
  id-less line becomes a new task at the end of its own priority section, and an
  id the runner never put on the worksheet is counted as ignored rather than
  applied. Also `backlog_assign_ids` skipping fenced blocks, and task text
  carrying a backslash or a percent sign surviving a merge byte for byte.
- The four merge counts are asserted as numbers, not just via the resulting
  file. `bin/hzl-run` splits `worksheet_merge`'s output with `cut -d' '` and
  logs the fourth field as `N worksheet line(s) ignored`, so the shape of that
  line is a contract between two files and is now tested as one.
- The regression from `docs/DESIGN.md` §6.3 has a test that fails without the
  fix: reverting `worksheet_merge` to `IFS=<tab> read` turns 6 assertions red,
  including the ignored count that made the original bug look plausible.
  Removing the fence skip from `backlog_assign_ids`, dropping the worksheet
  budget, or accepting an out-of-scope id each turn assertions red too — the
  suite was checked by breaking the code, not only by running it green.

### Changed
- `tests/test.sh` redirects `HEINZEL_HOME` to a temp directory *before* sourcing
  `lib/common.sh`, since every state path is derived at source time, then reads
  `HEINZEL_HOME` and `STATE_FILE` back and refuses to run a single assertion if
  either resolved outside that directory.
- `tests/test.sh --live` is refused with exit 2 instead of silently running the
  offline suite. `CONTRIBUTING.md` documents the flag as exercising the reviewer
  engine; nothing here calls an engine yet, and a contributor who ran it and saw
  green would believe otherwise. `CONTRIBUTING.md` now says so too.

## [0.1.2] - 2026-09-01

### Fixed
- **`SECURITY.md` overstated the review pipeline as a defence for the
  self-editing carve-out.** It is not one, and the reason is ordering: the
  release ritual pushes inside the executor's own run, and `bin/hzl-run`
  applies the review gate afterwards. The reviewer therefore sees the work
  after it has reached `origin`, and a `reject` reverts the backlog line
  without reverting the commit, un-pushing it, or moving the tag. Review gates
  the ledger, not the remote. Recorded as an open design question in
  `docs/SPEC.md` §15 with the three ways out, rather than patched in a hurry;
  `SECURITY.md` and `docs/DESIGN.md` §4.8 now say plainly what turning review
  on does and does not buy.

## [0.1.1] - 2026-09-01

### Changed
- **Heinzel may now improve itself.** The working directory is the repository,
  and `Edit(<repo>/**)` is allowed. The blanket denial that stood before would
  have denied the point. `etc/` stays denied: nothing in it is code, and every
  file in it is a way to widen the boundary rather than do the task — the
  generated deny list and its template, the budget and schedule, the plist, and
  the `sudoers-*` / `pf` templates a human installs with privilege.
  `hzl doctor` fails if the working directory is the repository and that
  carve-out is missing. See `SECURITY.md` and `docs/DESIGN.md` §4.8.
- Measured while doing it, and recorded in `docs/DESIGN.md` §4.5: a path
  `Edit(...)` **denial is enforced against a subprocess**, not only against
  Claude's own file tools. `python3` through Bash wrote to the repository root
  under the same settings file and was refused in `etc/`. `allow` rules remain
  one-layer-only; the asymmetry is now stated rather than assumed.

## [0.1.0] - 2026-09-01

First tagged baseline. From here on, every completed backlog task ships the
same night: changelog entry, version bump, commit, push, annotated tag - the
ritual is `docs/RELEASING.md`.

### Added
- **`docs/RUNTIME-BACKENDS.md`** - the pluggable runtime/backend and Herdr
  integration design, adopted as the working plan. Its §20 phases are the
  source of the nightly backlog: Phase 1 (characterization tests, Agent
  Driver / LocalRuntime extraction) and Phase 2 (durable workflow on the
  local backend) first; Phase 0 (live Herdr spike) stays human-run.
- **`docs/RELEASING.md`** - versioning and the per-task release ritual.
  `HEINZEL_VERSION` in `lib/common.sh` is the source of truth; patch per
  task, minor when a task completes a design phase.
- **The unattended agent may `git push origin`.** A deliberate, documented
  carve-out (SECURITY.md): the sandbox network allowlist opens `github.com`
  only, force/mirror/delete pushes stay denied, and the prompt permits
  exactly `git push origin` of the working repository as the ritual's final
  step. Measured 2026-09-01: the push authenticates and succeeds inside the
  sandbox; the keychain write-back warning `failed to store: 100001` is
  cosmetic.

### Changed
- **The unattended agent no longer sees the backlog.** Each run gets a
  *worksheet* — that run's `[ ]` tasks, their ids and notes, nothing else — and
  the runner merges the markers back into the ledger afterwards by id. The
  runner is now the ledger's only writer, and the set of ids a run may close is
  checked against a list kept out of the agent's reach, so "do not touch other
  runs' lines" is enforced rather than requested. Timestamps and `run:` fields
  are written by the merge; the agent has no clock and never needed one.
  See `docs/SPEC.md` §8.1 and `docs/DESIGN.md` §4.7. Verified end to end against
  a real engine on 2026-08-30 (run `20260830-215948`), including that a
  two-task backlog under a one-task budget leaves the second task untouched.
- The backlog belongs **outside** the working directory now, and is denied to
  the agent by name in `etc/heinzel-settings.json`. `hzl doctor` warns when the
  two overlap and reports a deny list that has gone stale against the
  configured backlog. Moving the backlog requires `hzl install` again.
- `hzl install` requires `DEFAULT_BACKLOG` to be set, because the generated
  permission file names it. An empty value would have rendered as a rule about
  the whole filesystem.

### Fixed
- **`hzl doctor` reported `claude` as not on PATH on a machine where the
  unattended run finds it fine.** `bin/hzl-run` appends `/usr/local/bin`,
  `/opt/homebrew/bin` and `~/.local/bin` to `PATH`; `bin/hzl` did not, and the
  engine usually lives in `~/.local/bin`. So the CLI and the runner disagreed
  about which engines existed, and the CLI was the one that was wrong. Both
  harden `PATH` identically now, and when the engine really is absent, `doctor`
  prints the `PATH` it searched instead of only asserting the conclusion.
- `install.sh` tested PATH membership with an unnormalised string compare, so a
  `~/.local/bin/` entry carrying a trailing slash — the ordinary shape, and the
  reason `which` prints `/Users/you/bin//hzl` — was reported as not on PATH.
  The note is also actionable now: it says what to do, and that `hzl` finds its
  own libraries through a symlink placed anywhere.
- **The LaunchAgent plist baked in the `PATH` of whichever shell ran
  `hzl install`.** A generated file that depends on ambient environment is not
  reproducible: installing from one shell and checking from another made
  `hzl doctor` report *"the installed plist has drifted from HEINZEL_HOURS"*
  when the schedule had not moved at all. The plist now carries a fixed base
  `PATH` — the runner appends its own three directories regardless — and the
  drift message says the file differs rather than naming a key it did not
  check, and prints the diff.
- Rows of `backlog_scan` output were taken apart with `IFS=<tab> read`, which
  collapses consecutive tabs — tab is an IFS whitespace character. An empty
  field shifted every later field left, so a task the agent split off arrived
  with its text in the id column and was silently discarded as out of scope.
  Rows go through `cut -f` now.
- **An edited `DEFAULT_WORKDIR` / `DEFAULT_BACKLOG` was ignored until the next
  `hzl on`.** `state.json` keeps a finished session's paths and `hzl` read them
  unconditionally, so the configuration file was consulted only when the key was
  absent — which it never is after the first session. `hzl doctor` reported the
  old paths and, worse, `hzl install` baked them into the agent's permission
  file, leaving the deny list naming a backlog nobody used. `hzl` now reads them
  through `cur_workdir` / `cur_backlog`, which prefer `state.json` only while a
  session is live. The runner is unchanged and still reads `state.json`
  directly: it only runs inside a session, where `hzl on --backlog X` must hold.
- `hzl on` refuses, and `hzl doctor` reports, a working directory inside
  `~/.heinzel`. That directory is denied to the agent wholesale, so such a run
  can write nothing — and it fails looking like an agent that could not do the
  task rather than a path that was wrong.
- `hzl install` and the runner's gate 7 now reject a permission file that still
  contains `__NAME__` placeholders. Such a file is valid JSON, so it passed
  every check there was, and every rule carrying a placeholder matched nothing —
  accepted and then ignored, the failure mode `docs/DESIGN.md` §4.6 is about.
- `backlog_assign_ids` was not fence-aware, though `backlog_scan` is. It stamped
  an id onto the worked example in the backlog template's own header — directly
  under the line saying ids are never written by hand — and consumed a number
  doing it. Fenced blocks are documentation to both functions now.

### Added
- `docs/DESIGN.md` — design notes for the merge of `macmode` (posture) and the
  `kobito` specification (unattended session), phase 0 of the implementation plan.
- Repository skeleton, Apache-2.0 license, CI stub.

Nothing is implemented yet. See `docs/DESIGN.md` §9 for the phase plan.
