// SPDX-License-Identifier: Apache-2.0
//
// proc_test.go — the wall clock, and the promise that comes with it.
//
// These are the assertions tests/test.sh made of lib/watchdog.sh, moved to the
// side of the boundary that now implements them. The one that matters most is
// the last: an engine's own subprocesses must die with it, because a
// grandchild that survives a timeout keeps running and keeps billing.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func run(t *testing.T, timeout, killAfter time.Duration, name string, args ...string) procOutcome {
	t.Helper()
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer devnull.Close()
	return runProc(procSpec{
		executable: name,
		argv:       args,
		dir:        t.TempDir(),
		stdin:      devnull,
		stdout:     devnull,
		stderr:     devnull,
		timeout:    timeout,
		killAfter:  killAfter,
	})
}

func TestExitStatusIsPassedThrough(t *testing.T) {
	if got := run(t, 5*time.Second, 5*time.Second, "/bin/sh", "-c", "exit 7").exitCode; got != 7 {
		t.Fatalf("exit status: want 7, got %d", got)
	}
	if got := run(t, 5*time.Second, 5*time.Second, "/bin/sh", "-c", "exit 0").exitCode; got != 0 {
		t.Fatalf("success: want 0, got %d", got)
	}
}

func TestExceedingTheWallClockIs124(t *testing.T) {
	if got := run(t, time.Second, 5*time.Second, "/bin/sleep", "30").exitCode; got != exitTimedOut {
		t.Fatalf("want %d, got %d", exitTimedOut, got)
	}
}

// 137 is the promise that the wall-clock budget cannot be declined by the thing
// being budgeted.
func TestACommandThatIgnoresTERMIsKilled(t *testing.T) {
	out := run(t, time.Second, time.Second, "/bin/sh", "-c",
		"trap '' TERM; while :; do sleep 1; done")
	if out.exitCode != exitKilled {
		t.Fatalf("want %d, got %d", exitKilled, out.exitCode)
	}
}

func TestNothingToStartIs127(t *testing.T) {
	if got := run(t, time.Second, time.Second, "hzl-no-such-command-anywhere").exitCode; got != exitNotFound {
		t.Fatalf("want %d, got %d", exitNotFound, got)
	}
}

// The reason the child leads its own process group. A grandchild that survives
// the timeout is an engine subprocess nobody is watching any more.
func TestTheWholeProcessGroupDiesNotJustTheChild(t *testing.T) {
	dir := t.TempDir()
	pidfile := filepath.Join(dir, "grandchild.pid")
	out := run(t, time.Second, 2*time.Second, "/bin/sh", "-c",
		"sleep 30 & printf '%s\\n' \"$!\" >"+pidfile+"; wait")
	if out.exitCode != exitTimedOut {
		t.Fatalf("want a timeout (%d), got %d", exitTimedOut, out.exitCode)
	}

	body, err := os.ReadFile(pidfile)
	if err != nil {
		t.Fatalf("the child never recorded its own child: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(body)))
	if err != nil {
		t.Fatalf("unreadable pid %q: %v", body, err)
	}
	for i := 0; i < 40; i++ {
		if err := syscall.Kill(pid, 0); err != nil {
			return // gone, which is the whole assertion
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
	t.Fatalf("grandchild %d survived the timeout", pid)
}

// A stop from outside arrives as a signal to this process, and the engine is in
// a group of its own. Forwarding it is the only thing that reaches the engine,
// and it is the path `cancel_stop ... tree` takes.
func TestAStopFromOutsideReachesTheChild(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "hzl-exec-test")
	build := exec.Command("go", "build", "-o", bin, ".")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		t.Skipf("cannot build the binary under test: %v", err)
	}

	dir := t.TempDir()
	marker := filepath.Join(dir, "started")
	cmd := exec.Command(bin, "timeout", "5", "60", "/bin/sh", "-c",
		": >"+marker+"; sleep 60")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 100; i++ {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("a TERM was not carried down to the child: still running after 10s")
	}
}
