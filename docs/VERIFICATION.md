# Manual verification plan

Everything in this document is a gap listed in [SPEC.md](SPEC.md) §15 — the
things that cannot be checked without a real machine, real credentials, and a
person watching.

The phases are ordered by how hard they are to undo. **Do them in order.** Each
one ends with an *evidence* block: commands whose output goes back to whoever
is fixing the code. Skipping a phase is fine; doing a later one first is not,
because a failure there is harder to diagnose without the earlier results.

Three rules that apply throughout:

- **Never run any of this with `sudo`.** `hzl` refuses, and the reason is that
  one `sudo hzl` leaves `state.json` owned by root and everything afterwards
  fails to read it. The commands that need privilege ask for it themselves.
- **Use a scratch working directory until phase E.** Not the directory you
  keep real work in. The agent is confined to `DEFAULT_WORKDIR`, so make that
  somewhere you would not mind losing.
- **Phase D can cut off remote access to this machine.** Read its warning
  before starting it.

---

## Phase 0 — does the engine work headless at all?

Before involving Heinzel, establish that the CLI runs non-interactively with
your credentials. If this fails, nothing in phase C can succeed, and the causes
look identical from the outside.

```sh
claude -p "Reply with exactly: ok" --output-format json \
  --model claude-opus-5 --effort low | jq '{is_error, result, session_id}'
```

Watch for: a non-zero exit, an authentication message on stderr, or a hang. A
hang here matters — it is the failure mode Heinzel's watchdog exists for.

Also worth knowing, because the unattended run inherits it via
`--setting-sources user`:

```sh
jq 'keys' ~/.claude/settings.json          # keys only, not values
jq '.env | keys? // "no env block"' ~/.claude/settings.json
```

If that file sets `ANTHROPIC_MODEL` or similar, the unattended run inherits it,
and the model you asked for is not necessarily the model that runs. Heinzel
records both — `model` is what was requested, `models_used` is what actually
ran — and phase C checks they agree.

> **Evidence 0** — the three outputs above. The `keys` calls deliberately avoid
> printing values, since that file can hold credentials.

---

## Phase 1 — install, configure, inspect

Nothing here starts an agent or changes a system setting.

```sh
cd ~/Claude/heinzel
./install.sh
```

`install.sh` copies the example configuration, which deliberately leaves the
paths **empty** — there is no sensible default for where your work lives, so it
does not guess. `hzl doctor` reports them as unconfigured until you fill them
in, which is the expected state at this point, not a fault.

Edit `etc/heinzel.conf`. At minimum:

```sh
DEFAULT_WORKDIR="/Users/<you>/hzl-scratch"     # must be absolute and exist
DEFAULT_BACKLOG="/Users/<you>/hzl-scratch/backlog.md"
```

`mkdir -p` the scratch directory first — `hzl on` refuses if the working
directory does not exist, on purpose, because launchd runs with `cwd=/` and a
missing directory would abort every run at 03:00 instead of now.

```sh
hzl doctor
hzl status
```

Expect at this point: complaints about a missing `etc/heinzel-settings.json`
and an unloaded launch agent. Both are fixed by the next phase. Anything else
is a real finding.

> **Evidence 1** — the full `hzl doctor` output and `hzl status`.

---

## Phase 2 — the launch agent

```sh
hzl install
launchctl print "gui/$(id -u)/local.heinzel" | head -25
```

This writes `~/Library/LaunchAgents/local.heinzel.plist`, generates
`etc/heinzel-settings.json` (the deny list, built around your working
directory), and loads the agent. It does **not** start a session: with no
session, every firing exits without doing anything.

Check the deny list actually names your scratch directory:

```sh
jq '.permissions.allow' etc/heinzel-settings.json
```

Reversible with `hzl uninstall`.

> **Evidence 2** — `hzl doctor` again (sections 2 and 3 should now be clean),
> and the `jq` output above.

---

## Phase 3 — the first real engine call

**This is the largest untested area.** Every run so far has been a dry run; no
API call has ever been made by this code.

