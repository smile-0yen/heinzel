# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
