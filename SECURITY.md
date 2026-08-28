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
- *An unattended agent reaching outside its working directory.* Reads, writes and edits are confined
  to the configured workdir by a deny list, which is validated before each run — an invalid deny
  list aborts the run instead of running without it.
- *An unattended agent reaching credentials.* SSH, AWS, gcloud, kube, npm, netrc, `.env` files and
  the agent's own settings are denied explicitly.
- *A session outliving the human's intent.* Sessions carry a TTL of at most 24 hours and drop to
  inert on expiry, reboot, loss of the liveness marker, or the machine entering travel posture.
- *Unbounded cost.* Three independent budgets plus a schedule window.
- *A standing write-capable sudo window during unattended work.* The relaxed sudo ticket that makes
  interactive remote work practical is removed for the duration of a session, and restored after.

**What it does not defend against**

- A compromised Claude Code binary, or a compromised model endpoint.
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
