# Contributing

Thanks for looking. Heinzel is early — the design is written, the implementation is not.

## Before writing code

Read [`docs/DESIGN.md`](docs/DESIGN.md). It carries ten numbered principles, and most review
comments will be a pointer to one of them. If a change contradicts a principle, that is worth
discussing — but say so explicitly rather than working around it.

Open an issue before a substantial change, so the design discussion happens once.

## Ground rules for the shell

- **Target `/bin/bash` 3.2.57**, the version macOS ships. No associative arrays, no `${var^^}`,
  no `mapfile`. CI runs `bash -n` under it.
- **No dependency stock macOS lacks.** If one is unavoidable, `hzl doctor` must detect and report
  its absence. (This is why the repository carries its own `timeout` replacement.)
- **Always `${var}`**, never bare `$var`, when a multibyte character may follow.
- **Never trust an exit code from a macOS settings tool.** Set, read back, compare, report the
  mismatch.
- Anything that observably changes behaviour for another script — exit codes, log fields, ledger
  line formats — is marked normative in `docs/SPEC.md` and needs a test.

## Tests

One entry point:

```
tests/test.sh          # static checks and offline unit tests; makes no API calls
tests/test.sh --live   # reserved: will exercise the reviewer engine (costs money)
```

The engine layer is covered offline: `lib/engines.sh` and `lib/watchdog.sh` are
exercised against a fake `claude` / `codex` on a temporary `PATH`, which records
the argv it was handed and plays back a fixture. `--live` stays refused with
exit 2 until a test calls a real engine. A flag that is accepted and ignored
reports a green suite for work it never did.

Run `tests/test.sh` before opening a pull request. Add a regression test for every bug fixed —
this project's bug history is its most valuable documentation, and `docs/DESIGN.md` §6 exists to
keep it.

## Licensing

By contributing you agree your contribution is licensed under the Apache License 2.0. New files
carry an SPDX header:

```sh
# SPDX-License-Identifier: Apache-2.0
```
