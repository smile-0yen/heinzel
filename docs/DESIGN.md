# Heinzel — Design

> Status: **design only, no code yet.** Written 2026-08-28, before implementation.
> Target: MacBook Pro / Apple M5 Pro / macOS 26.6.2 / arm64 / `/bin/bash` 3.2.57.

## §0 About this document

Heinzel keeps three documents. This is the first of them.

| Document | Answers | Read by |
|---|---|---|
| `docs/DESIGN.md` (this) | **why it is built this way** — the judgements, the rejected alternatives, the traps | people changing the design |
| `docs/SPEC.md` | **what is normatively true** — interfaces, schemas, state transitions, limits | people reading or porting the implementation |
| `docs/RUNBOOK.md` | **how to operate it** — procedures, reading logs, symptom → action | people using it |

While there is no code, this document is the source of truth. The moment `bin/hzl` exists, that
relationship inverts: **the implementation wins, and this document gets corrected.**

## §1 What Heinzel is

Heinzel has two ancestors, and it is the merge of them.

- **macmode** — a personal script (`/usr/local/bin/macmode`, 281 lines) that flips one MacBook
  between a *travel* posture (locked down for the bag) and a *remote ops* posture (open for
  VNC-driven remote use).
- **kobito** — a specification for running Claude Code unattended overnight against a
  `backlog.md`, with privilege separated out to hours when a human is present, state decided by a
  fail-safe composed function, cost bounded three ways, and the output re-read by a second engine.

Heinzel implements the kobito specification, keeps macmode's travel posture, and publishes the
result as something a stranger can install.

**The name.** *Heinzelmännchen* — the house gnomes of Cologne, who did the townspeople's work
overnight and were gone before anyone woke up. The same folklore role as 小人 (*kobito*). The
command is `hzl`.

**The license** is Apache-2.0. Every script carries an SPDX header.

## §2 The central design: two orthogonal axes

macmode had one axis with two values (`travel` | `remote`). kobito had a *different* one axis
(`normal` | `kobito`). Merging them by concatenation gives a four-valued mode soup where half the
values are nonsense. Instead, Heinzel keeps them as two axes that do not interact:

- **posture** — *how exposed the machine is.* `travel` | `remote`.
  Privileged. Changed by a human standing at the machine.
  Owns: screen sharing, packet filter, wake-on-LAN, screen-lock grace, sudo policy, Claude Code
  remote control.
- **session** — *whether unattended work is running.* `on` | `off`.
  Unprivileged after the first moment, TTL-bounded, expires by itself.
  Owns: sleep inhibition, the launchd runner, the budget, the backlog.

|  | session off | session on |
|---|---|---|
| **posture travel** | laptop in a bag | **unreachable** — §2.2 |
| **posture remote** | idle desk machine | the overnight case |

### 2.1 Why `remote` is not folded into `on`

Because you need three of the four cells. Opening VNC to work by hand from an iPhone is a
different act from starting an unattended run, and both are useful alone. Folding them also makes
`off` ambiguous: does stopping the unattended run also close VNC and re-arm the firewall? There is
no answer that is right twice.

Keeping them orthogonal costs one extra concept and buys an unambiguous `off`.

### 2.2 `travel` terminates a session; `on` refuses under `travel`

The diagonal cell is not merely discouraged, it is made unreachable, in both directions:

- `hzl travel` while a session is live → runs the full `off` path first (including the `pmset`
  restore), *then* applies the travel posture. Reported on stdout, never silent.
- `hzl on` while posture is `travel` → refused, exit 1, with the reason. **No `--force`.** The
  other refusals in `on` are about caution and can be overridden; this one is about the machine
  being in the wrong physical situation, and a flag cannot change that.

Travel means: probably on battery, probably on an untrusted network, lid closed in a bag. Every
one of those is independently a reason the runner would skip. Making the combination impossible is
cheaper than making it safe.

### 2.3 posture is *observed*, never stored

kobito's principle 3 — one source of truth per fact. For `session` that source is `state.json`.
For `posture` there is deliberately no file:

```
posture == travel   iff  screensharing job disabled  AND  pf block-all loaded  AND  no relaxed sudoers
posture == remote   iff  screensharing job loaded    AND  pf not blocking      AND  relaxed sudoers present
otherwise           mixed
```

