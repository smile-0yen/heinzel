// SPDX-License-Identifier: Apache-2.0
//
// normalize.go — what the runtime collected, turned into the one record every
// caller reads.
//
// The engine is read back out of the launch spec rather than passed again, so
// that the two cannot disagree about which engine produced the output being
// read. The backend is the one argument that cannot be read out of either
// file: it is the caller's choice of where this ran.
//
// The record is v2. Every v1 field is still here, in the same place, with the
// same meaning, and the four additions are additions: a reader that knows only
// v1 cannot tell the difference (docs/RUNTIME-BACKENDS.md §13.7).
package main

import (
	"encoding/json"
	"os"
	"strconv"
)

// The schema version is Heinzel's, not this binary's, so it arrives from the
// shell that owns the constant. The fallback is the value HEINZEL_RESULT_SCHEMA
// holds today and the test suite asserts the two are the same — which is the
// only way a constant living in two languages stays one constant.
const defaultResultSchema = 2

// Field order is the order the record has always been written in. It is not
// load-bearing for any reader, and it is kept anyway: a diff between a record
// written before this binary and one written after should show what changed,
// not where everything moved to.
type resultRecord struct {
	SchemaVersion  int      `json:"schema_version"`
	Engine         string   `json:"engine"`
	Role           string   `json:"role"`
	Model          string   `json:"model"`
	Effort         string   `json:"effort"`
	ModelsUsed     []string `json:"models_used"`
	ExitCode       int      `json:"exit_code"`
	Verdict        string   `json:"verdict"`
	DurationSec    int64    `json:"duration_sec"`
	SessionID      *string  `json:"session_id"`
	CostUSD        *float64 `json:"cost_usd"`
	TokensIn       int64    `json:"tokens_in"`
	TokensOut      int64    `json:"tokens_out"`
	Turns          int64    `json:"turns"`
	Text           string   `json:"text"`
	Backend        string   `json:"backend"`
	RuntimeState   string   `json:"runtime_state"`
	NativeExitCode *int     `json:"native_exit_code"`
	AttemptOutcome string   `json:"attempt_outcome"`
}

func resultSchemaVersion() int {
	if v := os.Getenv("HEINZEL_RESULT_SCHEMA"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return defaultResultSchema
}

// writeLastText puts the engine's final message where every engine's final
// message goes. A message that exists is written with the trailing newline a
// text file ends in; no message writes no file content at all. The distinction
// matters: ending an absent message with a newline would record a run that was
// cut off before it said anything as having said one blank line, which is not
// the same thing as having said nothing.
func writeLastText(path, text string) error {
	body := ""
	if text != "" {
		body = text + "\n"
	}
	return os.WriteFile(path, []byte(body), 0o644)
}

func cmdNormalize(args []string) int {
	if len(args) < 3 || len(args) > 4 {
		errf("usage: hzl-exec normalize <launch.json> <collected.json> <result.json> [backend]")
		return 2
	}
	launchPath, collectedPath, resultPath := args[0], args[1], args[2]
	backend := "local"
	if len(args) == 4 && args[3] != "" {
		backend = args[3]
	}

	launch, err := loadLaunch(launchPath)
	if err != nil {
		errf("%v", err)
		return 1
	}

	raw, err := os.ReadFile(collectedPath)
	if err != nil {
		errf("cannot read collected record: %v", err)
		return 1
	}
	var col struct {
		ExitCode    *int   `json:"exit_code"`
		DurationSec int64  `json:"duration_sec"`
		StdoutPath  string `json:"stdout_path"`
		StderrPath  string `json:"stderr_path"`
		OutputPath  string `json:"output_path"`
	}
	if err := json.Unmarshal(raw, &col); err != nil {
		errf("collected record is not readable JSON: %v", err)
		return 1
	}
	if col.ExitCode == nil {
		errf("collected record has no exit status")
		return 1
	}
	rc := *col.ExitCode

	var p parsed
	switch launch.Engine {
	case "claude":
		p = parseClaude(col.StdoutPath)
		// claude reports its final message inside its own JSON; codex was
		// told to write it out itself. Both end up in the same file.
		if err := writeLastText(col.OutputPath, p.text); err != nil {
			errf("cannot write %s: %v", col.OutputPath, err)
			return 1
		}
	case "codex":
		p = parseCodex(col.StdoutPath)
	case "opencode":
		p = parseOpencode(col.StdoutPath)
		// Unlike codex, OpenCode has no output-file flag. Its final completed
		// text part goes in the common location before the record is built.
		if err := writeLastText(col.OutputPath, p.text); err != nil {
			errf("cannot write %s: %v", col.OutputPath, err)
			return 1
		}
	}

	verdict := verdictOf(launch.Engine, rc, col.StderrPath, col.StdoutPath)

	// 124, 137 and 125 are Heinzel's own codes, not the command's (SPEC §9.3):
	// the watchdog ended it, or refused to start it. `exit_code` keeps
	// carrying them because a decade of readers expect a number there, and
	// `native_exit_code` says plainly that the process's own status is not
	// known. The same field is null for a backend whose agent settles without
	// a process exit at all, which is the case it exists for (§13.7).
	var native *int
	switch rc {
	case exitTimedOut, exitKilled, exitRefused:
	default:
		n := rc
		native = &n
	}

	// The text in the record is the file's, not the parse's: codex writes that
	// file itself and nothing here has ever second-guessed it.
	text, err := os.ReadFile(col.OutputPath)
	if err != nil {
		errf("cannot read %s: %v", col.OutputPath, err)
		return 1
	}

	models := p.modelsUsed
	if models == nil {
		models = []string{}
	}

	rec := resultRecord{
		SchemaVersion: resultSchemaVersion(),
		Engine:        launch.Engine,
		Role:          launch.Role,
		Model:         launch.Model,
		Effort:        launch.Effort,
		ModelsUsed:    models,
		ExitCode:      rc,
		Verdict:       verdict,
		DurationSec:   col.DurationSec,
		SessionID:     p.sessionID,
		CostUSD:       p.costUSD,
		TokensIn:      p.tokensIn,
		TokensOut:     p.tokensOut,
		Turns:         p.turns,
		Text:          string(text),
		Backend:       backend,
		// `runtime_state` is EXITED for every batch run, whatever the backend:
		// the batch contract is run-to-completion, so a collected record
		// existing at all is the observation that the process terminated. The
		// states that are not EXITED — SETTLED, LOST, UNREACHABLE (§9.1) —
		// belong to an agent that outlives the call that started it, and
		// arrive with the backend that has one.
		RuntimeState:   "EXITED",
		NativeExitCode: native,
		AttemptOutcome: attemptOutcome(verdict),
	}

	if err := writeJSONAtomic(resultPath, rec); err != nil {
		errf("cannot write %s: %v", resultPath, err)
		return 1
	}

	return 0
}
