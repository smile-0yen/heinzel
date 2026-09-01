# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