A stored `posture: "remote"` would start lying the moment someone toggles Screen Sharing in System
Settings — and a lying state file is worse than no state file. Each component is individually
observable at negligible cost, so we observe them.

`mixed` is a first-class value, not an error. It is exactly what a half-failed transition looks
like, and printing *which* component disagrees is how the user finds out which step failed. This
matters more than usual on macOS 26, where several of these setters return 0 on failure (§6.2).

## §3 Principles

Numbered so later sections can cite them. 1–7 are kobito's, restated; 8–10 are new to the merge.

| # | Principle | Consequence |
|---|---|---|
| 1 | **Privilege only when a human is present** | The unattended lane never gains privilege. Posture changes are privileged *and* interactive. No `NOPASSWD` for anything that writes. |
| 2 | **State is a composed function, not a stored field** | Expiry, reboot, dead marker, HALT, and now *travel* all fall to `normal` on their own. |
| 3 | **One source of truth per fact** | Session state: `state.json`. Schedule: `HEINZEL_HOURS`. Posture: the OS itself (§2.3). |
| 4 | **When in doubt stop — but never silently** | The unattended run treats `blocked` as a correct outcome. It never drops a task to make a number look better. |
| 5 | **Cost and time are bounded structurally** | Per-run tasks, per-session tasks, wall clock. Plus a time window that excludes the working day. |
| 6 | **Never degrade silently** | Invalid settings JSON ⇒ do not run. Truncated diff ⇒ say so. Misspelled effort ⇒ reject at startup. |
| 7 | **Engine knowledge lives in one file** | The runner knows `engine_run` and `result.json`. Nothing else. |
| 8 | **Every OS setting has exactly one owner** | No two subsystems write the same key. This is what keeps the two axes from colliding (§4.2). |
| 9 | **Portable before convenient** | No dependency a stock macOS lacks. If one is unavoidable, `doctor` detects and reports its absence. This is why we do not use `timeout(1)` (§6.1). |
| 10 | **Nothing in the repository names its author** | Paths, launchd labels, firewall rules and model IDs are configuration, not constants (§8). |

## §4 Privilege and ownership

### 4.1 The root boundary

```
  human present — interactive                    │  no human — unattended
  ───────────────────────────────────────────────┼──────────────────────────────────
  hzl travel / hzl remote                        │  launchd → hzl-run → engine
    sudo pfctl / launchctl / sysadminctl         │    no sudo anywhere, ever
    sudo install -m 440 …/sudoers.d/heinzel-*    │    writes confined to WORKDIR
  hzl on / hzl off                               │    reads state.json, never writes mode
    sudo pmset -a disablesleep {1,0}   ← the only privileged bit session owns
                    │                                        ▲
                    ▼                                        │ read-only
              ~/.heinzel/state.json  (user-owned, 0600) ──────┘
  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ root boundary
```

Every arrow that crosses the boundary starts at a command a human typed. The unattended lane
cannot reach root even if it runs away, because there is no path — not a weakened one, an absent
one.

**`hzl` refuses to run as root.** Including the privileged subcommands: they escalate *internally*
with `sudo`, they are not themselves run under `sudo`. One `sudo hzl status` would leave
`state.json` root-owned 0600, and every subsequent unprivileged run would fail to read it — a
failure mode kobito hit and guarded against. Heinzel extends the guard to all subcommands, which
inverts macmode's interface:

```
  sudo macmode travel   →   hzl travel
  sudo macmode remote   →   hzl remote
       macmode status   →   hzl status
```

Consequence: the human is prompted for a password *inside* the command rather than in front of it.
`hzl travel` therefore prints what it is about to do before the first prompt.

### 4.2 Which subsystem owns which OS setting

This is the sharpest hazard in the merge: macmode and kobito both write `pmset`, with restore
rules that contradict each other. Principle 8 resolves it by key — no key has two owners.

| Setting | Owner | travel | remote | session on | session off |
|---|---|---|---|---|---|
| `pmset -c sleep` / `disksleep` | posture | `10` | `0` | — | — |
| `pmset -c womp` (Wake-on-LAN) | posture | `0` | `1` | — | — |
| `pmset -a disablesleep` | **session** | — | — | `1` | **always `0`** |
| screen sharing launchd job | posture | disabled | enabled | — | — |
| pf ruleset | posture | block-all anchor | `/etc/pf.conf` | — | — |
| screen-lock grace | posture | immediate | configurable | — | — |
| `~/.claude/settings.json` remote control | posture | off | on | — | — |
| `sudoers.d/heinzel-diag` (read-only NOPASSWD) | posture | removed | installed | — | — |
| `sudoers.d/heinzel-ticket` (`!tty_tickets`) | posture, **suspended by session** (§4.3) | removed | installed | removed | restored |
| `caffeinate` | session | — | — | started | killed |

