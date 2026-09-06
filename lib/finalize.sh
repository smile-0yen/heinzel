#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/finalize.sh — the crash boundary between doing the work and recording it.
#
# The ledger is where a run's work becomes true. Until now the runner has read
# the worksheet and written the ledger in one motion: `worksheet_merge` parses a
# line and applies it, parses the next and applies it. If the process dies in the
# middle of that, what is left behind is half a merge and nothing that says so —
# no record of what was about to be applied, and no way for the next run to tell
# "this task was closed" from "this task was about to be closed".
#
# So the motion comes apart into the four steps of §13.4 and the `FINALIZING`
# state of §9.2 (docs/RUNTIME-BACKENDS.md):
#
#   1. parse       the worksheet becomes a list of candidates. Read only.
#   2. check       scope and workspace identity, deterministically, before
#                  anything is written.
#   3. intent      what is about to be applied, the digest of the ledger it is
#                  about to be applied to, and the digest of the evidence —
#                  saved atomically, *before* the ledger is touched.
#   4. commit      one transition, under the backlog lock, followed by a receipt
#                  carrying the digest of the ledger it produced.
#
#   finalize_candidates <worksheet> <allowed-ids>   -> the parse, as TSV
#   finalize_intent  <run-id> <ws> <backlog> <legacy-run-id> <allowed> [identity]
#   finalize_apply   <run-id> <ws> <backlog> <legacy-run-id> <allowed>
#   finalize_receipt <run-id> <backlog> <done> <blocked> <new> <ignored>
#   finalize_commit  <run-id> <ws> <backlog> <legacy-run-id> <allowed> [identity]
#   finalize_state   <run-id>                      -> none|intent|receipt
#   finalize_pending [backlog]                     -> runs that stopped mid-commit
#   finalize_recover <run-id> <backlog>            -> finishes one, exactly once
#
# The intent and the receipt are the whole argument. An intent with no receipt
# is a run that stopped somewhere inside step 4, and there are only two places it
# can have stopped: before the ledger changed, or after. The intent's
# `ledger_digest_before` tells recovery which, and the receipt is what stops a
# second recovery from doing it again. `tasks_done_total` moves with the receipt
# and not before it (§14.1), which is also the answer to the older question of
# what happens to a completion that landed in the ledger a moment before the
# process was killed: today it is in the ledger and missing from the total.
#
# Requires lib/common.sh, lib/runstore.sh and lib/locks.sh.

FINALIZE_SCHEMA=1

# How long the commit waits for the backlog lock. A ledger mutation is
# milliseconds; a caller waiting longer than this is waiting for something else.
FINALIZE_LOCK_WAIT=10

# The digest of a file, or the empty string when there is no file to digest. The
# fallback is the one claims_workspace_hash uses, for the same reason: this has
# to produce an answer on a machine without shasum, and the answer only has to
# be stable and hard to collide with by accident.
finalize_digest() { # file
  local f=$1 v=""
  [ -r "${f}" ] || return 1
  if have shasum; then
    v=$(shasum -a 256 "${f}" 2>/dev/null | cut -d' ' -f1)
  fi
  case ${v} in
    [0-9a-f][0-9a-f]*) printf 'sha256:%s' "${v}" ;;
    *) printf 'cksum:%s' "$(cksum <"${f}" | tr -d ' \n')" ;;
  esac
}

_finalize_intent_file()  { local d; d=$(runstore_dir "$1") || return 1; printf '%s/finalize.intent.json' "${d}"; }
_finalize_receipt_file() { local d; d=$(runstore_dir "$1") || return 1; printf '%s/finalize.receipt.json' "${d}"; }

# Where a run got to. `receipt` means the ledger transition is committed and
# recorded; `intent` means it was about to happen and nothing says it did.
finalize_state() { # run-id
  local i r
  i=$(_finalize_intent_file "$1") || return 1
  r=$(_finalize_receipt_file "$1") || return 1
  if [ -r "${r}" ]; then printf receipt
  elif [ -r "${i}" ]; then printf intent
  else printf none
  fi
}

# --- 1. the parse -----------------------------------------------------------

