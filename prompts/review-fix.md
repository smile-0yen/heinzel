A review of your previous run raised the findings below. Fix them, in this
working directory, in one pass.

Working directory: {{WORKDIR}}
Run id:            {{RUN_ID}}
Wall clock:        {{RUN_TIMEOUT_MIN}} minutes

Findings:
{{FINDINGS}}

Rules:

- Fix only what is listed. This is not an invitation to refactor.
- Do not change any backlog marker. The ledger is not yours to edit in this
  pass; whoever called you will update it based on the re-review.
- Verify your fixes the same way you were meant to verify the original work.
- The same hard limits apply: no `sudo`, nothing outside {{WORKDIR}}, no
  pushing, no secrets, no new background processes.
- If a finding cannot be fixed without a human decision, leave it and say so.

Finish with a short list of what you changed, one line per finding.
