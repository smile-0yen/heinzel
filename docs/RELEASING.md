# Releasing

Every improvement leaves the machine the same night it is made: documented,
committed, pushed, tagged. This is the ritual, in order. It is written for the
unattended agent as much as for a human, so it is exact.

## The version

`HEINZEL_VERSION` in `lib/common.sh` is the single source of truth. Semantic
versioning, pre-1.0:

- **patch** (`0.1.0 -> 0.1.1`): one completed backlog task.
- **minor** (`0.1.4 -> 0.2.0`): the task that completes a design phase of
  `docs/RUNTIME-BACKENDS.md` (the backlog task text says when it does), **or**
  any task that breaks something outside this repository: a command removed or
  renamed, a value in `hzl status --json` changed, a `state.json` schema an
  older build cannot read, a configuration key that stops being read, a
  documented behaviour withdrawn. Pre-1.0 the minor digit is where breaking
  changes go, and **the patch digit must never carry one** — a person reading
  `0.3.24 -> 0.3.25` is entitled to assume their scripts still run. If one task
  does both, it is still one minor bump.
- **1.0.0 is not a size, it is a promise** about the CLI, `status --json` and
  the state schema. It waits until `docs/SPEC.md` §15 has no unverified row and
  the command surface has survived real engine runs without moving. Do not
  reach for it because a change felt large.
- never re-tag, never move a tag, never `--force` anything.

## The ritual, per completed task

1. **Document.** Add an entry under a new `## [X.Y.Z] - YYYY-MM-DD` heading in
   `CHANGELOG.md` saying what changed and why (the date is in your prompt's
   run id if you have no clock: `run:YYYYMMDD-HHMMSS` is local time). Update
   whichever of `docs/SPEC.md`, `docs/DESIGN.md`, `docs/RUNBOOK.md`,
   `SECURITY.md` the change touches - code and SPEC must not disagree.
2. **Bump.** Set `HEINZEL_VERSION` in `lib/common.sh` to the new version.
3. **Verify.** `tests/test.sh` passes (once it exists); `bash -n` every shell
   file you touched.
4. **Commit.** One commit for the task, message in the imperative, body saying
   why. Do not commit `.heinzel/`, `etc/*.conf`, or generated files - the
   `.gitignore` already excludes them; use `git add` on the files you changed,
   not `git add -A` blindly.
5. **Push.** `git push origin HEAD`.
6. **Tag.** Only after the push succeeded: `git tag -a vX.Y.Z -m "<one line>"`
   then `git push origin vX.Y.Z`.

If the push is refused (sandbox, network, auth), keep the commit and the tag
local, record `push pending` in the run handover, and move on. The work is
done; the push is retried by the next run's ritual or by a human in the
morning - `git push origin HEAD --follow-tags` catches everything up.

## What a release is not

- No GitHub releases, no PRs, no other remotes: `origin` only.
- No version bump without a changelog entry, and vice versa.
- A blocked (`[!]`) task gets no version bump - nothing shipped.