# The worksheet, read as candidates and nothing else. One row per line the merge
# would act on:
#
#   done<TAB><id><TAB><TAB>
#   blocked<TAB><id><TAB><steps><TAB><reason>
#   reopen<TAB><id><TAB><TAB>
#   new<TAB><TAB><prio><TAB><text>
#   ignored<TAB><id><TAB><TAB>
#
# `steps` is the file in the working directory the agent wrote its instructions
# for a person in, when it wrote one. It is carried through the intent so that a
# recovery has it too: the instructions are the useful half of a block, and a
# commit finished by a later run must not finish it without them.
#
# Nothing here writes. That is the point of separating it: the list of what is
# about to happen has to exist before any of it happens, or there is nothing to
# put in the intent. The scope check — an id the run was not given is `ignored`,
# never applied — is the same one `worksheet_merge` makes, made earlier.
finalize_candidates() { # worksheet allowed-ids
  local ws=$1 allowed=$2 rows row allow_list lineno prio marker id text reason steps
  [ -r "${ws}" ] && [ -r "${allowed}" ] || return 1
  allow_list=" $(tr '\n' ' ' <"${allowed}") "
  rows=$(backlog_scan "${ws}" 2>/dev/null)
  while IFS= read -r row; do
    [ -n "${row}" ] || continue
    lineno=$(printf '%s' "${row}" | cut -f1)
    prio=$(printf '%s' "${row}" | cut -f2)
    marker=$(printf '%s' "${row}" | cut -f3)
    id=$(printf '%s' "${row}" | cut -f4)
    text=$(printf '%s' "${row}" | cut -f5-)
    if [ -z "${id}" ]; then
      # Only a todo may arrive without an id: a line marked done that nobody
      # ever queued is not a completion, and there is nothing to check it
      # against.
      if [ "${marker}" = " " ]; then
        printf 'new\t\t%s\t%s\n' "${prio}" "${text}"
      else
        printf 'ignored\t\t\t\n'
      fi
      continue
    fi
    case ${allow_list} in
      *" ${id} "*) ;;
      *) printf 'ignored\t%s\t\t\n' "${id}"; continue ;;
    esac
    case ${marker} in
      x|X) printf 'done\t%s\t\t\n' "${id}" ;;
      "!")
        reason=$(line_meta "${ws}" "${lineno}" | sed -n 's/.*reason:[ 	]*//p')
        [ -n "${reason}" ] || reason="not stated"
        steps=$(worksheet_steps_file "${ws}" "${id}" 2>/dev/null)
        [ -n "${steps}" ] && [ -r "${steps}" ] || steps=""
        printf 'blocked\t%s\t%s\t%s\n' "${id}" "${steps}" "$(oneline "${reason}")"
        ;;
      *) printf 'reopen\t%s\t\t\n' "${id}" ;;
    esac
  done <<EOF
${rows}
EOF
}