Seed the scratch backlog with something small and objectively verifiable:

```sh
cat > ~/hzl-scratch/backlog.md <<'EOF'
# Backlog

## P1
- [ ] create hello.sh that prints "hello from heinzel", make it executable, and verify it runs
EOF
```

Start a deliberately small session:

```sh
hzl on --duration 1h --max-total 1 --max-tasks 1 --timeout 600 --no-kick
```

Why each flag:

- `--max-total 1` — one task, so a misbehaving run costs one task's worth.
- `--timeout 600` — ten minutes, not an hour. If the agent hangs on a denied
  tool call (a behaviour inherited from kobito's notes and never re-verified
  here), this is what limits the damage.
- `--no-kick` — no run starts automatically. **You** decide when the first API
  call happens, on the next line.

You will be asked for your password once, for `pmset -a disablesleep 1`. That
is the only privileged thing a session does.

Then, deliberately:

```sh
HEINZEL_EFFORT=low hzl run-now
```

`HEINZEL_EFFORT=low` for the first call: this is a test of the plumbing, not of
the model. Environment beats the config file for this key, by design.

Watch for, in order of importance:

1. **A hang.** If nothing returns after ~10 minutes, the watchdog should kill
   it and the run should be recorded as `timeout`. If it hangs *past* that,
   the watchdog is broken and that is a serious finding — `Ctrl-C`, then
   `hzl off`.
2. `models_used` disagreeing with `model` — an inherited setting overrode the
   request.
3. The task marked `[x]` without `hello.sh` actually existing.

Whatever happens:

```sh
hzl off
```

> **Evidence 3**, in full — this is the phase where detail matters most:
>
> ```sh
> cat ~/.heinzel/logs/runner.log
> tail -1 ~/.heinzel/logs/runs.jsonl | jq .
> D=~/.heinzel/logs/$(date +%Y-%m-%d)
> jq '{engine,role,model,effort,models_used,verdict,exit_code,duration_sec,cost_usd,turns}' \
>    "$D"/exec-*/result.json
> head -40 "$D"/exec-*/stderr
> cat "$D"/notes.md
> cat ~/hzl-scratch/backlog.md
> ls -la ~/hzl-scratch/
> ```
>
> `stderr` can contain error text from the API. Skim it before pasting.

### Phase 3b — the timeout path (optional, ~2 minutes of spend)

The `timeout` verdict and its `[~]` rollback have only been unit-checked. To
exercise them for real, seed a task that cannot finish quickly and give it a
very short clock:

```sh
hzl on --duration 1h --max-total 1 --timeout 60 --no-kick
hzl run-now         # expect: result "timeout", exit 124, the task back at [ ]
hzl off
```

> **Evidence 3b** — `tail -1 ~/.heinzel/logs/runs.jsonl | jq '{result,exit_code}'`
> and the backlog line afterwards (it must be `[ ]`, not `[~]`).

---

## Phase 4 — posture

> ## Read this before running anything in this phase
>
> **`hzl travel` disconnects remote access to this machine.** It stops screen
> sharing and blocks all inbound traffic. If you run it over VNC, the session
> dies mid-command and you cannot undo it remotely — recovery needs the
> keyboard.
>
> Run this phase **sitting at the machine**. Not over VNC, not over Tailscale.
>
> It also stops any running session first, on purpose.

Posture refuses to do anything until you turn it on deliberately:

```sh
# in etc/heinzel.conf
HEINZEL_POSTURE=1
```

Look before you leap — this changes nothing and prints every step:

```sh
hzl travel --dry-run
hzl remote --dry-run
```

Then, at the machine:

```sh
hzl travel          # asks for your password (pfctl, launchctl, sysadminctl)
hzl status          # expect: posture travel, screen sharing off
hzl doctor          # section 8 lists every component separately
```

Verify the block is real rather than merely claimed — this is the setting macOS
26 accepts and silently ignores through `socketfilterfw`, which is why it is
done with pf:

