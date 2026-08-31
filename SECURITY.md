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
- *A standing write-capable sudo window during unattended work.* The relaxed sudo ticket that makes
  interactive remote work practical is removed for the duration of a session, and restored after.

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

**What it does not defend against**

- A compromised Claude Code binary, or a compromised model endpoint.
- Content the agent chooses to commit and push to the working repository's own `origin` — see the
  carve-out above.
- A malicious task in your own `backlog.md`. The ledger is trusted input; the agent's stop
  conditions are a safety net for ambiguity, not an adversary.
- Anyone with physical access, or with your login password.
- The screen-sharing and firewall exposure you deliberately enable with `hzl remote`. That command
  opens the machine up; that is its purpose.
- FileVault recovery. An unexpected reboot leaves the machine at the unlock screen and unreachable
  remotely. This is by design of the OS and Heinzel cannot change it.

## Privileged operations, in full

Every privileged thing Heinzel does, and when:

| Operation | Command | Why |
|---|---|---|
| `pmset -a disablesleep {1,0}` | `hzl on` / `hzl off` | Keep the machine awake with the lid closed; always restored to `0` |
| `pfctl` load / enable / disable | `hzl travel` / `hzl remote` | Block or restore inbound traffic |
| `launchctl` enable/disable screen sharing | `hzl travel` / `hzl remote` | Close or open VNC |
| `pmset -c sleep/disksleep/womp` | `hzl travel` / `hzl remote` | Idle sleep and Wake-on-LAN |
| `sysadminctl -screenLock` | `hzl travel` / `hzl remote` | Screen-lock grace period |
| Install/remove `sudoers.d/heinzel-diag` | `hzl remote` / `hzl travel` | `NOPASSWD` for **read-only** diagnostics only |
| Install/remove `sudoers.d/heinzel-ticket` | `hzl remote` / `hzl travel` / suspended by `hzl on` | Non-TTY-scoped sudo tickets for interactive remote work |

`hzl` refuses to run as root; the privileged subcommands escalate internally so that state files
stay owned by the user. Any `sudoers` file is validated with `visudo -c` before installation, so a
syntax error cannot break `sudo`.
