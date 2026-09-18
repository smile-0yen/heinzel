// SPDX-License-Identifier: Apache-2.0
//
// hzl-exec — the part of Heinzel that starts processes and reads what they
// wrote.
//
// It exists because two jobs in this program are the ones shell is worst at,
// and they are the two the whole unattended lane rests on:
//
//   - starting a process, holding it to a wall clock, and making sure that
//     when the clock runs out the engine's own children go with it. In shell
//     that is a background job, a `set -m` for job control, a watchdog
//     subshell, a marker file to carry the verdict back across the subshell
//     boundary, and four comments explaining which of those may not be
//     rearranged. Here it is a process group, a context and a Wait.
//
//   - reading what an agent CLI streamed. In shell that is jq run twice over
//     the same file because the first reading rejects a file cut off at the
//     deadline, and the second one cannot be expressed without re-parsing
//     every line. Here it is a decoder that keeps what it got.
//
// What it deliberately does NOT know: which engine takes which flags, what a
// role is, what a security profile means. Building a launch spec is policy and
// stays in lib/engines.sh. This binary is handed a spec and gives back what it
// observed (docs/RUNTIME-BACKENDS.md §7, §8.4).
//
// Every subcommand takes and returns the same JSON files the shell did, so the
// boundary is unchanged and either side can be replaced again.
package main

import (
	"fmt"
	"os"
)

// Set by the linker from HEINZEL_VERSION at build time. `hzl doctor` compares
// it with the version of the shell it was built beside: a binary left over
// from an older checkout is the one failure this split introduces that the
// shell alone never had, so it is the one the tooling has to be able to see.
var heinzelVersion = "unknown"

const usage = `hzl-exec — process control and agent output parsing for Heinzel

  hzl-exec run <launch.json> <run.json> <collected.json>
        Start what the launch spec names, hold it to the run spec's wall
        clock, and write down what was observed. Exits with the process's own
        status, or 124 (timed out), 137 (ignored TERM), 125 (spec refused).

  hzl-exec timeout <kill_after_sec> <timeout_sec> <command> [args...]
        The same wall clock around an ordinary command, with no spec files.

  hzl-exec render <launch.json>
        The launch as a shell would have to be handed it: the executable, then
        each argument, each one NUL-terminated.

  hzl-exec normalize <launch.json> <collected.json> <result.json> [backend]
        Turn what was collected into the engine-independent result.

  hzl-exec parse <engine> <raw-file>
        The figures read out of one engine's own output, and nothing else.

  hzl-exec verdict <engine> <rc> <stderr-file> <raw-file>
  hzl-exec authcheck <engine> <rc> <stderr-file>
  hzl-exec outcome <verdict>
        The three judgements, separately, for callers that want one.

  hzl-exec version
  hzl-exec schema
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "run":
		os.Exit(cmdRun(args))
	case "timeout":
		os.Exit(cmdTimeout(args))
	case "render":
		os.Exit(cmdRender(args))
	case "normalize":
		os.Exit(cmdNormalize(args))
	case "parse":
		os.Exit(cmdParse(args))
	case "verdict":
		os.Exit(cmdVerdict(args))
	case "authcheck":
		os.Exit(cmdAuthcheck(args))
	case "outcome":
		os.Exit(cmdOutcome(args))
	case "schema":
		// The result schema this binary would write when the shell does not
		// say. It is printed so that the test suite can assert it against
		// HEINZEL_RESULT_SCHEMA, which is the only way a constant that lives
		// in two languages stays one constant.
		fmt.Println(defaultResultSchema)
		return
	case "version", "--version", "-v":
		fmt.Println(heinzelVersion)
		return
	case "help", "--help", "-h":
		fmt.Print(usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "hzl-exec: unknown subcommand: %s\n", os.Args[1])
		os.Exit(2)
	}
}

// Every refusal goes to stderr with the same prefix the shell used, so a log
// from before this binary existed and one from after read the same way.
func errf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", a...)
}
