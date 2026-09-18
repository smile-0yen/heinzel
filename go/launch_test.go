// SPDX-License-Identifier: Apache-2.0
//
// launch_test.go — what a process cannot be given is refused before anything
// is started, and refused whole rather than honoured in part (§8.1).
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func spec(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "launch.json")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestALaunchSpecIsRead(t *testing.T) {
	got, err := loadLaunch(spec(t, `{"schema_version":1,"engine":"codex","role":"reviewer",
	  "executable":"codex","argv":["exec","--json"],"env":{"A":"b"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if got.Executable != "codex" || len(got.Argv) != 2 || got.Argv[1] != "--json" {
		t.Fatalf("%+v", got)
	}
	if got.Env["A"] != "b" {
		t.Fatalf("env: %v", got.Env)
	}
}

// A multi-line argument is one argument. The reviewer's --json-schema is a
// whole file, and a spec that split it would still launch — handing the engine
// several arguments of prose.
func TestAMultiLineArgumentSurvivesAsOneArgument(t *testing.T) {
	got, err := loadLaunch(spec(t, `{"executable":"claude","argv":["-p","first\nsecond"]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Argv) != 2 || got.Argv[1] != "first\nsecond" {
		t.Fatalf("%q", got.Argv)
	}
}

func TestTheRefusals(t *testing.T) {
	cases := []struct{ name, body, want string }{
		{"no executable", `{"argv":["x"]}`, "names no executable"},
		{"argument is not a string", `{"executable":"x","argv":[3]}`, "not a string"},
		{"NUL in an argument", "{\"executable\":\"x\",\"argv\":[\"a\\u0000b\"]}", "NUL byte"},
		{"env is not an object", `{"executable":"x","env":[1]}`, "not an object"},
		{"env name env could not set", `{"executable":"x","env":{"A B":"c"}}`, "not a variable name"},
		{"env value is not a string", `{"executable":"x","env":{"A":3}}`, "not a string"},
		{"NUL in an env value", "{\"executable\":\"x\",\"env\":{\"A\":\"a\\u0000b\"}}", "NUL byte"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := loadLaunch(spec(t, c.body))
			if err == nil {
				t.Fatalf("accepted: %s", c.body)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want a refusal mentioning %q, got: %v", c.want, err)
			}
		})
	}
}

// An absent env is an empty one; the child then inherits this process's
// environment, which is where PATH and HOME come from under launchd.
func TestAnAbsentEnvironmentInherits(t *testing.T) {
	got, err := loadLaunch(spec(t, `{"executable":"x","argv":["y"]}`))
	if err != nil {
		t.Fatal(err)
	}
	if got.environ() != nil {
		t.Fatal("an absent env replaced the environment instead of inheriting it")
	}
}
