// SPDX-License-Identifier: Apache-2.0
//
// stream.go — reading what an agent CLI wrote.
//
// Three engines, three shapes, one normalised set of figures. The shapes are
// not interchangeable and the differences are not cosmetic:
//
//	claude    the reviewer is handed `--output-format json` and writes one
//	          object; the executor is handed `stream-json` and writes one
//	          object per line so that a run in progress is something `tail -f`
//	          has anything to say about. Both end in the same object, the one
//	          marked "type":"result", and that is the only one anything reads.
//	codex     JSONL events, no USD figure anywhere in its telemetry.
//	opencode  JSONL events, with the spend on each step_finish part.
//
// The reading is done twice for claude, and the reason is the whole point of
// this file. A file that was written to the end parses as a sequence of JSON
// values. A file cut off at the deadline does not — and a strict parser that
// rejects the input because of one half-written last line throws away the
// hundred complete events before it, which are the evidence of what the run
// actually did. So: parse the whole thing; if that fails, parse line by line
// and keep every line that stood up on its own.
//
// Nothing at all reads as nothing, never as an object of defaults. An empty,
// absent or unreadable file has to stay distinguishable from a run that
// genuinely reported zeroes.
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"sort"
	"strings"
)

// The engine-independent figures. Pointers where a value's absence is itself
// information: a run with no session is not a run with session "", and an
// engine that reports no cost is not an engine that reported zero.
type parsed struct {
	present    bool
	sessionID  *string
	costUSD    *float64
	turns      int64
	tokensIn   int64
	tokensOut  int64
	modelsUsed []string
	text       string
}

// decodeStream reads the file as a sequence of JSON values, which is what
// `jq -s` does: one pretty-printed object however many lines it spans, or a
// JSONL file as the sequence it is. Any trailing garbage fails the whole read,
// exactly as it did before, and the caller falls back.
func decodeStream(path string) ([]any, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	dec := json.NewDecoder(f)
	dec.UseNumber()
	var out []any
	for {
		var v any
		if err := dec.Decode(&v); err != nil {
			if err == io.EOF {
				return out, nil
			}
			return nil, err
		}
		out = append(out, v)
	}
}

// decodeLines reads the file a line at a time and keeps the lines that parsed,
// which is `fromjson?`. This is the reading for a file that is still being
// written, or was cut off at the deadline.
func decodeLines(path string) []any {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var out []any
	for _, line := range bytes.Split(body, []byte("\n")) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		dec := json.NewDecoder(bytes.NewReader(line))
		dec.UseNumber()
		var v any
		if err := dec.Decode(&v); err != nil {
			continue
		}
		out = append(out, v)
	}
	return out
}

// --- reading values out of a decoded event ---------------------------------
//
// These reproduce jq's `//`, which treats null and false as absent. That is
// not pedantry: `.total_cost_usd // null` and `.num_turns // 0` are how a
// half-filled result object ends up with honest defaults rather than with
// Go's zero values silently standing in for figures nobody reported.

func obj(v any) (map[string]any, bool) {
	m, ok := v.(map[string]any)
	return m, ok
}

// field walks a path, returning the value only if every step existed.
func field(v any, path ...string) any {
	cur := v
	for _, key := range path {
		m, ok := obj(cur)
		if !ok {
			return nil
		}
		cur, ok = m[key]
		if !ok {
			return nil
		}
	}
	// jq's `//` passes over null and false alike.
	if cur == nil || cur == false {
		return nil
	}
	return cur
}

func stringOf(v any) (string, bool) {
	s, ok := v.(string)
	return s, ok
}

func intOf(v any) int64 {
	n, ok := v.(json.Number)
	if !ok {
		return 0
	}
	i, err := n.Int64()
	if err != nil {
		f, ferr := n.Float64()
		if ferr != nil {
			return 0
		}
		return int64(f)
	}
	return i
}

func floatOf(v any) (float64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	f, err := n.Float64()
	if err != nil {
		return 0, false
	}
	return f, true
}

// --- claude -----------------------------------------------------------------

// claudeResultObject finds the object the run's figures live on: the one the
// CLI marked as the result, else the last object that parsed — which is what
// reads the reviewer's single object, and what leaves an interrupted stream
// still naming the session it got as far as.
func claudeResultObject(path string) any {
	pick := func(vals []any) any {
		var last any
		var lastResult any
		for _, v := range vals {
			last = v
			if t := field(v, "type"); t != nil {
				if s, ok := stringOf(t); ok && s == "result" {
					lastResult = v
				}
			}
		}
		if lastResult != nil {
			return lastResult
		}
		// `// empty`: a last value of null or false is nothing, not a value.
		if last == nil || last == false {
			return nil
		}
		return last
	}
	if vals, err := decodeStream(path); err == nil {
		if got := pick(vals); got != nil {
			return got
		}
	}
	return pick(decodeLines(path))
}

