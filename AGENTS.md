<!-- SPDX-License-Identifier: Apache-2.0 -->
# Working in Heinzel

Code is the source of truth. `docs/SPEC.md` defines observable contracts; update it and add a regression test when behavior changes. `docs/DESIGN.md` explains decisions, `docs/RUNBOOK.md` covers operation, and `docs/VERIFICATION.md` lists manual checks. Historical status and version text may lag the code.

## Find the owner

- CLI, session transitions, schedule, installation: `bin/hzl`; shared config, state and backlog parsing: `lib/common.sh`; posture: `lib/posture.sh`.
- Unattended workflow and review gate: `bin/hzl-run`; review and snapshots: `bin/hzl-review`, `bin/hzl-changeset`; prompts: `prompts/`.
- Engine arguments and result normalization: `lib/engines.sh`, `go/`; process control: `go/`, `lib/watchdog.sh`; runtime dispatch: `lib/runtimes.sh`, `lib/runtimes/local.sh`.
- Task claims and one-writer safety: `lib/claims.sh`, `lib/locks.sh`; ledger commit and recovery: `lib/finalize.sh`; stop and freeze: `lib/cancel.sh`; durable run data: `lib/runstore.sh`.
- Web dashboard: `lib/web/`; shell tests: `tests/test.sh`; Go tests: `go/*_test.go`.

For auth/verdict changes, start at `lib/engines.sh`, `go/verdict.go`, `go/verdict_test.go`, then `docs/SPEC.md` §9. For task completion races, trace `bin/hzl-run` through claims, locks and finalize, then `docs/SPEC.md` §11 and `tests/test.sh`. For permission or workdir changes, start at `etc/heinzel.conf.example`, `etc/heinzel-settings.json.in`, `bin/hzl` (`generate_settings`, `cmd_install`, `cmd_doctor`), then `docs/SPEC.md` §13–14. Follow callers and tests for the specific change.

## Verify and keep generated state distinct

Target macOS `/bin/bash` 3.2. Run `cd go && go test ./...`; build the versioned shell-suite prerequisite with `bin/hzl build`, then run `tests/test.sh` from the root. CI also runs shell syntax, shellcheck, gofmt and `go vet` (`.github/workflows/ci.yml`).

Edit `etc/*.in`, `etc/heinzel.conf.example`, shell and Go sources. `etc/heinzel.conf` is local operator configuration; `etc/heinzel-settings.json`, the LaunchAgent plist, and `bin/hzl-exec` are generated. `hzl install` regenerates installed settings and schedule after relevant config changes; do not treat repository files as proof of the installed or running state. Check `hzl doctor` and `hzl status` on the target machine when operational state matters. Update this routing guide when owners, generation paths, or test entry points change.