_finalize_ids_json() { # candidates kind
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k && $2 != "" {print $2}' |
    jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# --- 3. the intent ----------------------------------------------------------

# What is about to be applied, to which ledger, on the strength of which
# evidence. Written whole and renamed into place, before the ledger is touched,
# because a record of an intention that is written afterwards is not one.
finalize_intent() { # run-id worksheet backlog legacy-run-id allowed [identity]
  local run=$1 ws=$2 backlog=$3 legacy=$4 allowed=$5 identity=${6:-}
  local cands dir tmp f json blocked_json new_json
  f=$(_finalize_intent_file "${run}") || return 1
  dir=$(dirname "${f}")
  [ -d "${dir}" ] || return 1
  cands=$(finalize_candidates "${ws}" "${allowed}") || return 1
  blocked_json=$(printf '%s\n' "${cands}" |
    awk -F'\t' '$1 == "blocked" && $2 != "" {printf "%s\t%s\t%s\n", $2, $4, $3}' |
    jq -R -s -c 'split("\n") | map(select(length > 0)) |
                 map(split("\t")) |
                 map({id: .[0], reason: (.[1] // ""), steps: (.[2] // "")})')
  new_json=$(printf '%s\n' "${cands}" |
    awk -F'\t' '$1 == "new" {printf "%s\t%s\n", $3, $4}' |
    jq -R -s -c 'split("\n") | map(select(length > 0)) |
                 map(split("\t")) | map({priority: .[0], text: (.[1] // "")})')
  json=$(jq -n \
    --argjson schema_version "${FINALIZE_SCHEMA}" \
    --arg run_id "${run}" \
    --arg legacy_run_id "${legacy}" \
    --arg backlog "${backlog}" \
    --arg workspace_identity "${identity}" \
    --arg worksheet_digest "$(finalize_digest "${ws}")" \
    --arg ledger_digest_before "$(finalize_digest "${backlog}")" \
    --argjson done "$(_finalize_ids_json "${cands}" done)" \
    --argjson blocked "${blocked_json}" \
    --argjson reopen "$(_finalize_ids_json "${cands}" reopen)" \
    --argjson new "${new_json}" \
    --arg created_at "$(iso_at)" \
    '{schema_version: $schema_version, run_id: $run_id,
      legacy_run_id: $legacy_run_id, backlog: $backlog,
      workspace_identity: $workspace_identity,
      worksheet_digest: $worksheet_digest,
      ledger_digest_before: $ledger_digest_before,
      done: $done, blocked: $blocked, reopen: $reopen, new: $new,
      created_at: $created_at}') || return 1
  tmp=$(mktemp "${dir}/.intent.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
     chmod 600 "${tmp}" && mv -f "${tmp}" "${f}"; then
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# --- 4. the commit ----------------------------------------------------------

# The single transition. Under the backlog lock, so that the ledger has one
# writer for the length of it, and the expected digest is checked again inside
# the lock: an evidence digest that was true before the lock and false inside it
# was never evidence about this ledger (§13.2).
#
# A ledger that moved is recorded and applied anyway. The check that protects
# the ledger is scope — only ids this run was given, which `worksheet_merge`
# enforces line by line — and refusing to record a finished run's work because
# somebody closed an unrelated task by hand would lose the work to protect the
# record of it. When there is a `NEEDS_REVIEW` outcome to put it in, that is
# where a moved ledger goes.
_finalize_moved_file() { local d; d=$(runstore_dir "$1") || return 1; printf '%s/finalize.moved' "${d}"; }

# Where a run's trap put the steps when it stopped: `stash_steps` in the runner
# copies `<workdir>/.heinzel/blocked/*.md` into the run's exec directory before
# it takes them out of the working directory, and the run's snapshot says where
# that directory is. Recovery reads the intent's source first and this second,
# so that a run stopped by SIGTERM - the deadline, `hzl off`, a closed lid - is
# finished with its instructions just as a run stopped by SIGKILL is.
_finalize_kept_steps() { # run-id id
  local exec_dir ref
  exec_dir=$(runstore_read "$1" 2>/dev/null | jq -r '.exec_dir // ""' 2>/dev/null)
  [ -n "${exec_dir}" ] || return 1
  ref=$(ledger_steps_ref "$2") || return 1
  printf '%s/%s' "${exec_dir}" "${ref}"
}

finalize_apply() { # run-id worksheet backlog legacy-run-id allowed
  lock_with "${LOCK_BACKLOG}" "${FINALIZE_LOCK_WAIT}" \
    _finalize_apply_locked "$1" "$2" "$3" "$4" "$5"
}

_finalize_apply_locked() { # run-id worksheet backlog legacy-run-id allowed
  local run=$1 ws=$2 backlog=$3 legacy=$4 allowed=$5 f expected now
  # The flag is a file and not a variable because the commit is read through a
  # command substitution, and a variable set inside one of those is set in a
  # shell that is about to end.
  f=$(_finalize_intent_file "${run}" 2>/dev/null)
  if [ -n "${f}" ] && [ -r "${f}" ]; then
    expected=$(jq -r '.ledger_digest_before // ""' "${f}" 2>/dev/null)
    now=$(finalize_digest "${backlog}")
    [ "${expected}" = "${now}" ] ||
      printf '%s\n' "${now}" >"$(_finalize_moved_file "${run}")"
  fi
  # The mechanical application is the one that was always here. Separating the
  # parse from the commit does not mean writing a second thing that moves
  # markers: there is one of those, and this is the moment it runs.
  worksheet_merge "${ws}" "${backlog}" "${legacy}" "${allowed}"
}

# The receipt: this ledger, after this commit. Written immediately after the
# transition, and the only thing that says the transition happened.
finalize_receipt() { # run-id backlog done blocked new ignored [recovered] [counted]
  local run=$1 backlog=$2 done=$3 blocked=$4 new=$5 ignored=$6
  local recovered=${7:-false} counted=${8:-0} f dir tmp json moved=false
  f=$(_finalize_receipt_file "${run}") || return 1
  dir=$(dirname "${f}")
  [ -d "${dir}" ] || return 1
  [ -e "$(_finalize_moved_file "${run}")" ] && moved=true
  json=$(jq -n \
    --argjson schema_version "${FINALIZE_SCHEMA}" \
    --arg run_id "${run}" \
    --arg ledger_digest_after "$(finalize_digest "${backlog}")" \
    --argjson done "${done:-0}" --argjson blocked "${blocked:-0}" \
    --argjson new "${new:-0}" --argjson ignored "${ignored:-0}" \
    --argjson ledger_moved "${moved}" \
    --argjson recovered "${recovered}" \
    --argjson counted "${counted}" \
    --arg committed_at "$(iso_at)" \
    '{schema_version: $schema_version, run_id: $run_id,
      ledger_digest_after: $ledger_digest_after,
      done: $done, blocked: $blocked, new: $new, ignored: $ignored,
      ledger_moved: $ledger_moved, recovered: $recovered,
      counted: $counted, committed_at: $committed_at}') || return 1
  tmp=$(mktemp "${dir}/.receipt.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
     chmod 600 "${tmp}" && mv -f "${tmp}" "${f}"; then
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# The four steps in order, printing what the merge printed, so that a caller
# that only wants `done blocked new ignored` sees no difference.
finalize_commit() { # run-id worksheet backlog legacy-run-id allowed [identity]
  local run=$1 ws=$2 backlog=$3 legacy=$4 allowed=$5 identity=${6:-}
  local counts rc d b n i
  finalize_intent "${run}" "${ws}" "${backlog}" "${legacy}" "${allowed}" "${identity}" ||
    { printf '0 0 0 0\n'; return 1; }
  counts=$(finalize_apply "${run}" "${ws}" "${backlog}" "${legacy}" "${allowed}")
  rc=$?
  d=$(printf '%s' "${counts}" | cut -d' ' -f1)
  b=$(printf '%s' "${counts}" | cut -d' ' -f2)
  n=$(printf '%s' "${counts}" | cut -d' ' -f3)
  i=$(printf '%s' "${counts}" | cut -d' ' -f4)
  finalize_receipt "${run}" "${backlog}" "${d:-0}" "${b:-0}" "${n:-0}" "${i:-0}"
  printf '%s %s %s %s\n' "${d:-0}" "${b:-0}" "${n:-0}" "${i:-0}"
  return ${rc}
}

# --- recovery ---------------------------------------------------------------

# The runs that stopped inside step 4: an intent, and nothing saying it was
# applied. Optionally narrowed to one ledger, because a run that was finalizing
# somebody else's backlog is not this run's to finish.
finalize_pending() { # [backlog]
  local backlog=${1:-} run f
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "$(finalize_state "${run}")" = intent ] || continue
    if [ -n "${backlog}" ]; then
      f=$(_finalize_intent_file "${run}") || continue
      [ "$(jq -r '.backlog // ""' "${f}" 2>/dev/null)" = "${backlog}" ] || continue
    fi
    printf '%s\n' "${run}"
  done <<EOF
$(runstore_runs)
EOF
}

# Finish one interrupted commit, exactly once, and print
# `done blocked new ignored` for what the recovery itself applied.
#
# There were two places to stop, and the intent's digest of the ledger it was
# about to change says which:
#
#   the ledger is byte for byte what the intent expected  -> nothing was applied
#   the ledger has moved                                  -> some or all of it was
#
# In the first case the whole intent is applied. In the second every id is
# checked and only the ones that did not land are applied — a marker is a
# setting and not an increment, so re-applying one that landed would be
# harmless, but counting it twice would not be. New tasks are the exception:
# inserting a line is not idempotent, so on the moved-ledger path one is
# inserted only if no line with exactly that text is in the ledger already.
#
# `tasks_done_total` moves here, once, for every completion this run made:
# a run that stopped between the intent and the receipt stopped long before it
# reached its own counter, so nothing it did has been counted (§14.1).
finalize_recover() { # run-id backlog
  local run=$1 backlog=$2 f state expected now legacy applied_done=0
  local n_done=0 n_blocked=0 n_new=0 n_total i id reason steps kept prio text marker
  state=$(finalize_state "${run}")
  [ "${state}" = intent ] || { printf '0 0 0 0\n'; return 1; }
  f=$(_finalize_intent_file "${run}") || { printf '0 0 0 0\n'; return 1; }
  [ -r "${backlog}" ] && [ -w "${backlog}" ] || { printf '0 0 0 0\n'; return 1; }
  legacy=$(jq -r '.legacy_run_id // ""' "${f}" 2>/dev/null)
  expected=$(jq -r '.ledger_digest_before // ""' "${f}" 2>/dev/null)
  now=$(finalize_digest "${backlog}")

  lock_acquire "${LOCK_BACKLOG}" "${FINALIZE_LOCK_WAIT}" || { printf '0 0 0 0\n'; return 1; }

  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    # Across the ledger, not just the backlog: a completion that landed and was
    # then swept into the archive is still a completion, and re-applying it
    # would put the task back into the backlog as a fresh `[x]`.
    marker=$(ledger_marker_of_id "${backlog}" "${id}")
    if [ "${marker}" = x ]; then
      applied_done=$((applied_done + 1))
    # Across the ledger to write, as well as to read. `backlog_set_state` writes
    # to the backlog whatever file the id is actually in, so a completion for a
    # task sitting in the blocked file failed here — and the counter and the
    # receipt moved on regardless, recording a completion the ledger does not
    # have. A write that did not happen is not counted.
    elif ledger_set_state "${backlog}" "${id}" x \
           "done:$(iso_at) run:${legacy} recovered:${run}"; then
      n_done=$((n_done + 1))
      applied_done=$((applied_done + 1))
    fi
  done <<EOF
$(jq -r '.done[]? // empty' "${f}" 2>/dev/null)
EOF

  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    reason=$(jq -r --arg i "${id}" '.blocked[]? | select(.id == $i) | .reason' "${f}" 2>/dev/null | head -1)
    [ -n "${reason}" ] || reason="not stated"
    # Independently of the marker: the interrupted run may have moved the marker
    # and died before the steps landed, and a `[!]` whose instructions are
    # missing is the state this file exists to prevent. The source the intent
    # recorded is in the working directory, and it is there only if the run was
    # killed outright: a run that got to run its trap has already moved it to
    # the exec directory, which is read second. When neither is there, the
    # reason stands alone.
    steps=$(jq -r --arg i "${id}" '.blocked[]? | select(.id == $i) | .steps // ""' "${f}" 2>/dev/null | head -1)
    if [ -n "${steps}" ] && ! [ -r "${steps}" ]; then
      kept=$(_finalize_kept_steps "${run}" "${id}" 2>/dev/null)
      [ -n "${kept}" ] && [ -r "${kept}" ] && steps=${kept}
    fi
    [ -n "${steps}" ] && ledger_steps_install "${backlog}" "${id}" "${steps}" >/dev/null 2>&1
    marker=$(ledger_marker_of_id "${backlog}" "${id}")
    if [ "${marker}" != "!" ]; then
      ledger_set_state "${backlog}" "${id}" "!" \
        "blocked:$(iso_at) reason:${reason} run:${legacy} recovered:${run}" &&
        n_blocked=$((n_blocked + 1))
    fi
  done <<EOF
$(jq -r '.blocked[]?.id // empty' "${f}" 2>/dev/null)
EOF

  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    marker=$(ledger_marker_of_id "${backlog}" "${id}")
    [ "${marker}" = "~" ] && ledger_set_state "${backlog}" "${id}" " " ""
  done <<EOF
$(jq -r '.reopen[]? // empty' "${f}" 2>/dev/null)
EOF

  # By index, not by priority: two new tasks under one heading are two tasks,
  # and grouping them would insert the first of them twice.
  n_total=$(jq -r '(.new // []) | length' "${f}" 2>/dev/null)
  case ${n_total} in ""|*[!0-9]*) n_total=0 ;; esac
  i=0
  while [ "${i}" -lt "${n_total}" ]; do
    prio=$(jq -r --argjson i "${i}" '.new[$i].priority // ""' "${f}" 2>/dev/null)
    text=$(jq -r --argjson i "${i}" '.new[$i].text // ""' "${f}" 2>/dev/null)
    i=$((i + 1))
    [ -n "${text}" ] || continue
    if [ "${expected}" != "${now}" ] && ledger_has_text "${backlog}" "${text}"; then
      continue
    fi
    backlog_insert_at_priority "${backlog}" "${prio}" "${text}" && n_new=$((n_new + 1))
  done

  # The counter moves with the receipt and never without it. Every completion in
  # the intent is counted, whether this recovery applied it or found it already
  # applied: the run that wrote the intent never reached its own counter.
  if [ "${applied_done}" -gt 0 ]; then
    state_update ".tasks_done_total = (.tasks_done_total + ${applied_done})" >/dev/null 2>&1
  fi
  finalize_receipt "${run}" "${backlog}" "${n_done}" "${n_blocked}" "${n_new}" 0 \
    true "${applied_done}"
  lock_release "${LOCK_BACKLOG}"
  printf '%s %s %s %s\n' "${n_done}" "${n_blocked}" "${n_new}" 0
}

# The "already in the ledger" question this used to answer itself now lives in
# lib/common.sh as `ledger_has_text`, because after the completed archive was
# split out it is a question about two files rather than one.
