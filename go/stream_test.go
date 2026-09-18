// SPDX-License-Identifier: Apache-2.0
//
// stream_test.go — reading output that may have been cut off mid-write.
//
// Fixed bytes on disk, never a real engine: none of this costs anything or
// needs a network. The cut-off cases are the reason this file exists — a
// strict parser that rejected the whole input because of one half-written last
// line would throw away the evidence of what the run actually did.
package main

import (
	"os"
	"path/filepath"
	"testing"
)

func fixture(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "raw")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// The reviewer's single object, pretty-printed over several lines. This is the
// shape every claude record written before the executor started streaming has,
// so it is not only the reviewer's.
func TestClaudeSingleObjectOverSeveralLines(t *testing.T) {
	p := fixture(t, `{
  "type": "result",
  "session_id": "sess-1",
  "total_cost_usd": 0.25,
  "num_turns": 4,
  "usage": {"input_tokens": 11, "output_tokens": 22},
  "modelUsage": {"sonnet": {}, "opus": {}},
  "result": "first line\nsecond line"
}`)
	got := parseClaude(p)
	if !got.present {
		t.Fatal("nothing parsed")
	}
	if got.sessionID == nil || *got.sessionID != "sess-1" {
		t.Fatalf("session_id: %v", got.sessionID)
	}
	if got.costUSD == nil || *got.costUSD != 0.25 {
		t.Fatalf("cost_usd: %v", got.costUSD)
	}
	if got.turns != 4 || got.tokensIn != 11 || got.tokensOut != 22 {
		t.Fatalf("figures: %+v", got)
	}
	// jq's `keys` is sorted, and the record is compared between runs.
	if len(got.modelsUsed) != 2 || got.modelsUsed[0] != "opus" || got.modelsUsed[1] != "sonnet" {
		t.Fatalf("models_used is not sorted: %v", got.modelsUsed)
	}
	if got.text != "first line\nsecond line" {
		t.Fatalf("text: %q", got.text)
	}
}

// The executor streams, and the figures are on the one object the CLI marks as
// the result — not on the last event, which is a different thing.
func TestClaudeStreamReadsTheResultObject(t *testing.T) {
	p := fixture(t, `{"type":"system","session_id":"sess-2"}
{"type":"assistant","session_id":"sess-2"}
{"type":"result","session_id":"sess-2","num_turns":3,"result":"done","usage":{"input_tokens":5,"output_tokens":6}}
`)
	got := parseClaude(p)
	if got.turns != 3 || got.text != "done" {
		t.Fatalf("%+v", got)
	}
}

// A stream killed at the deadline. The complete events before the cut are the
// evidence, and losing them to one half-written line is the failure this
// second reading exists to prevent.
func TestClaudeTruncatedStreamKeepsWhatParsed(t *testing.T) {
	p := fixture(t, `{"type":"system","session_id":"sess-cut"}
{"type":"assistant","session_id":"sess-cut"}
{"type":"assistant","sess`)
	got := parseClaude(p)
	if !got.present {
		t.Fatal("a truncated stream lost everything before the cut")
	}
	if got.sessionID == nil || *got.sessionID != "sess-cut" {
		t.Fatalf("session_id: %v", got.sessionID)
	}
	// No result object, so no figures — reported as absent, not as zero spend.
	if got.costUSD != nil {
		t.Fatalf("cost_usd should be absent, got %v", *got.costUSD)
	}
}

// Nothing at all is nothing, never an object of defaults: an empty, absent or
// unreadable file must stay distinguishable from a run that reported zeroes.
func TestClaudeNothingParsesAsNothing(t *testing.T) {
	if parseClaude(fixture(t, "")).present {
		t.Fatal("an empty file parsed as something")
	}
	if parseClaude(filepath.Join(t.TempDir(), "absent")).present {
		t.Fatal("an absent file parsed as something")
	}
	if parseClaude(fixture(t, "not json at all\n")).present {
		t.Fatal("garbage parsed as something")
	}
}

func TestOpencodePartialFinalEventKeepsCompletedTelemetry(t *testing.T) {
	p := fixture(t, `{"type":"step_finish","sessionID":"oc-cut","part":{"cost":0.02,"tokens":{"input":4,"output":2}}}
{"type":"text","sessionID":"oc-cut","part":`)
	got := parseOpencode(p)
	if got.turns != 1 || got.tokensIn != 4 || got.tokensOut != 2 {
		t.Fatalf("%+v", got)
	}
	if got.costUSD == nil || *got.costUSD != 0.02 {
		t.Fatalf("cost_usd: %v", got.costUSD)
	}
	if got.text != "" {
		t.Fatalf("a half-written text event became text: %q", got.text)
	}
}

// No steps is not zero spend. OpenCode reporting nothing and OpenCode
// reporting nothing spent are different statements.
func TestOpencodeWithNoStepsReportsNoCost(t *testing.T) {
	got := parseOpencode(fixture(t, `{"type":"text","sessionID":"oc","part":{"text":"hi"}}`+"\n"))
	if got.costUSD != nil {
		t.Fatalf("cost_usd should be absent, got %v", *got.costUSD)
	}
	if got.text != "hi" {
		t.Fatalf("text: %q", got.text)
	}
}

func TestCodexReadsTheLastUsageItReported(t *testing.T) {
	p := fixture(t, `{"session_id":"cx-1"}
{"usage":{"input_tokens":1,"output_tokens":2}}
{"usage":{"input_tokens":30,"output_tokens":40}}
`)
	got := parseCodex(p)
	if got.tokensIn != 30 || got.tokensOut != 40 {
		t.Fatalf("%+v", got)
	}
	if got.sessionID == nil || *got.sessionID != "cx-1" {
		t.Fatalf("session_id: %v", got.sessionID)
	}
	// codex telemetry carries no USD figure at all.
	if got.costUSD != nil {
		t.Fatalf("codex reported a cost it does not have: %v", *got.costUSD)
	}
}
