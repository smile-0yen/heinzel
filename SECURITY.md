# Security

Heinzel installs a `sudoers` drop-in and a LaunchAgent, and runs an LLM coding agent unattended on
your machine. That deserves a stated threat model rather than a promise.

## Reporting a vulnerability

Please report privately through
[GitHub Security Advisories](https://github.com/smile-0yen/heinzel/security/advisories/new)
rather than opening a public issue. A first response should take a few days; there is no bounty.

## Threat model

**What Heinzel defends against**

- *An unattended agent escalating privilege.* The unattended lane (launchd → runner → engine) never
  uses `sudo`. This is enforced by the absence of a code path, and independently by the OS.
- *An unattended agent reaching outside its working directory.* Writes are confined to the
  configured workdir by the OS: `sandbox.enabled` puts every Bash command and its child processes
  inside Seatbelt, and `--permission-mode dontAsk` refuses anything not pre-approved, including
  Claude's own Write tool. The permission file is validated before each run — an invalid one aborts
  the run instead of running without it.

  Until 2026-08-30 this said the confinement came from the deny list under `--permission-mode auto`.
  That was wrong, and testing found it: an `allow` rule pre-approves rather than denying the rest,
  permission rules do not see a subprocess opening a file itself, and a command the sandbox refuses
  falls back to being approved unsandboxed. See `docs/DESIGN.md` §4.5.
- *An unattended agent reaching credentials.* SSH, AWS, gcloud, kube, npm, netrc, `.env` files and
  the agent's own settings are denied explicitly.
- *A session outliving the human's intent.* Sessions carry a TTL of at most 24 hours and drop to
  inert on expiry, reboot, loss of the liveness marker, or the machine entering travel posture.
- *Unbounded cost.* Three independent budgets plus a schedule window.
- *A standing write-capable sudo window during unattended work.* The relaxed sudo ticket that made
  interactive remote work practical was retired in v0.4.0: no mode installs one, and every mode
  removes the file an older build left behind.
- *An unattended agent touching a real environment.* Safe mode (`HEINZEL_SAFE_MODE`, on by default,
  `docs/SPEC.md` §13.1) denies the commands that reach a cluster, a cloud account, a registry, a
  package index or another host — `gcloud`, `kubectl`, `terraform`, `helm`, `ssh`, `docker push`,
  `npm publish` and the rest of the list in `lib/common.sh`. A run that needs one is refused and
  blocks the task, which is the intended outcome: a deploy at three in the morning is the action
  nobody is there to take back. With the setting on, a run whose permission file does not carry the
  rules **aborts** rather than proceeding believing itself confined.

  Two limits, stated because a control nobody can bound is a control nobody can rely on. It is a
  permission-layer rule over the agent's own Bash tool, so a *subprocess* that invokes `kubectl`
  itself is stopped by the sandbox and its domain allowlist, not by this — the case DESIGN §4.5
  describes. And it is a list of command names: something reachable by another name, or by a
  script already in the repository, is not on it.

**A deliberate carve-out: `git push origin` (2026-09-01)**

The unattended agent may push the working repository's branch and tags to `origin`. Until
2026-09-01 every outward channel was denied; the nightly self-improvement loop
(`docs/RELEASING.md`) requires each verified change to land on the remote the same night, so this
one channel is open. Its scope is held narrow by three independent mechanisms: the sandbox network
allowlist admits only `github.com` (everything else still fails at the proxy, measured as a
CONNECT 403), the permission file denies `git push --force`/`-f`/`--mirror`/`--delete`, and the
prompt names `origin` as the only remote. The residual risk is real and accepted: an agent that
can push can publish whatever is in the workdir to the repository it already works on. History
rewriting stays denied, so a bad push is revertible.

**A deliberate carve-out: Heinzel edits its own source (2026-09-01)**

The working directory is the Heinzel repository, so the unattended agent writes the tool that runs
it. The repository was denied wholesale until now; keeping it that way would have denied the point.

The line is drawn at `etc/`, because nothing in `etc/` is code. Every file in it is control
surface, and each one is a way to widen the boundary rather than do the task: the generated deny
list and the template it comes from, `heinzel.conf` (budget, schedule, workdir, engine, review),
`agent.plist.in` (when the runner fires, and with what `PATH`), and the `sudoers-*.in` and
`pf-travel.conf.in` templates — which a *human* later installs with privilege, so an agent writing
them is writing a privileged file and waiting for someone to run it. `bin/`, `lib/`, `prompts/`,
`docs/` and `tests/` are writable; `etc/` is not; `Read` stays allowed throughout, because
understanding the configuration is not the risk.

Measured 2026-09-01, and the measurement is the reason this is stated as confinement rather than
as etiquette: under the same settings file, `python3` invoked through Bash — a subprocess opening
the file itself, the case DESIGN §4.5 warns permission rules do not cover — appended to a file in
the repository root and was refused in `etc/`. A path `Edit(...)` denial is reflected in the OS
sandbox, not only in Claude's own file tools.

The residual risks are real and accepted:

- **`bin/hzl` is writable, and a human runs it with `sudo`.** The unattended lane still never gains
  privilege itself, but it can now author code that a person later escalates. Nothing in the
  permission file defends against this. What stands in its place is the git history: every change
  is committed and pushed by the release ritual, so it is reviewable after the fact.

  **The review pipeline is not a second defence here, and it is important not to read it as one.**
  The release ritual pushes inside the executor's own run; the review gate runs after that. So the
  reviewer sees the work *after* it has reached `origin`, and a `reject` reverts the backlog line —
  it does not revert the commit, un-push it, or move the tag. Review gates the ledger, not the
  remote. Turning it on (`HEINZEL_REVIEW=1`) buys a recorded second opinion and a clear morning
  signal; it does not buy prevention. Making it prevent anything means moving the push behind the
  gate, which is a design change, not a setting — see `docs/SPEC.md` §15.
- **`prompts/backlog-run.md` is writable**, so the agent can edit its own instructions, including
  its stop conditions. This is consistent with the threat model below: the stop conditions are a
  safety net for ambiguity, not a defence against an adversarial agent.

**What it does not defend against**

- A compromised Claude Code binary, or a compromised model endpoint.
- Content the agent chooses to commit and push to the working repository's own `origin` — see the
  carve-out above.
- A malicious task in your own `backlog.md`. The ledger is trusted input; the agent's stop
  conditions are a safety net for ambiguity, not an adversary.
- Anyone with physical access, or with your login password.
- The screen-sharing and firewall exposure you deliberately enable with `hzl work`. Remote
  posture is part of that mode; opening the machine is its purpose.
- FileVault recovery. An unexpected reboot leaves the machine at the unlock screen and unreachable
  remotely. This is by design of the OS and Heinzel cannot change it.

## Privileged operations, in full

Every privileged thing Heinzel does, and when:

| Operation | Command | Why |
|---|---|---|
| `pmset -a disablesleep {1,0}` | `hzl work` / `hzl mobile` / `hzl off` | Keep the machine awake with the lid closed; always restored to `0` |
| `pfctl` load / enable / disable | `hzl work` / `hzl mobile` / `hzl off` | Block or restore inbound traffic |
| `launchctl` enable/disable screen sharing | `hzl work` / `hzl mobile` / `hzl off` | Close or open VNC |
| `pmset -c sleep/disksleep/womp` | `hzl work` / `hzl mobile` / `hzl off` | Idle sleep and Wake-on-LAN |
| `sysadminctl -screenLock` | `hzl work` / `hzl mobile` / `hzl off` | Screen-lock grace period |
| Install/remove `sudoers.d/heinzel-diag` | `hzl work` / `hzl mobile` / `hzl off` | `NOPASSWD` for **read-only** diagnostics only |
| Remove `sudoers.d/heinzel-ticket`, invalidate outstanding tickets | `hzl work` / `hzl mobile` / `hzl off` | The non-TTY-scoped sudo window is allowed only under remote posture with the session off, which is not one of the three modes. No mode installs it |

`hzl` refuses to run as root; the privileged subcommands escalate internally so that state files
stay owned by the user. Any `sudoers` file is validated with `visudo -c` before installation, so a
syntax error cannot break `sudo`.