Two notes carried from the ancestors, both load-bearing:

- **`disablesleep` restores to `0`, always** — never to the value recorded at `on` time. Honouring
  the recorded value compounds one missed `off` into permanent sleep suppression: the leaked `1`
  becomes the next session's baseline and no amount of `off` ever clears it. Observed on the real
  machine on 2026-08-19. `hzl off --no-sudo` is the escape hatch for deliberately keeping it.
- **`sleep 0` (posture) and `disablesleep 1` (session) are not redundant.** The first stops idle
  sleep on AC; only the second survives closing the lid. Different keys, different owners, both
  needed for the lid-closed overnight case.

### 4.3 The one setting with two owners — the sudo ticket window

macmode's remote posture installs a single sudoers file containing two very different things:

```sudoers
Defaults !tty_tickets                 # ← a standing 8-hour write window
Defaults timestamp_timeout=480
Cmnd_Alias CC_DIAG = /usr/sbin/lsof, /usr/bin/pmset -g, …   # ← read-only diagnostics
<user> ALL=(ALL) NOPASSWD: CC_DIAG
```

`!tty_tickets` is there for a real reason: Claude Code has no TTY, so a ticket obtained in a VNC
Terminal would otherwise not apply to the agent's session. Dropping tty scoping is what lets a
human authenticate once and have the agent work for the next eight hours.

That is precisely what kobito's threat model forbids. It is an eight-hour-wide, write-capable sudo
window that any process running as the user can walk through — including a runner firing at 03:00
with nobody watching.

It is fine while a human is driving. It is not fine while the runner is.

**Resolution: split the file in two, and give the dangerous half a suspend rule.**

| File | Contents | Present when |
|---|---|---|
| `sudoers.d/heinzel-diag` | `NOPASSWD` read-only diagnostics only | posture is `remote` |
| `sudoers.d/heinzel-ticket` | `!tty_tickets`, `timestamp_timeout` | posture is `remote` **and** session is `off` |

`hzl on` removes `heinzel-ticket` and invalidates outstanding tickets (`/var/db/sudo/ts/<user>`).
`hzl off` restores it if posture is still `remote`. So during an unattended session the
write-capable sudo window is *structurally closed*, and defence layer 1 (unprivileged) holds on
its own instead of leaning on layers 2–3.

The read-only half stays: it cannot write, and the deny layer blocks `Bash(sudo *)` for the agent
independently. Two reasons, either sufficient.

**What this costs:** an unattended session and a human doing sudo work over VNC cannot overlap.
Acceptable — the unattended window is 01–05 by default, which is the same window a human is
already not using. Both operations reserve the machine; now they say so.

`hzl doctor` treats `session on` **and** `heinzel-ticket` present as a defect, not a warning: the
only way to reach it is a restore path that failed.

### 4.4 Defence in depth for the unattended lane

Four layers, inherited from kobito unchanged. Each holds if any other is removed.

| Layer | Mechanism | Guarantees |
|---|---|---|
| 1 | No privilege anywhere in launchd → runner → engine | A runaway cannot reach root. Enforced by the OS, not by us. |
| 2 | `deny` in `etc/heinzel-settings.json` | Dangerous commands and secret files are unreachable. `deny` beats `allow`. |
| 3 | `--disallowedTools` repeating the critical denials | `--print` silently ignores a malformed settings file; the denials that matter most are also passed as arguments. |
| 4 | The prompt's stop conditions + the permission classifier | "When in doubt, block." Covers the judgement problems layers 1–3 cannot express. |

Layer 3 exists because of a documented `claude --print` behaviour, not a hypothetical one. Layer 2
is validated with `jq -e .` before every run: a silently-ignored deny list is the worst available
failure, so an invalid settings file aborts the run (principle 6).

## §5 State model

`~/.heinzel/state.json`, 0600, written by validating with `jq` and then `mv` — atomic replace.
Written by `hzl` and (a subset of fields) by the runner. The agent is denied write access to the
whole directory.

