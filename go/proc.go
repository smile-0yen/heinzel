// SPDX-License-Identifier: Apache-2.0
//
// proc.go — starting a process and holding it to a wall clock.
//
// This is lib/watchdog.sh, which was a replacement for coreutils timeout(1)
// because stock macOS ships neither `timeout` nor `gtimeout` and the
// wall-clock budget is not optional (DESIGN 6.1). The contract it kept is the
// contract kept here, exit codes included:
//
//	124  the command was killed after exceeding its seconds
//	137  the command ignored TERM and was killed after kill_after more
//	125  refused before anything started
//	127  there was nothing there to start
//	otherwise the command's own status, or 128+signal when a signal ended it
//
// Three things the shell version had to say in comments are structural here.
//
//   - The child leads its own process group, so a timeout kills the engine's
//     own children with it. In shell that needed `set -m` toggled around the
//     background job and restored afterwards, because job control is what made
//     a job a group leader. Here it is one field on SysProcAttr.
//
//   - The child is never wrapped in a subshell to change directory. `( cd x &&
//     cmd ) &` makes the pid the subshell's, and killing that orphans the real
//     grandchild, which keeps running and keeps billing. Here the directory is
//     a field on the command and there is no wrapper process at all.
//
//   - A stop from outside arrives while we are waiting. The shell relied on
//     the engine sharing a process group with the thing being signalled; here
//     the group is deliberately separate, so this process forwards the signal
//     down and applies the same bounded escalation to it. That is stricter
//     than what it replaces: the engine is stopped by something that then
//     waits to see it gone, rather than by a signal aimed at a group it was
//     assumed to be in.
package main

import (
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

const (
	exitTimedOut = 124 // the wall clock ran out and TERM ended it
	exitKilled   = 137 // TERM was ignored; KILL ended it
	exitRefused  = 125 // nothing was started
	exitNotFound = 127 // there was nothing there to start
)

type procSpec struct {
	executable string
	argv       []string
	env        []string // full environment, or nil to inherit
	dir        string
	// stdin is explicit because the two callers need opposite things. A batch
	// engine run must have it closed: `codex exec` treats a non-TTY stdin as
	// additional input and waits for EOF, which hangs forever under launchd
	// even when the prompt was passed as an argument. A `timeout` around a
	// command in a pipeline must inherit it, or the pipe it was put there to
	// read would be empty.
	stdin     *os.File
	stdout    *os.File
	stderr    *os.File
	timeout   time.Duration
	killAfter time.Duration
}

type procOutcome struct {
	exitCode int
	started  time.Time
	ended    time.Time
}

// signalGroup sends sig to the whole group the child leads. The negative pid
// is the group; the fallback to the bare pid covers the window in which the
// child has been forked but has not yet been moved into its own group, where
// the group does not exist to be addressed.
func signalGroup(pid int, sig syscall.Signal) {
	if err := syscall.Kill(-pid, sig); err != nil {
		_ = syscall.Kill(pid, sig)
	}
}

// waitStatus turns what the OS reports into the number a shell caller expects:
// the command's own status when it exited, and 128+signal when a signal ended
// it, which is what `wait` in bash would have returned for the same process.
func waitStatus(ps *os.ProcessState) int {
	if ps == nil {
		return exitRefused
	}
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok {
		if ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return ws.ExitStatus()
	}
	return ps.ExitCode()
}

func runProc(p procSpec) procOutcome {
	cmd := exec.Command(p.executable, p.argv...)
	cmd.Dir = p.dir
	cmd.Env = p.env
	cmd.Stdout = p.stdout
	cmd.Stderr = p.stderr

	cmd.Stdin = p.stdin

	// The child leads its own process group, so that signalling it reaches the
	// engine's own subprocesses too.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	started := time.Now()
	if err := cmd.Start(); err != nil {
		// Nothing was started. 127 is what a shell reports for a command it
		// could not find, and callers already read that number; anything else
		// would be a new code for an old situation.
		code := exitNotFound
		if !errors.Is(err, exec.ErrNotFound) && !errors.Is(err, os.ErrNotExist) {
			code = exitRefused
		}
		errf("cannot start %s: %v", p.executable, err)
		return procOutcome{exitCode: code, started: started, ended: time.Now()}
	}
	pid := cmd.Process.Pid

	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(done)
	}()

	// A stop from outside. Forwarded down and then escalated on the same
	// bounded schedule as a timeout, because a signal delivered is not a stop
	// (lib/cancel.sh §14.5) and this process is the only one still holding the
	// engine's group id.
	stops := make(chan os.Signal, 1)
	signal.Notify(stops, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(stops)

	var timedOut, killed bool

	// A timeout of zero means no wall clock at all. A nil channel blocks
	// forever, which is exactly the "never fires" this needs.
	var deadline <-chan time.Time
	if p.timeout > 0 {
		t := time.NewTimer(p.timeout)
		defer t.Stop()
		deadline = t.C
	}

	select {
	case <-done:
	case <-stops:
		signalGroup(pid, syscall.SIGTERM)
		if !waitOrKill(pid, done, p.killAfter) {
			killed = true
		}
	case <-deadline:
		timedOut = true
		signalGroup(pid, syscall.SIGTERM)
		if !waitOrKill(pid, done, p.killAfter) {
			killed = true
		}
	}

	ended := time.Now()
	switch {
	case killed:
		return procOutcome{exitCode: exitKilled, started: started, ended: ended}
	case timedOut:
		return procOutcome{exitCode: exitTimedOut, started: started, ended: ended}
	default:
		return procOutcome{exitCode: waitStatus(cmd.ProcessState), started: started, ended: ended}
	}
}

// waitOrKill gives the group `grace` to go after TERM and then kills it.
// Returns true when TERM was enough. It always waits for the child to be
// reaped afterwards: a stop that returned before the process was gone would be
// the exact thing 137 exists to promise cannot happen.
func waitOrKill(pid int, done <-chan struct{}, grace time.Duration) bool {
	if grace <= 0 {
		select {
		case <-done:
			return true
		default:
		}
		signalGroup(pid, syscall.SIGKILL)
		<-done
		return false
	}
	t := time.NewTimer(grace)
	defer t.Stop()
	select {
	case <-done:
		return true
	case <-t.C:
		signalGroup(pid, syscall.SIGKILL)
		<-done
		return false
	}
}
