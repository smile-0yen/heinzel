// SPDX-License-Identifier: Apache-2.0
//
// verdict_test.go — telling apart the four things that can have happened.
//
// The engine-by-engine split is the point: codex prints MCP HTTP 401s to
// stderr on runs that succeeded, and applying claude's pattern to it would
// halt the whole tool the first time codex exited non-zero for an unrelated
// reason.
package main

import (
	"os"
	"path/filepath"
	"testing"
)

func errfile(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "stderr")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestASuccessfulRunIsNeverAnAuthFailure(t *testing.T) {
	if isAuthError("claude", 0, errfile(t, "401 unauthorized\n")) {
		t.Fatal("a run that exited 0 was called an auth failure")
	}
}

func TestClaudeAuthPatterns(t *testing.T) {
	if !isAuthError("claude", 1, errfile(t, "Error: 401 Unauthorized\n")) {
		t.Fatal("a 401 on a failed claude run is an auth error")
	}
	if isAuthError("claude", 1, errfile(t, "something else entirely\n")) {
		t.Fatal("an unrelated failure was called an auth error")
	}
}

// codex's MCP transport speaks about somebody else's HTTP, on runs that worked.
func TestCodexMCPTransport401IsNotTheAccountsAuthFailure(t *testing.T) {
	if isAuthError("codex", 1, errfile(t, "rmcp::transport: 401 unauthorized\n")) {
		t.Fatal("an MCP transport 401 was read as the account's own auth failure")
	}
	if !isAuthError("codex", 1, errfile(t, "You are not logged in. Run codex login.\n")) {
		t.Fatal("a real codex auth failure was missed")
	}
	// The excluded line must not suppress a real one further down the file.
	if !isAuthError("codex", 1, errfile(t, "rmcp::transport: 401 unauthorized\nnot logged in\n")) {
		t.Fatal("an excluded line hid a real auth failure on another line")
	}
}

func TestUnknownEngineIsNeverDiagnosedAsAuth(t *testing.T) {
	if isAuthError("nosuch", 1, errfile(t, "401 unauthorized\n")) {
		t.Fatal("an engine nobody knows was diagnosed anyway")
	}
}

// 124 and 137 come from the wall clock, and outrank everything the process may
// have printed on its way out.
func TestTheWallClockOutranksWhatWasPrinted(t *testing.T) {
	e := errfile(t, "401 unauthorized\n")
	for _, rc := range []int{exitTimedOut, exitKilled} {
		if got := verdictOf("claude", rc, e, "/nonexistent"); got != "timeout" {
			t.Fatalf("rc %d: want timeout, got %s", rc, got)
		}
	}
}

// claude reports a failed run inside a successful process exit, on the same
// object the telemetry is read from.
func TestClaudeReportsFailureInsideASuccessfulExit(t *testing.T) {
	raw := fixture(t, `{"type":"result","is_error":true,"session_id":"s"}`+"\n")
	if got := verdictOf("claude", 0, errfile(t, ""), raw); got != "error" {
		t.Fatalf("want error, got %s", got)
	}
	ok := fixture(t, `{"type":"result","is_error":false,"session_id":"s"}`+"\n")
	if got := verdictOf("claude", 0, errfile(t, ""), ok); got != "ok" {
		t.Fatalf("want ok, got %s", got)
	}
}

// OpenCode's structured error event stands even if a future CLI stops setting
// a non-zero process status for it.
func TestOpencodeErrorEventIsAnErrorOnItsOwn(t *testing.T) {
	raw := fixture(t, `{"type":"error","error":{"message":"the tool exploded"}}`+"\n")
	if got := verdictOf("opencode", 0, errfile(t, ""), raw); got != "error" {
		t.Fatalf("want error, got %s", got)
	}
}

func TestOpencodeAuthErrorOutranksAPlainError(t *testing.T) {
	raw := fixture(t, `{"type":"error","error":{"message":"invalid api key"}}`+"\n")
	if got := verdictOf("opencode", 1, errfile(t, ""), raw); got != "auth" {
		t.Fatalf("want auth, got %s", got)
	}
}

func TestAttemptOutcomeVocabulary(t *testing.T) {
	want := map[string]string{
		"ok":       "COLLECTED",
		"timeout":  "TIMED_OUT",
		"auth":     "AUTH_FAILED",
		"error":    "FAILED",
		"":         "UNKNOWN",
		"nonsense": "UNKNOWN",
	}
	for verdict, outcome := range want {
		if got := attemptOutcome(verdict); got != outcome {
			t.Fatalf("%q: want %s, got %s", verdict, outcome, got)
		}
	}
}