Fields are kobito's, with the tool renamed. The full schema is normative and belongs in
`docs/SPEC.md`; the design-relevant parts are:

- `mode` — `"heinzel"` | `"normal"`. **Alone it does not mean the session is live** (§5.1).
- `expires_at_epoch` — TTL. Max 24 h, not configurable upward.
- `boot_id` — `sysctl -n kern.bootsessionuuid`. **Not `kern.boottime`** — see below.
- `caffeinate_pid` — liveness marker. Killing it drops the session immediately; that is the
  documented emergency stop.
- `max_tasks_total`, `max_tasks_per_run`, `tasks_done_total`, `run_timeout_sec` — the budget.
- `halt_reason` — `null` | `"auth"` | `"consecutive-failures"`. Non-null ⇒ every run no-ops.
- `workdir`, `backlog` — always absolute. launchd runs with `cwd=/`, so a relative path is not a
  bug that shows up later, it is a guaranteed abort.

**`kern.boottime` must not be used to detect reboots.** kobito measured two independent defects:
the obvious `sed` greediness that captures `usec` instead of `sec`, and the fatal one — the value
*changes without a reboot* (uptime 15 days, usec moved 582824 → 851932). Together they make every
run after the first sleep/wake cycle no-op for the stated reason "rebooted". For an overnight tool
that is total failure. `kern.bootsessionuuid` is unique per boot and constant while up.

### 5.1 `effective_mode()` — the composed function

Short-circuit AND, evaluated in this order. Any single false ⇒ `normal` ⇒ the run does nothing.

```
  state.json exists, readable, valid   ─┐
  state.mode == "heinzel"               │
  halt_reason == null                   │
  now < expires_at_epoch                ├─ AND ─→ heinzel   (status exit code 10)
  boot_id == current boot session       │
  caffeinate_pid is alive               │
  posture != travel            ← new    ─┘
                    │
                    └─ any false ─→ normal (silent no-op, exit 0, no log line)
```

Fail-safe is guaranteed by there being **only one direction to fall**. Expiry, reboot, a dead
marker, HALT, and now leaving the desk all land on "do nothing".

**Why gate 7 (`posture != travel`) earns its place** even though the runner already skips on
battery: the AC gate catches the bag, but not the café. A machine on travel posture plugged into a
café outlet passes every other gate — right TTL, right boot, live marker, AC power — and would
fire a run on an untrusted network with the firewall closed around it. Gate 7 is one `launchctl
print` plus one `pfctl` read, and it is the only gate that encodes *where the machine is* rather
than *what state it is in*. Both gates stay; they fail in different directions.

Each false condition maps to exactly one human-readable reason string, and each reason string maps
to exactly one row in the RUNBOOK. That one-to-one property is normative — it is what makes
`status` output actionable without reading code.

## §6 What the target machine forced us to change

kobito's spec was written against a machine we do not have. These are the deltas we measured
before writing any code.

### 6.1 `timeout(1)` does not exist — measured

```
$ command -v timeout gtimeout
(nothing)
```

macOS 26.6.2 ships neither. kobito depends on `timeout -k 30 <sec>` for the wall-clock budget and
on exit codes 124/137 to classify a run as `timeout`. That dependency is simply unmet on a stock
Mac, and `brew install coreutils` is friction we should not hand to someone installing an OSS tool
(principle 9).

Heinzel ships `lib/watchdog.sh` with `hzl_timeout <kill_after> <secs> <cmd…>`, contract-compatible
with coreutils `timeout`, in bash 3.2:

1. start the child in the background, record `$!`
2. start a watchdog that sleeps `secs`, sends `TERM`, sleeps `kill_after`, sends `KILL`
3. `wait` on the child; map TERM-after-timeout → 124, KILL → 137
4. kill the watchdog on the normal path so it cannot outlive the run

Two traps from kobito §8.3 are the reason this is one tested helper rather than three inline
copies:

- **Never wrap `cd` in a subshell around the child.** `( cd … && cmd ) &` makes `$!` the
  subshell's pid; killing it orphans the grandchild (the engine), which keeps running and keeps
  billing. Do `cd` → background → `cd` back → `wait`.
- **Never foreground the child.** bash defers a `SIGTERM` trap until the foreground child exits,
  so the runner's own `trap cleanup EXIT INT TERM` would not fire when it matters most.

