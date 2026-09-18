// SPDX-License-Identifier: Apache-2.0
//
// verdict.go — what happened, in three words that do not overlap.
//
// Deciding an authentication failure per engine is not fussiness. codex prints
// MCP HTTP 401s to stderr on runs that succeeded; reusing claude's pattern
// would halt the whole tool the first time codex exited non-zero for any
// unrelated reason. The patterns below are the shell's `grep -E` patterns
// unchanged, and they are matched line by line because that is what grep did:
// `api key.*(missing|invalid)` is a statement about one line, not about a file.
package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strconv"
)

var (
	claudeAuthPattern = regexp.MustCompile(
		`(?i)401|403|unauthorized|forbidden|expired|invalid_token|authentication failed|credentials`)
	codexAuthPattern = regexp.MustCompile(
		`(?i)not logged in|codex login|401 unauthorized|refresh token|token expired`)
	// The lines codex prints from its MCP client are about somebody else's
	// HTTP, not about this account, and they appear on runs that worked.
	codexNotOursPattern = regexp.MustCompile(`rmcp::|mcp-client|models_manager`)
	opencodeAuthPattern = regexp.MustCompile(
		`(?i)unauthorized|forbidden|authentication|not authenticated|invalid api key|api key.*(missing|invalid)|credentials.*(missing|invalid)`)
)

// isAuthError is engine_is_auth_error. A successful run is never an auth
// failure, whatever it printed.
func isAuthError(engine string, rc int, stderrPath string) bool {
	if rc == 0 {
		return false
	}
	f, err := os.Open(stderrPath)
	if err != nil {
		return false
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	// An engine that dies mid-sentence can leave a very long line; the default
	// 64KiB would stop the scan there and report no auth failure on a file
	// that holds one further down.
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		switch engine {
		case "claude":
			if claudeAuthPattern.MatchString(line) {
				return true
			}
		case "codex":
			if codexNotOursPattern.MatchString(line) {
				continue
			}
			if codexAuthPattern.MatchString(line) {
				return true
			}
		case "opencode":
			if opencodeAuthPattern.MatchString(line) {
				return true
			}
		default:
			return false
		}
	}
	return false
}

// verdictOf is engine_verdict. rc 124 and 137 come from the watchdog and mean
// the wall clock ran out.
func verdictOf(engine string, rc int, stderrPath, rawPath string) string {
	if rc == exitTimedOut || rc == exitKilled {
		return "timeout"
	}
	if isAuthError(engine, rc, stderrPath) {
		return "auth"
	}
	if engine == "opencode" && readable(rawPath) {
		if rc != 0 && opencodeHasAuthError(rawPath) {
			return "auth"
		}
		// The current CLI sets a non-zero process status for an error event.
		// Keep the event check as well: it is the engine's structured
		// statement, and a future CLI must not turn one into a collected
		// success by changing only its process-exit convention.
		if opencodeHasError(rawPath) {
			return "error"
		}
	}
	if rc != 0 {
		return "error"
	}
	// claude reports a failed run inside a successful process exit, on the
	// same result object the telemetry is read from. Reading the file rather
	// than its last line matters now that the executor streams: the run's own
	// `is_error` is on that object, and a stream is a hundred events that are
	// not it.
	if engine == "claude" && readable(rawPath) {
		if final := claudeResultObject(rawPath); final != nil {
			if m, ok := obj(final); ok {
				if v, present := m["is_error"]; present && v == true {
					return "error"
				}
			}
		}
	}
	return "ok"
}

func readable(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}

// attemptOutcome is engine_attempt_outcome: the same judgement as the verdict,
// under a name that cannot be misread as a statement that the work was right.
// `ok` has always meant "the attempt ran and its output was collected", which
// no runtime is in a position to widen (§8.3). There is no value here that
// means the task was done.
func attemptOutcome(verdict string) string {
	switch verdict {
	case "ok":
		return "COLLECTED"
	case "timeout":
		return "TIMED_OUT"
	case "auth":
		return "AUTH_FAILED"
	case "error":
		return "FAILED"
	default:
		return "UNKNOWN"
	}
}

func cmdVerdict(args []string) int {
	if len(args) != 4 {
		errf("usage: hzl-exec verdict <engine> <rc> <stderr-file> <raw-file>")
		return 2
	}
	rc, err := strconv.Atoi(args[1])
	if err != nil {
		errf("verdict: exit status is not a number: %s", args[1])
		return 2
	}
	fmt.Print(verdictOf(args[0], rc, args[2], args[3]))
	return 0
}

// cmdAuthcheck keeps engine_is_auth_error's shape: the answer is the exit
// status, so that a shell caller writes `if hzl-exec authcheck ...` exactly
// where it used to write `if engine_is_auth_error ...`.
func cmdAuthcheck(args []string) int {
	if len(args) != 3 {
		errf("usage: hzl-exec authcheck <engine> <rc> <stderr-file>")
		return 2
	}
	rc, err := strconv.Atoi(args[1])
	if err != nil {
		return 1
	}
	if isAuthError(args[0], rc, args[2]) {
		return 0
	}
	return 1
}

func cmdOutcome(args []string) int {
	if len(args) != 1 {
		errf("usage: hzl-exec outcome <verdict>")
		return 2
	}
	fmt.Print(attemptOutcome(args[0]))
	return 0
}