```sh
sudo pfctl -s info | head -3           # expect Status: Enabled
sudo pfctl -s rules | grep "block drop"
nc -z -G 1 127.0.0.1 5900; echo "5900 reachable: $?"   # expect non-zero
```

Then put it back:

```sh
hzl remote
hzl status          # expect: posture remote, screen sharing on
ls /etc/sudoers.d/
```

Two things worth knowing about the transition:

- **`sudo` still works, whatever happens.** Every sudoers file is validated
  with `visudo -c` before installation, and a file that fails validation is not
  installed.
- **macmode's `/etc/sudoers.d/claude-code` is not touched.** Heinzel manages
  `heinzel-diag` and `heinzel-ticket` only, and posture detection ignores the
  old file. After this phase both may exist; deciding whether to remove the old
  one is yours, and until you do, the old relaxed ticket policy is still in
  force regardless of what Heinzel thinks.

Then check the interlock that the whole sudo split exists for:

```sh
hzl on --duration 1h --no-kick
ls /etc/sudoers.d/          # heinzel-ticket must be GONE
hzl doctor                  # section 8 must not report a defect
hzl off
ls /etc/sudoers.d/          # heinzel-ticket must be BACK
```

And the refused cell of the matrix:

```sh
hzl travel
hzl on                      # must refuse, exit 1, and say why
hzl remote
```

> **Evidence 4** — `hzl status` and `hzl doctor` section 8 after `travel` and
> again after `remote`; the three `pfctl`/`nc` outputs; the two `ls
> /etc/sudoers.d/` outputs from the interlock check; and the exact refusal
> message from `hzl on` under travel.

---

## Phase 5 — a night

Only after phases 1–3 pass. Point the configuration at real work, or keep the
scratch directory with a handful of genuine tasks.

```sh
hzl remote
hzl on --duration 10h
hzl status                  # confirm: session on, slots before expiry > 0
```

Then leave it. In the morning:

```sh
hzl status
cat ~/.heinzel/logs/$(date +%Y-%m-%d)/notes.md
hzl take
hzl off
```

Things to look at specifically:

- Did runs fire at 01:00–05:00, or all at once on wake? The second means the
  window guard failed, which is the thing that keeps runs out of your working
  day.
- Did the machine stay awake with the lid closed? If it slept, `disablesleep`
  did not take on this build, and `hzl on` should have warned.
- Did the budget hold? `tasks_done_total` must never exceed `max_tasks_total`.

> **Evidence 5** — `notes.md`, `grep -E "skip|abort|HALT|ok" ~/.heinzel/logs/runner.log`,
> and `jq -c '{run_id,result,tasks_done,tasks_done_total,cost_usd,duration_sec}' ~/.heinzel/logs/runs.jsonl`.
> Redact task text if the backlog by then holds real work.

---

## Phase 6 — the review pipeline (optional)

Needs a second engine authenticated: `codex login status`.

```sh
HEINZEL_REVIEW=1 hzl run-now
```

Only the "no changes" and "reviewer unavailable" paths have been exercised. The
interesting cases are a real `approve` and a real `reject` — and specifically
that a `reject` reverts **only** the lines carrying this run's id, leaving
other runs' completions and anything you closed by hand alone.

> **Evidence 6** — `cat ~/.heinzel/logs/$(date +%Y-%m-%d)/review-*/verdict.json`
> and `jq '.review' <(tail -1 ~/.heinzel/logs/runs.jsonl)`.

---

## If something goes wrong

```sh
kill $(cat ~/.heinzel/caffeinate.pid)   # every later run no-ops. No password
hzl off                                 # stop and restore settings
hzl uninstall                           # remove the launch agent
```

The first works because the liveness marker is one of the seven conditions a
session is judged by. It needs no privilege and no working `hzl`.

To undo Heinzel completely:

```sh
hzl off && hzl uninstall
rm -f ~/.local/bin/hzl
sudo rm -f /etc/sudoers.d/heinzel-diag /etc/sudoers.d/heinzel-ticket
sudo pmset -a disablesleep 0
rm -rf ~/.heinzel                       # deletes the logs too
```