The child's pid is exported as `HEINZEL_ENGINE_PID` so the runner's cleanup can reach it.

If `gtimeout` happens to be installed, `doctor` notes it and we still use our own — one code path,
tested once.

### 6.2 macOS 26 setters that fail silently

Carried from macmode, measured on this OS version:

- `socketfilterfw --setblockall` is accepted and ignored. Block-all is done with a pf anchor that
  preserves Apple's own anchors, and the result is read back with `pfctl -s info`.
- `sysadminctl -screenLock` returns 0 on failure and needs the user's password on stdin.

Both setters are therefore wrapped in the same shape: **set, read back, compare, report the
mismatch.** Never trust the exit code. This is the mechanical form principle 6 takes here, and it
is why `posture` can report `mixed` at all.

### 6.3 `/bin/bash` is 3.2.57

No associative arrays, no `${var^^}`, no `mapfile`, no `${var@Q}`. Plus two from kobito:

- a multibyte character immediately following `$var` is parsed as part of the variable name, and
  under `set -u` that is an unbound-variable abort. Always `${var}`. Mostly moot now the UI is
  English, but comments and prompt templates still carry UTF-8, so lint keeps the rule.
- multibyte truncation is locale-dependent. One `trunc` helper, explicit `LC_CTYPE`.
- **`awk -v` rejects a newline in the value.** Hit twice while building: once
  rendering a prompt (a task plus its notes), which produced an *empty* prompt
  that then sailed through the leftover-placeholder check, and once generating
  the plist's calendar block, which meant `hzl install` wrote no plist at all.
  Multi-line values go through `ENVIRON` instead. Where the value is text a
  human typed and the destination is line-oriented, it is flattened with
  `oneline` rather than passed through — a newline in a backlog reason would
  break the ledger format even if awk accepted it.

### 6.4 Inherited but not re-observed

kobito's §14 table lists traps measured on *its* machine: `codex exec` blocking on non-TTY stdin,
`codex login status` writing to stderr with rc 0, codex emitting MCP 401s on successful runs, `jq`'s
`//` collapsing `false`, `--argjson` with a torn line exiting 0, git-root prefix matching breaking
across a symlink, `xargs` destroying `ls -t` ordering.

Every one becomes a check in `tests/lint.sh` or `tests/test.sh`. None are presented as our
findings: `docs/SPEC.md` marks them **inherited, not re-verified here**, and they get promoted to
verified only when we observe them ourselves. Blurring that line is how a spec starts lying.

## §7 Components

```
heinzel/
├── bin/hzl              interactive CLI — the only place privilege is used
├── bin/hzl-run          launchd runner — non-interactive, unprivileged
├── bin/hzl-review       changeset → reviewer → verdict.json → exit code
├── bin/hzl-changeset    snapshot / diff (shell only, no LLM)
├── lib/common.sh        state, backlog, time, power
├── lib/posture.sh       travel / remote, with read-back verification
├── lib/engines.sh       the only file that knows engine-specific flags
├── lib/watchdog.sh      hzl_timeout (§6.1)
├── etc/heinzel.conf              the tuning surface
├── etc/heinzel-settings.json     deny/allow for the unattended agent
├── etc/review-schema.json        forces the reviewer's output shape
├── etc/pf-travel.conf.in         pf anchor template (posture)
├── etc/sudoers-{diag,ticket}.in  sudoers templates (posture, §4.3)
├── etc/agent.plist.in            LaunchAgent template
├── prompts/{backlog-run,review,review-fix}.md
└── tests/{test.sh,lint.sh}       one entry point: test.sh

~/.heinzel/              mutable state — outside the agent's reach, denied twice
├── state.json           session state, 0600
├── run.lock / run.pid / caffeinate.pid
└── logs/{runner.log, runs.jsonl, launchd.{out,err}, <YYYY-MM-DD>/…}
```

The split that matters: **all judgement lives in the runner, all engine knowledge lives in
`engines.sh`.** Adding an engine touches one file. The runner only ever sees `engine_run` and a
normalised `result.json`.

The review pipeline follows the same shape — the LLM decides exactly one step in the middle
(`snapshot` → executor → `diff` → **reviewer** → gate), and everything before and after it is
deterministic shell. A degraded reviewer cannot corrupt the ledger, and a missing reviewer cannot
stop it: review is a quality gate, never an availability dependency.

