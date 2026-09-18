// SPDX-License-Identifier: Apache-2.0
//
// launch.go — the launch spec, and what a process cannot be given.
//
// This is the validation that was a single jq program in
// lib/runtimes/local.sh, kept message for message so that a log line from
// before this binary and one from after say the same thing. The refusals are
// not defensive decoration: a spec is refused entirely rather than honoured in
// part (docs/RUNTIME-BACKENDS.md §8.1).
//
// The reason NUL is refused rather than escaped is worth keeping in one place.
// No OS argv or environ entry can carry a NUL byte — it is the terminator — so
// an argument holding one cannot be passed at all. In the shell version it was
// also the delimiter the spec was restored through, which made an argument
// holding one arrive as two. That second reason is gone here, because argv
// crosses into this process as a JSON array and is handed to execve as a slice
// of strings, with no line or byte to be split on. The first reason is not,
// and it is the one that mattered.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// A launch spec, read loosely on purpose: the fields are checked one at a time
// so that each can be refused in its own words, rather than as one decoder
// error naming a Go type the operator has never heard of.
type launchSpec struct {
	SchemaVersion int    `json:"schema_version"`
	Engine        string `json:"engine"`
	Role          string `json:"role"`
	Executable    string `json:"executable"`
	Model         string `json:"model"`
	Effort        string `json:"effort"`
	Argv          []string
	Env           map[string]string
}

var envNamePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func loadLaunch(path string) (*launchSpec, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read launch spec: %w", err)
	}
	var doc struct {
		SchemaVersion int               `json:"schema_version"`
		Engine        string            `json:"engine"`
		Role          string            `json:"role"`
		Executable    string            `json:"executable"`
		Model         string            `json:"model"`
		Effort        string            `json:"effort"`
		Argv          []json.RawMessage `json:"argv"`
		Env           json.RawMessage   `json:"env"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("launch spec is not readable JSON: %w", err)
	}

	spec := &launchSpec{
		SchemaVersion: doc.SchemaVersion,
		Engine:        doc.Engine,
		Role:          doc.Role,
		Executable:    doc.Executable,
		Model:         doc.Model,
		Effort:        doc.Effort,
		Env:           map[string]string{},
	}

	if spec.Executable == "" {
		return nil, fmt.Errorf("launch spec names no executable")
	}

	for _, item := range doc.Argv {
		var s string
		if err := json.Unmarshal(item, &s); err != nil {
			return nil, fmt.Errorf("launch spec has an argument that is not a string")
		}
		if strings.ContainsRune(s, 0) {
			return nil, fmt.Errorf("launch spec has an argument holding a NUL byte")
		}
		spec.Argv = append(spec.Argv, s)
	}

	// An absent env is an empty one. A present env that is not an object is a
	// different statement and gets its own refusal.
	if len(doc.Env) > 0 && string(doc.Env) != "null" {
		var env map[string]json.RawMessage
		if err := json.Unmarshal(doc.Env, &env); err != nil {
			return nil, fmt.Errorf("launch spec has an env that is not an object")
		}
		for name, rawValue := range env {
			if !envNamePattern.MatchString(name) {
				return nil, fmt.Errorf("launch spec has an environment name that is not a variable name")
			}
			var value string
			if err := json.Unmarshal(rawValue, &value); err != nil {
				return nil, fmt.Errorf("launch spec has an environment value that is not a string")
			}
			if strings.ContainsRune(value, 0) {
				return nil, fmt.Errorf("launch spec has an environment value holding a NUL byte")
			}
			spec.Env[name] = value
		}
	}

	return spec, nil
}

// The environment the child gets: this process's, with the spec's names set
// over it. That is what `env KEY=VALUE ... command` did in the shell, and the
// difference from replacing the environment wholesale is load-bearing — the
// engine still needs PATH and HOME, which launchd passes and the spec does not
// carry.
func (l *launchSpec) environ() []string {
	if len(l.Env) == 0 {
		return nil // nil means inherit, which is what os/exec does with it
	}
	out := os.Environ()
	for name, value := range l.Env {
		out = append(out, name+"="+value)
	}
	return out
}

// cmdRender prints the launch the way a shell would have to be handed it: the
// executable, then each argument, each one NUL-terminated. It is not a command
// string because a multi-line argument would stop being one argument, and the
// reviewer's --json-schema is a whole file.
func cmdRender(args []string) int {
	if len(args) != 1 {
		errf("usage: hzl-exec render <launch.json>")
		return 2
	}
	spec, err := loadLaunch(args[0])
	if err != nil {
		errf("%v", err)
		return 1
	}
	out := &strings.Builder{}
	out.WriteString(spec.Executable)
	out.WriteByte(0)
	for _, a := range spec.Argv {
		out.WriteString(a)
		out.WriteByte(0)
	}
	fmt.Print(out.String())
	return 0
}
