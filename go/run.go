// SPDX-License-Identifier: Apache-2.0
//
// run.go — the local runtime backend: start what the launch spec names, hold
// it to the run spec's wall clock, write down what was observed.
//
// This is lib/runtimes/local.sh. It knows what an executable, an argument and
// a second are, and nothing about engines, roles or what any of the arguments
// it passes on mean (docs/RUNTIME-BACKENDS.md §8.4).
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

type runSpec struct {
	SchemaVersion int    `json:"schema_version"`
	Cwd           string `json:"cwd"`
	TimeoutSec    *int   `json:"timeout_sec"`
	KillAfterSec  *int   `json:"kill_after_sec"`
	StdoutPath    string `json:"stdout_path"`
	StderrPath    string `json:"stderr_path"`
	OutputPath    string `json:"output_path"`
}

// The defaults the shell carried in its jq reads. They are here and nowhere
// else: a run spec written by an older build is missing them, and a build that
// guessed differently in two places would run two different wall clocks.
const (
	defaultTimeoutSec   = 3600
	defaultKillAfterSec = 30
)

// What the backend observed. The three paths are written back out so that a
// later reader does not have to remember the output directory's layout.
type collected struct {
	SchemaVersion int    `json:"schema_version"`
	ExitCode      int    `json:"exit_code"`
	DurationSec   int    `json:"duration_sec"`
	StdoutPath    string `json:"stdout_path"`
	StderrPath    string `json:"stderr_path"`
	OutputPath    string `json:"output_path"`
}

func loadRunSpec(path string) (*runSpec, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read run spec: %w", err)
	}
	spec := &runSpec{}
	if err := json.Unmarshal(raw, spec); err != nil {
		return nil, fmt.Errorf("run spec is not readable JSON: %w", err)
	}
	if spec.TimeoutSec == nil {
		d := defaultTimeoutSec
		spec.TimeoutSec = &d
	}
	if spec.KillAfterSec == nil {
		d := defaultKillAfterSec
		spec.KillAfterSec = &d
	}
	return spec, nil
}

// Same directory, then rename: a reader never sees half a record, and the
// rename is the moment the run became observable (§8.4).
func writeJSONAtomic(path string, v any) error {
	body, err := json.Marshal(v)
	if err != nil {
		return err
	}
	body = append(body, '\n')
	tmp := path + ".tmp"
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(tmp, body, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func cmdRun(args []string) int {
	if len(args) != 3 {
		errf("usage: hzl-exec run <launch.json> <run.json> <collected.json>")
		return 2
	}
	launchPath, runPath, collectedPath := args[0], args[1], args[2]

	// Everything that can be refused is refused before anything is started,
	// and a refusal leaves no collected record behind: a launch that never
	// reached a process must not be readable as one that did.
	launch, err := loadLaunch(launchPath)
	if err != nil {
		errf("%v", err)
		return 1
	}
	run, err := loadRunSpec(runPath)
	if err != nil {
		errf("%v", err)
		return 1
	}
	if len(launch.Argv) == 0 {
		errf("launch spec has an empty argv")
		return 1
	}
	if run.Cwd == "" {
		errf("run spec names no working directory")
		return 1
	}
	if st, err := os.Stat(run.Cwd); err != nil || !st.IsDir() {
		errf("cannot cd to %s", run.Cwd)
		return 1
	}

	stdout, err := os.OpenFile(run.StdoutPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		errf("cannot write %s: %v", run.StdoutPath, err)
		return 1
	}
	defer stdout.Close()
	stderr, err := os.OpenFile(run.StderrPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		errf("cannot write %s: %v", run.StderrPath, err)
		return 1
	}
	defer stderr.Close()

	// A batch engine run gets no stdin at all; see procSpec.stdin.
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		errf("cannot open %s: %v", os.DevNull, err)
		return 1
	}
	defer devnull.Close()

	out := runProc(procSpec{
		executable: launch.Executable,
		argv:       launch.Argv,
		env:        launch.environ(),
		dir:        run.Cwd,
		stdin:      devnull,
		stdout:     stdout,
		stderr:     stderr,
		timeout:    time.Duration(*run.TimeoutSec) * time.Second,
		killAfter:  time.Duration(*run.KillAfterSec) * time.Second,
	})

	rec := collected{
		SchemaVersion: 1,
		ExitCode:      out.exitCode,
		DurationSec:   int(out.ended.Sub(out.started).Seconds()),
		StdoutPath:    run.StdoutPath,
		StderrPath:    run.StderrPath,
		OutputPath:    run.OutputPath,
	}
	if err := writeJSONAtomic(collectedPath, rec); err != nil {
		errf("cannot write %s: %v", collectedPath, err)
		return 1
	}
	return out.exitCode
}

// cmdTimeout is the same wall clock with no spec files, for the two places
// that ask a CLI a question rather than running a job: `claude -p /usage` and
// the codex app-server probe behind it.
func cmdTimeout(args []string) int {
	if len(args) < 3 {
		errf("usage: hzl-exec timeout <kill_after_sec> <timeout_sec> <command> [args...]")
		return exitRefused
	}
	killAfter, err := strconv.Atoi(args[0])
	if err != nil || killAfter < 0 {
		return exitRefused
	}
	timeout, err := strconv.Atoi(args[1])
	if err != nil || timeout < 0 {
		return exitRefused
	}
	// stdin is inherited here: `hzl_timeout ... codex app-server` sits in a
	// pipeline whose left-hand side is the request it must read.
	out := runProc(procSpec{
		executable: args[2],
		argv:       args[3:],
		stdin:      os.Stdin,
		stdout:     os.Stdout,
		stderr:     os.Stderr,
		timeout:    time.Duration(timeout) * time.Second,
		killAfter:  time.Duration(killAfter) * time.Second,
	})
	return out.exitCode
}