## §8 Making it publishable

The two ancestors are personal tools; every hard-coded assumption has to become configuration
(principle 10).

| Was, in macmode / kobito | Becomes |
|---|---|
| `~/claude` workdir, `~/claude/backlog.md` | `HEINZEL_WORKDIR` / `HEINZEL_BACKLOG`. No default that assumes someone else's directory exists; `hzl install` requires them explicitly. |
| launchd label `com.tatsuyasuzuki.kobito` | `HEINZEL_LABEL`, resolved at install time, default `local.heinzel`. |
| Japanese CLI output, byte-width alignment helper | English. The alignment helper is deleted outright, not translated. |
| Model IDs, `--effort xhigh`, Bedrock env inheritance | Configurable; model and effort are always passed explicitly and echoed into `result.json`. Generalised as *inherited interactive settings must not silently change unattended cost*, which is true for everyone, rather than as one machine's quirk. |
| codex required as reviewer | Optional. Review defaults to **off** on a fresh install. A missing reviewer yields `verdict: skipped`, never a failure. |
| macmode's pf rules, sudoers contents, VNC assumptions | Templates in `etc/`, and the posture commands are **opt-in**: with no posture config, `hzl travel` / `hzl remote` refuse rather than guess at a stranger's firewall. |
| Single-user assumptions (`/usr/local/bin`, root-owned script) | User-level install; `~/.local/bin/hzl` symlink, repo checked out anywhere. |

Repository surface: `README.md`, `LICENSE` (Apache-2.0), `NOTICE`, `CONTRIBUTING.md`,
`SECURITY.md`, `CHANGELOG.md`, `.github/workflows/ci.yml` (shellcheck + `tests/test.sh` on
`macos-latest`).

`SECURITY.md` carries more weight than usual: this tool installs a sudoers file and a LaunchAgent,
and runs an LLM agent unattended. It states the threat model (§4.4), what is explicitly out of
scope, and a private reporting path.

## §9 Implementation phases

Each phase ends with `tests/test.sh` green. Nothing merges without it.

| Phase | Delivers | Done when |
|---|---|---|
| **0** (this) | Design, repository skeleton, license, CI stub | Documents reviewed |
| **1** | `lib/common.sh`, state model, `hzl status` / `on` / `off` / `doctor`, `lib/watchdog.sh` | Session lifecycle works with no engine involved; watchdog returns 124/137 correctly |
| **2** | `lib/posture.sh` — `travel` / `remote` ported from macmode with read-back verification and the sudoers split (§4.3) | Both transitions verified by reading back, `mixed` reported correctly |
| **3** | `bin/hzl-run`, LaunchAgent, backlog ledger, engine abstraction. Review disabled. | A seeded task goes `[ ]` → `[x]` unattended; `normal` no-ops in well under a second with zero API calls |
| **4** | Review pipeline: `hzl-changeset`, `hzl-review`, the gate | Gate rewrites only this run's `[x]` lines; reviewer failure never drops a task |
| **5** | `RUNBOOK.md`, docs pass, public-readiness review | Repository can be made public without an edit |

Phases 1–2 are independent of 3–5 and can land in either order; the two axes do not share code
beyond `lib/common.sh`.

## §10 Open questions

Recorded rather than guessed at.

1. **Copyright holder.** `LICENSE` and `NOTICE` currently say `smile-0yen` (the GitHub account),
   which fits the existing neutral-naming policy for this machine. Switch to a legal name if the
   repository is ever meant to carry one.
2. **Default schedule.** kobito used 01–05, five slots. Keeping it as the default; it is
   `HEINZEL_HOURS` and the plist is generated from it, so changing it is one edit in one place.
3. **`hzl remote` and the network layer.** macmode assumes Tailscale is already up and does not
   manage it. Heinzel keeps that boundary for v1: posture touches local settings only.
4. **FileVault.** An unexpected reboot during a session strands the machine at the unlock screen,
   unreachable remotely. Nothing Heinzel can do about it; it belongs in the RUNBOOK as the reason
   planned reboots go through `sudo fdesetup authrestart`.
5. **What happens to `macmode`.** Leave `/usr/local/bin/macmode` in place, replace it with a shim
   that prints the `hzl` equivalent, or remove it. Recommend the shim for one release, then remove.
