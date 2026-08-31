# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