func parseClaude(path string) parsed {
	final := claudeResultObject(path)
	if final == nil {
		return parsed{}
	}
	p := parsed{present: true, modelsUsed: []string{}}
	if s, ok := stringOf(field(final, "session_id")); ok {
		p.sessionID = &s
	}
	if f, ok := floatOf(field(final, "total_cost_usd")); ok {
		p.costUSD = &f
	}
	p.turns = intOf(field(final, "num_turns"))
	p.tokensIn = intOf(field(final, "usage", "input_tokens"))
	p.tokensOut = intOf(field(final, "usage", "output_tokens"))
	// `model` and `effort` are what was asked for; models_used is what
	// actually ran. They differ when an inherited setting overrides the
	// request, and without both there is no way to find that out afterwards.
	if m, ok := obj(field(final, "modelUsage")); ok {
		for k := range m {
			p.modelsUsed = append(p.modelsUsed, k)
		}
		sort.Strings(p.modelsUsed) // jq's `keys` is sorted
	}
	if s, ok := stringOf(field(final, "result")); ok {
		p.text = s
	}
	return p
}

// --- codex ------------------------------------------------------------------

func parseCodex(path string) parsed {
	vals, err := decodeStream(path)
	if err != nil {
		// The strict reading is the only one codex ever had. A file it cannot
		// read reports nothing rather than a shape full of defaults.
		return parsed{}
	}
	p := parsed{present: true, modelsUsed: []string{}}
	for _, v := range vals {
		if s, ok := stringOf(field(v, "session_id")); ok {
			p.sessionID = &s
		}
		if n := field(v, "usage", "input_tokens"); n != nil {
			p.tokensIn = intOf(n)
		}
		if n := field(v, "usage", "output_tokens"); n != nil {
			p.tokensOut = intOf(n)
		}
	}
	return p
}

// --- opencode ---------------------------------------------------------------

func opencodeEvents(path string) []any { return decodeLines(path) }

func parseOpencode(path string) parsed {
	events := opencodeEvents(path)
	p := parsed{present: true, modelsUsed: []string{}}
	var steps []any
	for _, e := range events {
		if s, ok := stringOf(field(e, "sessionID")); ok {
			p.sessionID = &s
		}
		t, _ := stringOf(field(e, "type"))
		switch t {
		case "step_finish":
			if part := field(e, "part"); part != nil {
				steps = append(steps, part)
			}
		case "text":
			if s, ok := stringOf(field(e, "part", "text")); ok {
				p.text = s
			}
		}
	}
	p.turns = int64(len(steps))
	if len(steps) > 0 {
		var cost float64
		for _, s := range steps {
			if f, ok := floatOf(field(s, "cost")); ok {
				cost += f
			}
			p.tokensIn += intOf(field(s, "tokens", "input"))
			p.tokensOut += intOf(field(s, "tokens", "output"))
		}
		p.costUSD = &cost
	}
	return p
}

func opencodeHasError(path string) bool {
	for _, e := range opencodeEvents(path) {
		if s, ok := stringOf(field(e, "type")); ok && s == "error" {
			return true
		}
	}
	return false
}

// opencodeHasAuthError asks the same question of the whole error value, not of
// a field on it, because the CLI has moved where it puts the message. jq's
// `tostring` over the object is reproduced by re-encoding it.
func opencodeHasAuthError(path string) bool {
	for _, e := range opencodeEvents(path) {
		s, ok := stringOf(field(e, "type"))
		if !ok || s != "error" {
			continue
		}
		v := field(e, "error")
		if v == nil {
			v = e
		}
		var text string
		if s, ok := stringOf(v); ok {
			text = s
		} else {
			body, err := json.Marshal(v)
			if err != nil {
				continue
			}
			text = string(body)
		}
		if opencodeAuthPattern.MatchString(strings.ToLower(text)) {
			return true
		}
	}
	return false
}

// --- the parse, on its own --------------------------------------------------

// parsedJSON is the shape the shell's _engine_result_* functions printed, kept
// so that the parsers can be asserted on a fixture file without running an
// engine or building a whole result record. Nothing in the running program
// reads it; the test suite does, which is the point — a reader this delicate
// needs to be checkable against bytes on disk.
type parsedJSON struct {
	SessionID  *string  `json:"session_id"`
	CostUSD    *float64 `json:"cost_usd"`
	Turns      int64    `json:"turns"`
	TokensIn   int64    `json:"tokens_in"`
	TokensOut  int64    `json:"tokens_out"`
	ModelsUsed []string `json:"models_used"`
	Text       string   `json:"text"`
}

func parseFor(engine, path string) parsed {
	switch engine {
	case "claude":
		return parseClaude(path)
	case "codex":
		return parseCodex(path)
	case "opencode":
		return parseOpencode(path)
	}
	return parsed{}
}

func cmdParse(args []string) int {
	if len(args) != 2 {
		errf("usage: hzl-exec parse <engine> <raw-file>")
		return 2
	}
	p := parseFor(args[0], args[1])
	// Nothing parsed prints nothing, never an object of defaults: an empty,
	// absent or unreadable file has to stay distinguishable from a run that
	// reported zeroes.
	if !p.present {
		return 0
	}
	models := p.modelsUsed
	if models == nil {
		models = []string{}
	}
	body, err := json.Marshal(parsedJSON{
		SessionID:  p.sessionID,
		CostUSD:    p.costUSD,
		Turns:      p.turns,
		TokensIn:   p.tokensIn,
		TokensOut:  p.tokensOut,
		ModelsUsed: models,
		Text:       p.text,
	})
	if err != nil {
		errf("%v", err)
		return 1
	}
	os.Stdout.Write(body)
	return 0
}
