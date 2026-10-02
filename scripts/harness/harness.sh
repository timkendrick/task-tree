#!/usr/bin/env bash
# Test harness for tt bootstrap CLI
# Source this file from test scripts; do not execute directly.

# Guard against direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Error: harness.sh must be sourced, not executed directly." >&2
  exit 1
fi

# VCS tracing must never leak in from the ambient environment: TT_LOG=info or
# TT_LOG=verbose echoes backend command lines to stderr and forwards output the
# backend would otherwise discard, and suites that fold stderr into captured
# output would then assert against trace lines. Suites that exercise tracing set
# TT_LOG explicitly per invocation.
unset TT_LOG

# Resolve paths
HARNESS_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
TT="$REPO_ROOT/scripts/cli/tt"

# Global counters (written to temp files so subshells can contribute)
_PASS_COUNT=0
_FAIL_COUNT=0
_SKIP_COUNT=0
declare -a _FAILURES=()



# Temp dir for accumulating results across subshells. The runner supplies a
# shared one as _TT_TEST_RESULTS_DIR; a suite run on its own creates its own.
if [[ -n "${_TT_TEST_RESULTS_DIR:-}" ]]; then
  _RESULTS_DIR="$_TT_TEST_RESULTS_DIR"
  _OWN_RESULTS_DIR=''
else
  _RESULTS_DIR="$(mktemp -d)"
  _OWN_RESULTS_DIR="$_RESULTS_DIR"
fi

# Suite start time in milliseconds. Uses perl for sub-second precision (it
# starts in a few milliseconds, where python3 takes tens); falls back to
# python3, then to whole seconds via date.
_ms_now() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    printf '%d000' "$(date +%s)"
  fi
}
_SUITE_START="$(_ms_now)"
_SECTION_START="$_SUITE_START"

# Colors (respect NO_COLOR; _TT_TEST_FORCE_COLOR bypasses the TTY check for
# buffered subprocess output that will be replayed on a real TTY by the runner)
if [[ -z "${NO_COLOR:-}" && ( -t 2 || -n "${_TT_TEST_FORCE_COLOR:-}" ) ]]; then
  _RED='\033[0;31m'
  _GREEN='\033[0;32m'
  _YELLOW='\033[0;33m'
  _CYAN='\033[0;36m'
  _BOLD='\033[1m'
  _RESET='\033[0m'
else
  _RED='' _GREEN='' _YELLOW='' _CYAN='' _BOLD='' _RESET=''
fi

# Escape a string for use in a grep -E (extended regex) pattern.
_escape_ere() {
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

# ---------------------------------------------------------------------------
# Test Lifecycle
# ---------------------------------------------------------------------------

# Per-test temp directory; cleaned up after each test.
# A new directory is created within the provided TT_TEST_ROOT
# if specified otherwise a fresh temp dir is created.
if [[ -n "${TT_TEST_ROOT:-}" ]]; then
  _TEST_ROOT="$(mktemp -d "$TT_TEST_ROOT/tt-test-XXXXXX")"
else
  _TEST_ROOT="$(mktemp -d)"
fi
trap 'rm -rf "$_TEST_ROOT" ${_OWN_RESULTS_DIR:+"$_OWN_RESULTS_DIR"}' EXIT

# Per-test workspace vars (set by setup_workspace)
REPO=""
VIRTUAL=""

# Build a fresh jj repo + tt workspace: an initial commit on `main`, then
# `tt workspace init` against a sibling virtual folder. REPO must not yet
# exist; VIRTUAL is created by workspace init.
# Usage: build_workspace REPO VIRTUAL
build_workspace() {
  local repo="$1" virtual="$2"
  mkdir -p "$repo"
  # Resolve any symlinks in the path (e.g. /var -> /private/var on macOS)
  repo="$(cd "$repo" && pwd -P)"

  jj git init "$repo" >/dev/null 2>&1

  echo "initial" > "$repo/README.md"
  jj -R "$repo" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$repo" bookmark set main >/dev/null 2>&1

  "$TT" workspace init "$repo" "$virtual" >/dev/null 2>&1
  # workspace init creates .tt/workspace symlink automatically; no further setup needed.
}

# Create a fresh jj repo + tt workspace for a test.
# Sets REPO, VIRTUAL, and exports TT_REPO, changes CWD to REPO.
#
# When the runner has built a template workspace (_TT_TEST_TEMPLATE names a
# directory holding `repo` and `virtual` as build_workspace leaves them), the
# workspace is a copy of that template rather than a fresh build: every test
# starts from the identical state, and a copy is a single process where a
# build is a dozen. Only the two absolute symlinks — `.tt/workspace` in the
# repo and `HEAD` in the virtual folder — are re-pointed at the copy; nothing
# else in a workspace records where it lives.
# Usage: setup_workspace [name]
setup_workspace() {
  local name="${1:-test-$$-$RANDOM}"
  local root="$_TEST_ROOT/$name"
  REPO="$root/repo"
  VIRTUAL="$root/virtual"
  if [[ -n "${_TT_TEST_TEMPLATE:-}" && -d "$_TT_TEST_TEMPLATE/repo" ]]; then
    mkdir -p "$root"
    cp -R "$_TT_TEST_TEMPLATE/repo" "$_TT_TEST_TEMPLATE/virtual" "$root/"
    # Resolve any symlinks in the path (e.g. /var -> /private/var on macOS)
    REPO="$(cd "$REPO" && pwd -P)"
    ln -sfn "$VIRTUAL" "$REPO/.tt/workspace"
    ln -sfn "$REPO" "$VIRTUAL/HEAD"
  else
    build_workspace "$REPO" "$VIRTUAL"
    REPO="$(cd "$REPO" && pwd -P)"
  fi
  cd "$REPO"

  # Export so run_tt forwards it as --repo to all tt commands
  export TT_REPO="$REPO"
}

# ---------------------------------------------------------------------------
# tt Command Helper
# ---------------------------------------------------------------------------

# Run a tt command, with stdout and stderr captured separately.
# Usage: run_tt [args...]
run_tt() {
  if _harness_cache_ready && _harness_read_stdin; then
    _harness_run_cached "$_HARNESS_STDIN" "$@"
  else
    TT_REPO="${TT_REPO:-${REPO:-}}" "$TT" "$@"
  fi
}

# Run a tt command from within a worktree, simulating a user who has cd'd into
# the worktree without TT_REPO set. This exercises the find_repo_root code path
# (resolving $repo from CWD) rather than the TT_REPO shortcut.
# Usage: run_tt_in_worktree WORKTREE_PATH [args...]
run_tt_in_worktree() {
  local worktree_path="$1"; shift
  (cd "$worktree_path" && unset TT_REPO && "$TT" "$@")
}

# Edit a working copy file (creates or overwrites).
# Usage: edit_file PATH CONTENT
edit_file() {
  local path="$1" content="$2"
  [[ "$path" == */* ]] && mkdir -p "${path%/*}"
  printf '%s\n' "$content" > "$path"
}

# Append to a working copy file.
# Usage: append_file PATH CONTENT
append_file() {
  local path="$1" content="$2"
  [[ "$path" == */* ]] && mkdir -p "${path%/*}"
  printf '%s\n' "$content" >> "$path"
}

# ---------------------------------------------------------------------------
# Workflow Convenience Helpers
# ---------------------------------------------------------------------------

# Create a project and return its ID on stdout.
# Usage: id=$(create_project SLUG TITLE [BODY])
create_project() {
  local slug="$1" title="$2" body="${3:-}"
  local out
  out="$(run_tt task create --project --slug "$slug" --title "$title" <<< "$body" 2>/dev/null)" || return $?
  printf '%s\n' "${out##*$'\n'}"
}

# Create a child task under the current branch and return its ID on stdout.
# Usage: id=$(create_task SLUG TITLE [BODY])
create_task() {
  local slug="$1" title="$2" body="${3:-}"
  local out
  out="$(run_tt task create --slug "$slug" --title "$title" <<< "$body" 2>/dev/null)" || return $?
  printf '%s\n' "${out##*$'\n'}"
}

# Create a child task under a specific parent and return its ID on stdout.
# Usage: id=$(create_task_under PARENT_ID SLUG TITLE [BODY])
create_task_under() {
  local parent="$1" slug="$2" title="$3" body="${4:-}"
  local out
  out="$(run_tt task create --parent "$parent" --slug "$slug" --title "$title" <<< "$body" 2>/dev/null)" || return $?
  printf '%s\n' "${out##*$'\n'}"
}

# Checkout a task (switches WC to it).
# Usage: checkout_task TASK_ID
checkout_task() {
  run_tt task checkout "$1" >/dev/null 2>&1
}

# Check out a task with a dedicated worktree and return the worktree path on stdout.
# Asserts the worktree was genuinely created, so a regression in worktree creation
# fails loudly at setup rather than silently corrupting the rest of the test.
# Extra arguments are passed through to `tt task checkout` (e.g. --switch).
# Usage: path=$(create_task_worktree TASK_ID [CHECKOUT_ARGS...])
create_task_worktree() {
  local task_id="$1"; shift
  local path
  path=$(run_tt task checkout "$task_id" --worktree "$@" 2>/dev/null) || path=""
  assert_neq "worktree created for $task_id" "$path" "$REPO"
  assert_output_not_empty "worktree path for $task_id" "$path"
  printf '%s\n' "$path"
}

# Checkpoint the current task with a message.
# Usage: checkpoint_task MESSAGE
checkpoint_task() {
  run_tt task checkpoint -m "$1" 2>&1
}

# Complete the current task (or a specific task).
# Usage: complete_task [TASK_ID]
complete_task() {
  if [[ $# -gt 0 ]]; then
    run_tt task complete "$1" 2>&1
  else
    run_tt task complete 2>&1
  fi
}

# Checkin the current task (or a specific task) to its parent.
# Usage: checkin_task [TASK_ID] [EXTRA_ARGS...]
checkin_task() {
  run_tt task checkin "$@" 2>&1
}

# Capture the task ID from the last line of stdout.
# Usage: TASK_ID=$(last_line "$output")
last_line() {
  local text="${1%$'\n'}"
  printf '%s' "${text##*$'\n'}"
}

# ---------------------------------------------------------------------------
# Process Helpers
#
# Dummy processes stand in for a long-running process (e.g. a web server)
# that uses a worktree's files. Each runs `tail -f /dev/null`, which does
# nothing until killed, so it holds the path until the test releases it with
# abort_dummy_process. It is not a child of the tt commands the test runs, nor
# an ancestor of them, so tt does not mistake it for part of its own process
# lineage.
#
# A dummy process has no timeout, so a test that spawns one also registers an
# EXIT trap that aborts it, in case the test stops before its explicit abort:
#
#   pid=$(spawn_dummy_process_in_dir "$dir")
#   trap "abort_dummy_process $pid" EXIT
#   ...assertions...
#   abort_dummy_process "$pid"
# ---------------------------------------------------------------------------

# Start a dummy process whose current directory is DIR. Prints its PID once
# lsof reports it in DIR.
# Usage: pid=$(spawn_dummy_process_in_dir DIR)
spawn_dummy_process_in_dir() {
  local dir="$1"
  (cd "$dir" && exec tail -f /dev/null) </dev/null >/dev/null 2>&1 &
  __harness_await_dummy_process "$!" "$(cd "$dir" && pwd -P)"
}

# Start a dummy process that holds FILE open, with its current directory
# elsewhere. Prints its PID once lsof reports it holding FILE.
# Usage: pid=$(spawn_dummy_process_holding_file FILE)
spawn_dummy_process_holding_file() {
  local file="$1"
  (cd / && exec tail -f /dev/null 3<"$file") </dev/null >/dev/null 2>&1 &
  __harness_await_dummy_process "$!" "$(cd "${file%/*}" && pwd -P)/${file##*/}"
}

# Stop a dummy process and wait until it has exited. Does nothing if it has
# already exited, so the EXIT trap backstop can call it after the test has.
# Usage: abort_dummy_process PID
abort_dummy_process() {
  local pid="$1" waited=0
  kill "$pid" 2>/dev/null || return 0
  while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 50 ]]; do
    sleep 0.1
    waited=$(( waited + 1 ))
  done
}

# Waits until lsof reports PID using the canonical path CANONICAL_PATH, so the
# test never races the dummy process's startup, then prints PID. Aborts the
# process and returns 1 if that never happens.
# Usage: __harness_await_dummy_process PID CANONICAL_PATH
__harness_await_dummy_process() {
  local pid="$1" canonical_path="$2" waited=0
  while [[ $waited -lt 50 ]]; do
    if lsof -a -p "$pid" -F n 2>/dev/null | grep -qxF "n$canonical_path"; then
      printf '%s' "$pid"
      return 0
    fi
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  abort_dummy_process "$pid"
  printf 'Error: dummy process %s never started using %s\n' "$pid" "$canonical_path" >&2
  return 1
}

# Prints the current PATH with the executable NAME made unfindable: each entry
# that holds NAME is replaced by a directory of links to that entry's other
# contents.
# Usage: PATH="$(path_without_command NAME)" run_tt ...
path_without_command() {
  local name="$1"
  local -a entries=()
  IFS=':' read -ra entries <<< "$PATH"
  local result='' entry shadow target i=0
  for entry in "${entries[@]}"; do
    if [[ -x "$entry/$name" ]]; then
      shadow="$_TEST_ROOT/path-without-$name-$i"
      mkdir -p "$shadow"
      for target in "$entry"/*; do
        [[ "${target##*/}" == "$name" ]] || ln -sf "$target" "$shadow/"
      done
      entry="$shadow"
    fi
    result+="${result:+:}$entry"
    i=$(( i + 1 ))
  done
  printf '%s' "$result"
}

# ---------------------------------------------------------------------------
# Command cache
#
# Every tt command a test runs through run_tt costs dozens of processes, and
# process creation is what bounds the suite, while most tests reach their
# starting point through the same commands applied to the same state. The
# runner therefore keeps a cache (_TT_TEST_CACHE) of what each command did:
# the first time a command runs against a given workspace state it is run for
# real and its resulting repo, stdout, stderr and exit status are recorded.
# Any later run of the same command against the same state receives a
# copy of the 'memoized' recording instead.
#
# "The same state" is determined by computing a hash of the repository's
# current operation ID, a manifest of the working copy (every path outside
# the .jj and .git stores, with file content), the command line, whatever is
# on stdin, and the environment a command's behaviour can depend on.
#
# A workspace with a dedicated worktree is never cached in either direction:
# the backend records worktree paths absolutely, so such a state cannot be
# copied elsewhere. Nor is a command whose stdin is a terminal or a pipe,
# since its input cannot be read up front.
#
# TT_TEST_NO_CACHE=1 runs every command live; a suite run outside the runner
# has no cache.
# ---------------------------------------------------------------------------

# Whether the current workspace can take part in the cache: a template copy
# with no dedicated worktree, addressed by TT_REPO, from a working directory
# the restore leaves intact, and at a single operation head.
_harness_cache_ready() {
  [[ -n "${_TT_TEST_CACHE:-}" && -z "${TT_TEST_NO_CACHE:-}" && -n "${REPO:-}" ]] || return 1
  [[ "${TT_REPO:-$REPO}" == "$REPO" ]] || return 1
  [[ "$PWD" == "$REPO" || "$PWD" != "$REPO"/* ]] || return 1
  _harness_no_worktrees || return 1
  [[ -n "$(_harness_op_head)" ]]
}

# Whether the virtual folder holds nothing but a HEAD link back to the repo.
_harness_no_worktrees() {
  local entry
  for entry in "$VIRTUAL"/* "$VIRTUAL"/.[!.]* "$VIRTUAL"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "${entry##*/}" == 'HEAD' ]] || return 1
  done
  [[ "$VIRTUAL/HEAD" -ef "$REPO" ]]
}

# Reads stdin into _HARNESS_STDIN when it can be read without blocking (a
# file, a here-string, /dev/null); returns 1 for a terminal or a pipe.
_harness_read_stdin() {
  _HARNESS_STDIN=''
  [[ -t 0 ]] && return 1
  [[ -p /dev/stdin ]] && return 1
  _HARNESS_STDIN="$(</dev/stdin)" 2>/dev/null || _HARNESS_STDIN=''
  return 0
}

# The repository's current operation ID, read from the operation store's
# head directory; empty when there is not exactly one head.
_harness_op_head() {
  local entry head='' count=0
  for entry in "$REPO/.jj/repo/op_heads/heads"/*; do
    [[ -e "$entry" ]] || continue
    head="${entry##*/}"
    count=$(( count + 1 ))
  done
  [[ $count -eq 1 ]] && printf '%s' "$head"
}

# A manifest of the working copy: every entry outside the .jj and .git
# stores, with regular files' content, so two workspaces whose manifests
# agree hold the same files.
_harness_manifest() {
  __harness_manifest_dir "$REPO" ''
}
__harness_manifest_dir() {
  local dir="$1" rel="$2" entry name
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    if [[ -z "$rel" && ( "$name" == '.jj' || "$name" == '.git' ) ]]; then continue; fi
    if [[ -L "$entry" ]]; then
      printf 'L %s\n' "$rel$name"
    elif [[ -d "$entry" ]]; then
      __harness_manifest_dir "$entry" "$rel$name/"
    elif [[ -f "$entry" ]]; then
      printf 'F %s\n%s\n' "$rel$name" "$(<"$entry")"
    fi
  done
}

# _harness_restore DIR
# Replaces the workspace with the state recorded in DIR. The repo directory
# itself survives (it is the test's working directory); everything inside it
# is replaced, and the two absolute symlinks are re-pointed at this copy.
_harness_restore() {
  local dir="$1" entry
  local -a stale=()
  for entry in "$REPO"/* "$REPO"/.[!.]* "$REPO"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] && stale+=("$entry")
  done
  if [[ ${#stale[@]} -gt 0 ]]; then
    rm -rf "${stale[@]}" || return 1
  fi
  cp -R "$dir/repo/." "$REPO/" || return 1
  ln -sfn "$VIRTUAL" "$REPO/.tt/workspace" || return 1
  ln -sfn "$REPO" "$VIRTUAL/HEAD" || return 1
}

# _harness_relocate DIR TEXT
# Prints TEXT with the recording test's repo, virtual folder and test root
# (in that order, so the more specific paths win) replaced by this test's.
_harness_relocate() {
  local dir="$1" text="$2"
  local their_repo their_virtual their_root
  { read -r their_repo; read -r their_virtual; read -r their_root; } < "$dir/locations" || true
  text="${text//"$their_repo"/$REPO}"
  text="${text//"$their_virtual"/$VIRTUAL}"
  text="${text//"$their_root"/$_TEST_ROOT}"
  printf '%s' "$text"
}

# _harness_run_cached INPUT ARG...
# Runs `tt ARG...` with INPUT on stdin through the cache: replayed when the
# command has been recorded against this state, otherwise run live and
# recorded. Writes the command's stdout and stderr to this function's own
# (stderr first, then stdout: tt narrates on stderr and prints its result on
# stdout last) and returns its exit status.
_harness_run_cached() {
  local input="$1"; shift
  local material arg name
  material="$(_harness_op_head)"$'\x1f'"$(_harness_manifest)"$'\x1f'
  # Every TT_* setting except the ones naming this test's own locations, plus
  # the editor and colour settings tt honours.
  for name in $(compgen -A variable TT_) GIT_EDITOR VISUAL EDITOR NO_COLOR; do
    case "$name" in TT_REPO|TT_TEST_ROOT|TT_TEST_NO_CACHE) continue ;; esac
    material+="${name}=${!name:-}"$'\x1f'
  done
  material+="$input"
  for arg in "$@"; do material+=$'\x1e'"$arg"; done
  local key
  key="$(printf '%s' "$material" | cksum)"
  key="${key// /-}"
  local dir="$_TT_TEST_CACHE/$key"

  # Claiming the entry (an atomic mkdir) decides who runs the command: the
  # claimant records it, and a test arriving while the recording is under
  # way waits for it rather than running the same command itself, which
  # would leave it with a history of its own that nothing later could match.
  local out err rc root claimed=''
  if mkdir "$dir" 2>/dev/null; then
    claimed=1
  else
    local waited=0
    while [[ ! -f "$dir/done" && ! -f "$dir/skip" && $waited -lt 600 ]]; do
      sleep 0.1
      waited=$(( waited + 1 ))
    done
    if [[ -f "$dir/done" && "$(<"$dir/material")" == "$material" ]] && _harness_restore "$dir"; then
      out="$(<"$dir/stdout")"; out="$(_harness_relocate "$dir" "$out")"; out="${out%x}"
      err="$(<"$dir/stderr")"; err="$(_harness_relocate "$dir" "$err")"; err="${err%x}"
      rc="$(<"$dir/exit")"
      printf '%s' "$err" >&2
      printf '%s' "$out"
      return "$rc"
    fi
  fi

  # The command's exit status rides on the end of its captured stdout, so
  # that trailing newlines survive the capture as well.
  local err_file="$_TEST_ROOT/.stderr-$$"
  out="$(TT_REPO="${TT_REPO:-$REPO}" "$TT" "$@" <<< "$input" 2>"$err_file"; printf 'x%d' "$?")"
  rc="${out##*x}"
  out="${out%x*}"
  err=''
  IFS= read -r -d '' err < "$err_file" || true
  if [[ -n "$claimed" ]]; then
    if _harness_no_worktrees && cp -R "$REPO" "$dir/repo" 2>/dev/null; then
      printf '%s' "$material" > "$dir/material"
      printf '%s\n%s\n%s' "$REPO" "$VIRTUAL" "$_TEST_ROOT" > "$dir/locations"
      printf '%sx' "$out" > "$dir/stdout"
      printf '%sx' "$err" > "$dir/stderr"
      printf '%s' "$rc" > "$dir/exit"
      : > "$dir/done"
    else
      : > "$dir/skip"
    fi
  fi
  printf '%s' "$err" >&2
  printf '%s' "$out"
  return $rc
}

# ---------------------------------------------------------------------------
# VCS Introspection Helpers
# ---------------------------------------------------------------------------

# Get the current jj operation ID.
get_jj_op() {
  jj -R "$REPO" op log --no-graph -T id -n 1 2>/dev/null
}

# Get the current working-copy revision's change ID (short 8 chars).
get_wc_change_id() {
  jj -R "$REPO" log -r '@' --no-graph -T 'change_id.short(8)' 2>/dev/null
}

# Get the current working-copy revision's commit ID (short).
get_wc_commit() {
  jj -R "$REPO" log -r '@' --no-graph -T 'commit_id.short(8)' 2>/dev/null
}

# Get the commit that a bookmark points to (short commit ID).
# Usage: get_bookmark_commit BOOKMARK
get_bookmark_commit() {
  jj -R "$REPO" log -r "$1" --no-graph -T 'commit_id.short(8)' 2>/dev/null
}

# Get the full commit ID for a revision.
# Usage: get_full_commit_id REV
get_full_commit_id() {
  jj -R "$REPO" log -r "$1" --no-graph -T 'commit_id' 2>/dev/null
}

# Get the commit message for a revision.
# Usage: get_commit_message REV
get_commit_message() {
  jj -R "$REPO" log -r "$1" --no-graph -T 'description' 2>/dev/null
}

# Get the first line of the commit message for a revision.
# Usage: get_commit_message_first_line REV
get_commit_message_first_line() {
  jj -R "$REPO" log -r "$1" --no-graph -T 'description.first_line()' 2>/dev/null
}

# Get the list of files modified in a commit.
# Usage: get_modified_files REV
get_modified_files() {
  jj -R "$REPO" diff -r "$1" --name-only 2>/dev/null
}

# List all files tracked at a revision.
# Usage: get_file_list REV
get_file_list() {
  jj -R "$REPO" file list -r "$1" 2>/dev/null
}

# Check if working copy is clean (empty diff, no pending changes).
is_wc_clean() {
  local result
  result="$(jj -R "$REPO" log -r '@' --no-graph -T 'empty' 2>/dev/null)"
  [[ "$result" == "true" ]]
}

# Check if a given revision has an empty diff.
# Usage: is_diff_empty REV
is_diff_empty() {
  local rev="$1"
  local diff_output
  diff_output="$(jj -R "$REPO" diff -r "$rev" --name-only 2>/dev/null)"
  [[ -z "$diff_output" ]]
}

# Read the repository's current operation ID without loading any working copy.
# Unlike get_jj_op this records nothing, and it still answers when the
# canonical workspace is stale — which is exactly when a test needs to prove
# that a command wrote nothing.
# Usage: get_jj_op_bare [REPO]
get_jj_op_bare() {
  local repo="${1:-$REPO}"
  jj -R "$repo" --ignore-working-copy op log --no-graph -T id -n 1 2>/dev/null
}

# Print the workspace name the repository records for a worktree path.
# Usage: get_workspace_name WORKTREE
get_workspace_name() {
  local worktree="$1"
  local resolved
  resolved="$(cd "$worktree" && pwd -P)" || return 1
  local line name path
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%%: *}"
    path="${line#*: }"
    [[ "$path" == "$resolved" ]] || continue
    printf '%s\n' "$name"
    return 0
  done < <(jj -R "$REPO" --ignore-working-copy workspace list --no-pager \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)
  return 1
}

# Leave WORKTREE's on-disk files behind the commit they belong to, the way a
# bare rewrite performed from another workspace does, so that the backend
# refuses every command there until the worktree is refreshed.
#
# The rewrite addresses the target by workspace name from the canonical repo,
# so it cannot be attributed to the target workspace and cannot update its
# files. The resulting refusal is asserted rather than assumed: a backend that
# stopped producing this state would otherwise silently disarm every test that
# depends on it.
#
# Sets STALE_PRE_REWRITE_COMMIT to the commit the worktree's files are left
# holding — the one the rewrite moved the graph off. Callers cannot capture it
# themselves, since the marker snapshot below advances the working-copy commit.
#
# Only one marker path is rewritten, never the whole tree. A worktree's branch
# is read from the task symlink recorded in its working-copy commit, so wiping
# the tree would leave it on no branch at all / a different condition, and one
# that quietly removes the worktree from the target list of commands like
# tt worktree sync.
# Usage: make_worktree_stale WORKTREE
make_worktree_stale() {
  local worktree="$1"
  local name
  name="$(get_workspace_name "$worktree")" || {
    _log_fail "make_worktree_stale: '$worktree' is not a workspace of $REPO"
    _record_fail "make_worktree_stale: unknown workspace $worktree"
    return 1
  }

  # Give the working-copy commit a file of its own, snapshotting it so the
  # workspace's recorded state is current: the staleness that follows is then
  # caused by the rewrite below and nothing else.
  local marker='.tt-stale-marker'
  printf 'marker\n' > "$worktree/$marker"
  jj -R "$worktree" log -r '@' --no-graph -T '' >/dev/null 2>&1 || true

  STALE_PRE_REWRITE_COMMIT="$(jj -R "$worktree" --ignore-working-copy \
    log -r '@' --no-graph -T 'commit_id' 2>/dev/null)"

  # Bare rewrite of just that path out of the target's working-copy commit:
  # the tree changes in the graph while the files on disk stay where they
  # were, which is what the backend calls stale.
  jj -R "$REPO" --ignore-working-copy restore --from 'root()' --into "${name}@" \
    "$marker" >/dev/null 2>&1 || {
    _log_fail "make_worktree_stale: could not rewrite the working-copy commit of $worktree"
    _record_fail "make_worktree_stale: rewrite failed for $worktree"
    return 1
  }

  if jj -R "$worktree" status >/dev/null 2>&1; then
    _log_fail "make_worktree_stale: $worktree is still usable after the rewrite"
    _record_fail "make_worktree_stale: $worktree did not become stale"
    return 1
  fi
  return 0
}

# Build the state a canonical-guard refusal test acts on: a project, a task
# beneath it, and that task checked out into its own dedicated worktree.
# Sets STALE_PROJ_ID, STALE_TASK_ID and STALE_WORKTREE. Makes nothing stale,
# so a test needing further setup can do it before calling
# make_worktree_stale "$REPO" itself.
# Usage: setup_guard_fixture [SLUG]
setup_guard_fixture() {
  local slug="${1:-guarded}"
  STALE_PROJ_ID="$(create_project "proj-$slug" "Project")"
  checkout_task "$STALE_PROJ_ID"
  STALE_TASK_ID="$(create_task "$slug" "Task $slug")"
  STALE_WORKTREE="$(create_task_worktree "$STALE_TASK_ID")"
}

# setup_guard_fixture followed by making the canonical workspace stale — the
# starting state of a canonical-guard refusal test that needs no extra setup.
# Usage: setup_stale_canonical [SLUG]
setup_stale_canonical() {
  setup_guard_fixture "$@"
  make_worktree_stale "$REPO"
}

# Run a branch-writing command from WORKTREE with the canonical workspace
# stale, and assert the standard refusal: non-zero exit, a message naming the
# stale workspace and the command that recovers it, no history entry created,
# and no operation recorded.
#
# The operation check is what proves the command wrote nothing at all, and it
# is read bare — an ordinary read would be refused by the stale workspace it
# is asking about.
# Usage: assert_refuses_stale_canonical WORKTREE COMMAND...
assert_refuses_stale_canonical() {
  local worktree="$1"; shift
  get_history_lines
  local history_before="${#HISTORY_LINES[@]}"
  local op_before
  op_before="$(get_jj_op_bare)"

  local output exit_code=0
  output="$(run_tt_in_worktree "$worktree" "$@" </dev/null 2>&1)" || exit_code=$?

  assert_failure "refused while the canonical workspace is stale" "$exit_code"
  assert_contains "the refusal names the stale workspace" "$output" \
    "Error: The workspace is stale: $REPO"
  assert_contains "the refusal names the recovery command" "$output" \
    "tt worktree refresh"
  assert_history_count "no transaction was opened" "$history_before"
  assert_eq "the repository was not written to" "$(get_jj_op_bare)" "$op_before"
}

# Create a plain jj commit in the current repo (does not advance any bookmarks).
# Usage: jj_commit MESSAGE [REPO]
jj_commit() {
  local msg="$1"
  local repo="${2:-$REPO}"
  jj -R "$repo" commit -m "$msg" >/dev/null 2>&1
}

# Read a file from a specific revision.
# Usage: read_file_at_rev REV PATH
read_file_at_rev() {
  jj -R "$REPO" file show -r "$1" -- "$2" 2>/dev/null
}

# Check if a bookmark exists.
# Usage: bookmark_exists BOOKMARK
bookmark_exists() {
  jj -R "$REPO" log -r "$1" --no-graph -T '' >/dev/null 2>&1
}

# Check if ANCESTOR is a strict ancestor of DESCENDANT in the VCS DAG.
# Strict: a revision is NOT an ancestor of itself.
# Usage: is_vcs_ancestor ANCESTOR DESCENDANT
is_vcs_ancestor() {
  local ancestor="$1" descendant="$2"
  # NOTE: the `A::B` revset is empty when A is not an ancestor of B, but `jj log`
  # still exits 0 in that case. The emptiness of the *output* is what carries the
  # answer, so a real template must be used and the result inspected -- checking
  # the exit code alone would make this function unconditionally true.
  local reachable
  reachable="$(jj -R "$REPO" log -r "${ancestor}::${descendant}" --no-graph \
    -T 'commit_id ++ "\n"' 2>/dev/null)" || return 1
  [[ -n "$reachable" ]] || return 1

  # `::` is inclusive at both ends, so reject the A == B case separately.
  local a b
  a="$(jj -R "$REPO" log -r "$ancestor" -n 1 --no-graph -T 'commit_id' 2>/dev/null)"
  b="$(jj -R "$REPO" log -r "$descendant" -n 1 --no-graph -T 'commit_id' 2>/dev/null)"
  [[ "$a" != "$b" ]]
}

# Get the list of bookmarks at a given revision.
# Usage: get_bookmarks_at REV
get_bookmarks_at() {
  jj -R "$REPO" log -r "$1" --no-graph \
    -T 'bookmarks.map(|b| b.name()).join("\n")' 2>/dev/null
}

# Get all task/project bookmarks in the repo.
# Usage: get_all_task_bookmarks
get_all_task_bookmarks() {
  jj -R "$REPO" log -r 'bookmarks()' \
    -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' \
    --no-graph 2>/dev/null | grep -E '^(task|project)/' | sort -u
}

# Count the number of commits in a revset.
# Usage: count_commits REVSET
count_commits() {
  local marks
  marks="$(jj -R "$REPO" log -r "$1" --no-graph -T '"x\n"' 2>/dev/null)"
  marks="${marks//[!x]/}"
  printf '%s' "${#marks}"
}

# Check if a revset contains any conflicts.
# Usage: has_conflicts REVSET
has_conflicts() {
  local result
  result="$(jj -R "$REPO" log -r "$1" --no-graph \
    -T 'if(conflict, "yes\n")' 2>/dev/null)" || true
  [[ -n "$result" ]]
}

# Check if a file exists at a specific revision.
# Usage: file_exists_at_rev REV PATH
file_exists_at_rev() {
  jj -R "$REPO" file show -r "$1" -- "$2" >/dev/null 2>&1
}

# Check if a symlink exists in the working copy and where it points.
# Usage: get_symlink_target PATH
get_symlink_target() {
  readlink "$1" 2>/dev/null
}

# Print the target of the symlink recorded at the repo-root-relative PATH at
# REV. Prints nothing and returns 1 when PATH is absent or not a symlink there.
# Usage: get_symlink_target_at_rev REV PATH
get_symlink_target_at_rev() {
  local rev="$1" path="$2"
  jj -R "$REPO" --ignore-working-copy diff --git --from 'root()' --to "$rev" \
    -- "root-file:\"${path}\"" 2>/dev/null | awk '
      /^new file mode 120000$/ { symlink = 1 }
      symlink && !found && /^\+[^+]/ { found = 1; print substr($0, 2) }
      END { exit(found ? 0 : 1) }
    '
}

# ---------------------------------------------------------------------------
# Log Helpers
# ---------------------------------------------------------------------------

_log_pass() { printf '%b  ✓ %s%b\n' "$_GREEN" "$1" "$_RESET" >&2; }
_log_fail() { printf '%b  ✗ %s%b\n' "$_RED" "$1" "$_RESET" >&2; }
_log_skip() { printf '%b  ⊘ %s%b\n' "$_YELLOW" "$1" "$_RESET" >&2; }
_log_section() {
  # Print elapsed time for the previous section if one was running
  local now elapsed
  now="$(_ms_now)"
  if [[ "$_SECTION_START" != "$_SUITE_START" ]]; then
    elapsed=$(( now - _SECTION_START ))
    printf '%b  (%d.%03ds)%b\n' "$_YELLOW" "$(( elapsed / 1000 ))" "$(( elapsed % 1000 ))" "$_RESET" >&2
  fi
  _SECTION_START="$now"
  printf '\n%b── %s%b\n' "$_BOLD" "$1" "$_RESET" >&2
}

# ---------------------------------------------------------------------------
# Generic Assertion Helpers
# ---------------------------------------------------------------------------

# _record_pass / _record_fail / _record_skip
# Write a result to the shared temp dir so subshells contribute to totals.
_record_pass() { printf 'p\n' >> "${_TT_TEST_RESULTS_DIR:-$_RESULTS_DIR}/results"; }
_record_fail() { printf 'f\n' >> "${_TT_TEST_RESULTS_DIR:-$_RESULTS_DIR}/results"; printf '%s\n' "$1" >> "${_TT_TEST_RESULTS_DIR:-$_RESULTS_DIR}/failures"; }
_record_skip() { printf 's\n' >> "${_TT_TEST_RESULTS_DIR:-$_RESULTS_DIR}/results"; }

# assert_eq LABEL ACTUAL EXPECTED
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected '$expected', got '$actual'"
    _record_fail "$label: expected '$expected', got '$actual'"
  fi
}

# assert_neq LABEL ACTUAL UNEXPECTED
assert_neq() {
  local label="$1" actual="$2" unexpected="$3"
  if [[ "$actual" != "$unexpected" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected value to differ from '$unexpected'"
    _record_fail "$label: expected value to differ from '$unexpected'"
  fi
}

# assert_contains LABEL HAYSTACK NEEDLE
# _harness_contains HAYSTACK NEEDLE
# Fixed-string containment, as `grep -F` sees it: any line of NEEDLE present
# in HAYSTACK. A single-line needle is a plain substring test.
_harness_contains() {
  local haystack="$1" needle="$2" part
  if [[ "$needle" != *$'\n'* ]]; then
    [[ "$haystack" == *"$needle"* ]]
    return
  fi
  while IFS= read -r part || [[ -n "$part" ]]; do
    [[ "$haystack" == *"$part"* ]] && return 0
  done <<< "$needle"
  return 1
}

# _harness_line_matches STRING ERE
# Whether any line of STRING matches ERE, as `grep -E` sees it.
_harness_line_matches() {
  local string="$1" pattern="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $pattern ]] && return 0
  done <<< "$string"
  return 1
}

# _harness_id_pattern PATTERN
# Expands every %…% placeholder in PATTERN to the ERE for a task ID suffix.
_harness_id_pattern() {
  local pattern="$1"
  while [[ "$pattern" == *%*%* ]]; do
    local head="${pattern%%%*}" rest="${pattern#*%}"
    rest="${rest#*%}"
    pattern="${head}[a-z0-9-]+-[0-9a-f]{8}${rest}"
  done
  printf '%s' "$pattern"
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if _harness_contains "$haystack" "$needle"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected to contain '$needle'"
    printf '    Actual: %s\n' "$haystack" >&2
    _record_fail "$label: expected to contain '$needle'"
  fi
}

# assert_not_contains LABEL HAYSTACK NEEDLE
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! _harness_contains "$haystack" "$needle"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected NOT to contain '$needle'"
    _record_fail "$label: expected NOT to contain '$needle'"
  fi
}

# assert_matches LABEL STRING PATTERN
# PATTERN is an extended regex (ERE).
# %SLUG% shorthand: matches a task/project ID with given slug.
assert_matches() {
  local label="$1" string="$2" pattern="$3"
  local ere_pattern
  ere_pattern="$(_harness_id_pattern "$pattern")"
  if _harness_line_matches "$string" "$ere_pattern"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected to match pattern '$pattern' (ERE: '$ere_pattern')"
    printf '    Actual: %s\n' "$string" >&2
    _record_fail "$label: expected to match '$pattern'"
  fi
}

# assert_not_matches LABEL STRING PATTERN
assert_not_matches() {
  local label="$1" string="$2" pattern="$3"
  local ere_pattern
  ere_pattern="$(_harness_id_pattern "$pattern")"
  if ! _harness_line_matches "$string" "$ere_pattern"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected NOT to match pattern '$pattern'"
    _record_fail "$label: expected NOT to match '$pattern'"
  fi
}

# assert_file_exists LABEL PATH
assert_file_exists() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: file not found: $path"
    _record_fail "$label: file not found: $path"
  fi
}

# assert_file_not_exists LABEL PATH
assert_file_not_exists() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: file should not exist: $path"
    _record_fail "$label: file should not exist: $path"
  fi
}

# assert_symlink LABEL PATH EXPECTED_TARGET
assert_symlink() {
  local label="$1" path="$2" expected="$3"
  if [[ -L "$path" ]]; then
    local actual
    actual="$(readlink "$path")"
    assert_eq "$label" "$actual" "$expected"
  else
    _log_fail "$label: not a symlink: $path"
    _record_fail "$label: not a symlink: $path"
  fi
}

# assert_exit_code LABEL EXPECTED ACTUAL
assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  assert_eq "$label (exit code)" "$actual" "$expected"
}

# assert_success LABEL EXIT_CODE
assert_success() {
  local label="$1" exit_code="$2"
  assert_eq "$label (should succeed)" "$exit_code" "0"
}

# assert_failure LABEL EXIT_CODE
assert_failure() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" != "0" ]]; then
    _log_pass "$label (exit code $exit_code)"
    _record_pass
  else
    _log_fail "$label: expected non-zero exit code, got 0"
    _record_fail "$label: expected non-zero exit code, got 0"
  fi
}

# assert_output_empty LABEL OUTPUT
assert_output_empty() {
  local label="$1" output="$2"
  if [[ -z "$output" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected empty output, got: $output"
    _record_fail "$label: expected empty output"
  fi
}

# assert_output_not_empty LABEL OUTPUT
assert_output_not_empty() {
  local label="$1" output="$2"
  if [[ -n "$output" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected non-empty output"
    _record_fail "$label: expected non-empty output"
  fi
}

# assert_line_count LABEL OUTPUT EXPECTED_COUNT
assert_line_count() {
  local label="$1" output="$2" expected="$3"
  local actual
  actual="$(printf '%s' "$output" | grep -c . 2>/dev/null || true)"
  assert_eq "$label (line count)" "$actual" "$expected"
}

# ---------------------------------------------------------------------------
# VCS-Specific Assertion Helpers
# ---------------------------------------------------------------------------

# assert_commit_empty LABEL REV
assert_commit_empty() {
  local label="$1" rev="$2"
  if is_diff_empty "$rev"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: commit '$rev' is not empty (has file changes)"
    _record_fail "$label: commit '$rev' is not empty"
  fi
}

# assert_commit_not_empty LABEL REV
assert_commit_not_empty() {
  local label="$1" rev="$2"
  if ! is_diff_empty "$rev"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: commit '$rev' should not be empty"
    _record_fail "$label: commit '$rev' should be non-empty"
  fi
}

# assert_bookmark_exists LABEL BOOKMARK
assert_bookmark_exists() {
  local label="$1" bookmark="$2"
  if bookmark_exists "$bookmark"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: bookmark '$bookmark' does not exist"
    _record_fail "$label: bookmark '$bookmark' does not exist"
  fi
}

# assert_bookmark_not_exists LABEL BOOKMARK
assert_bookmark_not_exists() {
  local label="$1" bookmark="$2"
  if ! bookmark_exists "$bookmark"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: bookmark '$bookmark' should not exist"
    _record_fail "$label: bookmark '$bookmark' should not exist"
  fi
}

# assert_wc_clean LABEL
assert_wc_clean() {
  local label="$1"
  if is_wc_clean; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: working copy is not clean"
    _record_fail "$label: working copy is not clean"
  fi
}

# assert_wc_dirty LABEL
assert_wc_dirty() {
  local label="$1"
  if ! is_wc_clean; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: working copy should be dirty"
    _record_fail "$label: working copy should be dirty"
  fi
}

# assert_commit_message LABEL REV EXPECTED
assert_commit_message() {
  local label="$1" rev="$2" expected="$3"
  local msg
  msg="$(get_commit_message "$rev")"
  assert_eq "$label" "$msg" "$expected"
}

# assert_commit_message_first_line LABEL REV EXPECTED
assert_commit_message_first_line() {
  local label="$1" rev="$2" expected="$3"
  local actual
  actual="$(get_commit_message_first_line "$rev")"
  assert_eq "$label" "$actual" "$expected"
}

# assert_file_on_branch LABEL BRANCH PATH
assert_file_on_branch() {
  local label="$1" branch="$2" path="$3"
  if file_exists_at_rev "$branch" "$path"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: file '$path' not found on branch '$branch'"
    _record_fail "$label: file '$path' not found on branch '$branch'"
  fi
}

# assert_file_not_on_branch LABEL BRANCH PATH
assert_file_not_on_branch() {
  local label="$1" branch="$2" path="$3"
  if ! file_exists_at_rev "$branch" "$path"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: file '$path' should not exist on branch '$branch'"
    _record_fail "$label: file '$path' should not exist on branch '$branch'"
  fi
}

# assert_file_content_at_rev LABEL REV PATH EXPECTED_CONTENT
assert_file_content_at_rev() {
  local label="$1" rev="$2" path="$3" expected="$4"
  local actual
  actual="$(read_file_at_rev "$rev" "$path")" || {
    _log_fail "$label: could not read $path at $rev"
    _record_fail "$label: could not read $path at $rev"
    return
  }
  assert_contains "$label" "$actual" "$expected"
}

# assert_no_conflicts LABEL [REVSET]
assert_no_conflicts() {
  local label="$1" revset="${2:-bookmarks()}"
  local conflicted
  conflicted="$(jj -R "$REPO" log -r "$revset" --no-graph \
    -T 'if(conflict, commit_id.short(8) ++ " " ++ description.first_line() ++ "\n")' \
    2>/dev/null)" || true
  if [[ -z "$conflicted" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: conflicting commits found:"
    printf '%s\n' "$conflicted" | while IFS= read -r line; do
      printf '    %s\n' "$line" >&2
    done
    _record_fail "$label: conflicting commits found"
  fi
}

# assert_is_ancestor LABEL ANCESTOR_REV DESCENDANT_REV
assert_is_ancestor() {
  local label="$1" ancestor="$2" descendant="$3"
  if is_vcs_ancestor "$ancestor" "$descendant"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: '$ancestor' is not an ancestor of '$descendant'"
    _record_fail "$label: '$ancestor' is not an ancestor of '$descendant'"
  fi
}

# assert_not_ancestor LABEL ANCESTOR_REV DESCENDANT_REV
assert_not_ancestor() {
  local label="$1" ancestor="$2" descendant="$3"
  if ! is_vcs_ancestor "$ancestor" "$descendant"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: '$ancestor' should not be an ancestor of '$descendant'"
    _record_fail "$label: '$ancestor' should not be an ancestor of '$descendant'"
  fi
}

# assert_revset_count LABEL REVSET EXPECTED_COUNT
assert_revset_count() {
  local label="$1" revset="$2" expected="$3"
  local actual
  actual="$(count_commits "$revset")"
  assert_eq "$label" "$actual" "$expected"
}

# ---------------------------------------------------------------------------
# Task File Helpers
# ---------------------------------------------------------------------------

# Read the TASK.md for a given task ID from its branch (default) or from REV.
# Usage: content=$(read_task_file "task/my-task-abc12345")
read_task_file() {
  local task_id="$1" rev="${2:-$1}"
  local suffix="${task_id#*/}"
  jj -R "$REPO" file show -r "$rev" -- ".tt/task/$suffix/TASK.md" 2>/dev/null
}

# Extract a single-value frontmatter field.
get_frontmatter_field() {
  local content="$1" field="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$field:"* ]]; then
      line="${line#"$field:"}"
      printf '%s\n' "${line#"${line%%[! ]*}"}"
      return 0
    fi
  done <<< "$content"
}

# Extract all values for a repeatable frontmatter field.
get_frontmatter_field_all() {
  local content="$1" field="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$field:"* ]]; then
      line="${line#"$field:"}"
      printf '%s\n' "${line#"${line%%[! ]*}"}"
    fi
  done <<< "$content"
}

# Extract the body (everything after the second ---).
get_task_body() {
  local content="$1" line sep=0 found=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$found" ]]; then
      printf '%s\n' "$line"
    elif [[ "$line" == '---' ]]; then
      sep=$(( sep + 1 ))
      [[ $sep -eq 2 ]] && found=1
    fi
  done <<< "$content"
}

# ---------------------------------------------------------------------------
# Task Status / Frontmatter Assertions
# ---------------------------------------------------------------------------

# assert_task_status LABEL TASK_ID EXPECTED_STATUS [REV]
assert_task_status() {
  local label="$1" task_id="$2" expected="$3"
  local rev="${4:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  actual="$(get_frontmatter_field "$content" "status")"
  assert_eq "$label" "$actual" "$expected"
}

# assert_task_title LABEL TASK_ID EXPECTED_TITLE [REV]
assert_task_title() {
  local label="$1" task_id="$2" expected="$3"
  local rev="${4:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  actual="$(get_frontmatter_field "$content" "title")"
  actual="${actual#\"}"
  actual="${actual%\"}"
  assert_eq "$label" "$actual" "$expected"
}

# assert_task_label LABEL TASK_ID EXPECTED_LABEL [REV]
assert_task_label() {
  local label="$1" task_id="$2" expected="$3"
  local rev="${4:-$task_id}"
  local content labels
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  labels="$(get_frontmatter_field_all "$content" "label")"
  assert_contains "$label" "$labels" "$expected"
}

# assert_task_no_label LABEL TASK_ID UNEXPECTED_LABEL [REV]
assert_task_no_label() {
  local label="$1" task_id="$2" unexpected="$3"
  local rev="${4:-$task_id}"
  local content labels
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  labels="$(get_frontmatter_field_all "$content" "label")"
  assert_not_contains "$label" "$labels" "$unexpected"
}

# assert_task_body_contains LABEL TASK_ID NEEDLE [REV]
assert_task_body_contains() {
  local label="$1" task_id="$2" needle="$3"
  local rev="${4:-$task_id}"
  local content body
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  body="$(get_task_body "$content")"
  assert_contains "$label" "$body" "$needle"
}

# assert_frontmatter_field LABEL TASK_ID FIELD EXPECTED_VALUE [REV]
assert_frontmatter_field() {
  local label="$1" task_id="$2" field="$3" expected="$4"
  local rev="${5:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  actual="$(get_frontmatter_field "$content" "$field")"
  assert_eq "$label" "$actual" "$expected"
}

# assert_frontmatter_field_count LABEL TASK_ID FIELD EXPECTED_COUNT [REV]
assert_frontmatter_field_count() {
  local label="$1" task_id="$2" field="$3" expected="$4"
  local rev="${5:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  actual="$(get_frontmatter_field_all "$content" "$field" | grep -c . 2>/dev/null || true)"
  assert_eq "$label" "$actual" "$expected"
}

# ---------------------------------------------------------------------------
# Subtask Entry Assertions
# ---------------------------------------------------------------------------

# assert_subtask_entry LABEL PARENT_ID CHILD_ID EXPECTED_CHECKBOX [REV]
assert_subtask_entry() {
  local label="$1" parent_id="$2" child_id="$3" expected_checkbox="$4"
  local rev="${5:-$parent_id}"
  local content
  content="$(read_task_file "$parent_id" "$rev")" || {
    _log_fail "$label: could not read task file for parent '$parent_id'"
    _record_fail "$label: could not read task file for parent '$parent_id'"
    return
  }
  local expected_line="subtask: ${expected_checkbox} ${child_id}"
  assert_contains "$label" "$content" "$expected_line"
}

# assert_no_subtask_entry LABEL PARENT_ID CHILD_ID [REV]
assert_no_subtask_entry() {
  local label="$1" parent_id="$2" child_id="$3"
  local rev="${4:-$parent_id}"
  local content
  content="$(read_task_file "$parent_id" "$rev")" || {
    _log_fail "$label: could not read task file for parent '$parent_id'"
    _record_fail "$label: could not read task file for parent '$parent_id'"
    return
  }
  if printf '%s' "$content" | grep -qF "subtask: " && \
     printf '%s' "$content" | grep "subtask: " | grep -qF "$child_id"; then
    _log_fail "$label: parent '$parent_id' still has a subtask entry for '$child_id'"
    _record_fail "$label: parent still has subtask entry for '$child_id'"
  else
    _log_pass "$label"
    _record_pass
  fi
}

# ---------------------------------------------------------------------------
# Context Assertions
# ---------------------------------------------------------------------------

# assert_context_entry LABEL TASK_ID CTX_ID [REV]
assert_context_entry() {
  local label="$1" task_id="$2" ctx_id="$3"
  local rev="${4:-$task_id}"
  local content
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  assert_contains "$label" "$content" "context: $ctx_id"
}

# assert_no_context_entry LABEL TASK_ID CTX_ID [REV]
assert_no_context_entry() {
  local label="$1" task_id="$2" ctx_id="$3"
  local rev="${4:-$task_id}"
  local content
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  assert_not_contains "$label" "$content" "context: $ctx_id"
}

# assert_context_file_exists LABEL TASK_ID CTX_ID [REV]
assert_context_file_exists() {
  local label="$1" task_id="$2" ctx_id="$3"
  local rev="${4:-$task_id}"
  local suffix="${task_id#*/}"
  local ctx_path=".tt/task/$suffix/${ctx_id}.md"
  assert_file_on_branch "$label" "$rev" "$ctx_path"
}

# assert_context_file_not_exists LABEL TASK_ID CTX_ID [REV]
assert_context_file_not_exists() {
  local label="$1" task_id="$2" ctx_id="$3"
  local rev="${4:-$task_id}"
  local suffix="${task_id#*/}"
  local ctx_path=".tt/task/$suffix/${ctx_id}.md"
  assert_file_not_on_branch "$label" "$rev" "$ctx_path"
}

# assert_context_count LABEL TASK_ID EXPECTED_COUNT [REV]
assert_context_count() {
  local label="$1" task_id="$2" expected="$3"
  local rev="${4:-$task_id}"
  assert_frontmatter_field_count "$label" "$task_id" "context" "$expected" "$rev"
}

# ---------------------------------------------------------------------------
# Frontmatter Ordering Assertion
# ---------------------------------------------------------------------------

# assert_frontmatter_order LABEL CONTENT
#
# Validates that CONTENT has a well-formed frontmatter block with fields in
# canonical order. Checks:
#   1. Starts with "---" and contains a second "---" closing delimiter.
#   2. Each frontmatter line matches the pattern: <known-key>: <value>
#      (known keys: title, status, created, updated, label, context, subtask)
#   3. All present fields appear in canonical order:
#      title < status < created < updated < label < context < subtask
#      (every occurrence of key A precedes every occurrence of key B)
#
# CONTENT is the raw file content (including `---` delimiters and body).
assert_frontmatter_order() {
  local label="$1" content="$2"
  local result
  result="$(printf '%s' "$content" | awk '
    BEGIN {
      split("title,status,created,updated,label,context,subtask", _keys, ",")
      for (_i = 1; _i <= length(_keys); _i++) rank[_keys[_i]] = _i
      prev_rank = 0
      errors = 0
      sep = 0
    }
    /^---$/ {
      sep++
      if (sep == 2) { if (errors == 0) print "ok"; exit }
      next
    }
    sep == 1 {
      k = $0; sub(/:.*$/, "", k)
      if (!(k in rank)) {
        print "unknown key: " k " at line " NR
        errors++
        next
      }
      r = rank[k]
      if (r < prev_rank) {
        print "ordering violation: " k " (rank " r ") after rank " prev_rank " at line " NR
        errors++
      }
      prev_rank = r
    }
    END { if (sep < 2 && errors == 0) { print "missing closing ---" } }
  ')" || true
  if [[ "$result" == "ok" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: $result"
    _record_fail "$label: $result"
  fi
}

# ---------------------------------------------------------------------------
# Current Task / Misc Assertions
# ---------------------------------------------------------------------------
#
# Two different questions, and two sets of assertions for them:
#
#   Where does a working copy sit in the commit graph?  assert_wc_on_branch
#   Which task does a worktree have checked out?        assert_task_symlink
#
# They agree in a healthy checkout and part company as soon as a branch write
# moves a bookmark off the worktree's line: the working copy's nearest
# bookmarked ancestor is then some outer branch, while the task it holds has
# not changed. assert_current_task requires both, which is what a checkout
# leaves behind.

# Nearest bookmarked ancestor of WORKTREE's @ (default: $REPO), or empty when
# nothing in its ancestry carries a bookmark.
# Usage: branch=$(wc_branch [WORKTREE])
wc_branch() {
  local worktree="${1:-$REPO}"
  local actual
  actual="$(jj -R "$worktree" log -r 'heads(ancestors(@) & bookmarks())' -n 1 --no-graph \
    -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  printf '%s' "${actual%%,*}"
}

# assert_wc_on_branch LABEL EXPECTED_BOOKMARK [WORKTREE]
assert_wc_on_branch() {
  local label="$1" expected="$2" worktree="${3:-$REPO}"
  assert_eq "$label" "$(wc_branch "$worktree")" "$expected"
}

# assert_wc_on_branch_matches LABEL EXPECTED_ERE_PATTERN [WORKTREE]
assert_wc_on_branch_matches() {
  local label="$1" pattern="$2" worktree="${3:-$REPO}"
  assert_matches "$label" "$(wc_branch "$worktree")" "$pattern"
}

# The task WORKTREE (default: $REPO) has checked out, as recorded by the root
# TASK.md symlink the task branch's fork commit plants there.
# Usage: assert_task_symlink LABEL TASK_ID [WORKTREE]
assert_task_symlink() {
  local label="$1" task_id="$2" worktree="${3:-$REPO}"
  assert_symlink "$label" "$worktree/TASK.md" ".tt/task/${task_id#*/}/TASK.md"
}

# The root TASK.md symlink recorded at REV points at TASK_ID's task file.
# Usage: assert_task_symlink_at_rev LABEL REV TASK_ID
assert_task_symlink_at_rev() {
  local label="$1" rev="$2" task_id="$3"
  assert_eq "$label" "$(get_symlink_target_at_rev "$rev" TASK.md)" \
    ".tt/task/${task_id#*/}/TASK.md"
}

# Both halves of a checkout: WORKTREE records TASK_ID as the task it holds, and
# its working copy is parked on that task's branch.
# Usage: assert_current_task LABEL TASK_ID [WORKTREE]
assert_current_task() {
  local label="$1" task_id="$2" worktree="${3:-$REPO}"
  assert_task_symlink "$label (checked-out task)" "$task_id" "$worktree"
  assert_wc_on_branch "$label (working copy position)" "$task_id" "$worktree"
}

# ---------------------------------------------------------------------------
# Transaction History Assertions
# ---------------------------------------------------------------------------

declare -a HISTORY_LINES=()

# Read all lines from .tt/history into HISTORY_LINES.
get_history_lines() {
  HISTORY_LINES=()
  local hf="$REPO/.tt/history"
  if [[ -f "$hf" && -s "$hf" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && HISTORY_LINES+=("$line")
    done < "$hf"
  fi
}

history_before_op() { printf '%s' "${1%%:*}"; }
history_after_op()  { printf '%s' "${1#*:}"; }

# assert_history_count LABEL EXPECTED_COUNT
assert_history_count() {
  local label="$1" expected="$2"
  get_history_lines
  assert_eq "$label" "${#HISTORY_LINES[@]}" "$expected"
}

# assert_subtask_count LABEL PARENT_ID EXPECTED_COUNT [REV]
assert_subtask_count() {
  local label="$1" parent_id="$2" expected="$3"
  local rev="${4:-$parent_id}"
  assert_frontmatter_field_count "$label" "$parent_id" "subtask" "$expected" "$rev"
}

# assert_history_integrity LABEL [CHAIN_DEPTH]
#
# Verifies:
#   1. No in-progress entries: every after-op-id is non-empty.
#   2. The last entry's after-op-id matches the current jj operation ID,
#      i.e. no jj operations have happened since the last tt command.
#   3. Chain contiguity for the last CHAIN_DEPTH entries:
#      entry[i].after == entry[i+1].before for the tail of the log.
#      Defaults to the full history length (all entries checked).
#
# Why gaps can occur: jj auto-snapshots the working copy whenever files
# change between tt commands, advancing the op log without a history entry.
# Each entry's before-op remains a valid restore point, so undo correctness
# is unaffected. Pass an explicit CHAIN_DEPTH equal to the number of tt
# commands your test section issued to limit the contiguity check to those
# entries and avoid false failures from snapshots triggered earlier in setup.
assert_history_integrity() {
  local label="$1" chain_depth="${2:-}"
  get_history_lines
  local count="${#HISTORY_LINES[@]}"

  if [[ $count -eq 0 ]]; then
    _log_pass "$label (empty history)"
    _record_pass
    return
  fi

  # Check 1: no in-progress entry (every after-op-id must be non-empty)
  local i
  for ((i=0; i<count; i++)); do
    local after
    after="$(history_after_op "${HISTORY_LINES[$i]}")"
    if [[ -z "$after" ]]; then
      _log_fail "$label: in-progress transaction at entry $i (empty after-op)"
      _record_fail "$label: in-progress transaction at entry $i"
      return
    fi
  done

  # Check 2: last after-op matches current jj op
  local last_after current_op
  last_after="$(history_after_op "${HISTORY_LINES[$((count-1))]}")"  
  current_op="$(get_jj_op)"
  if [[ "$last_after" != "$current_op" ]]; then
    _log_fail "$label: last after-op (${last_after:0:12}) != current jj op (${current_op:0:12})"
    _record_fail "$label: history out of sync with jj"
    return
  fi

  # Check 3: chain contiguity for the last CHAIN_DEPTH entries (default: all)
  local effective_depth=$(( chain_depth > 0 ? chain_depth : count ))
  if [[ $effective_depth -gt 1 ]]; then
    # The tail slice starts at index (count - effective_depth), clamped to 0.
    local start=$(( count - effective_depth ))
    [[ $start -lt 0 ]] && start=0
    for ((i=start; i<count-1; i++)); do
      local this_after next_before
      this_after="$(history_after_op "${HISTORY_LINES[$i]}")"
      next_before="$(history_before_op "${HISTORY_LINES[$((i+1))]}")"    
      if [[ "$this_after" != "$next_before" ]]; then
        _log_fail "$label: history chain broken at entry $i (last $chain_depth checked): after (${this_after:0:12}) != next before (${next_before:0:12})"
        _record_fail "$label: history chain broken at entry $i"
        return
      fi
    done
  fi

  _log_pass "$label"
  _record_pass
}

# assert_no_pending_transaction LABEL
assert_no_pending_transaction() {
  local label="$1"
  get_history_lines
  local count="${#HISTORY_LINES[@]}"
  if [[ $count -eq 0 ]]; then
    _log_pass "$label (empty history)"
    _record_pass
    return
  fi
  local last_after
  last_after="$(history_after_op "${HISTORY_LINES[$((count-1))]}")"  
  if [[ -z "$last_after" ]]; then
    _log_fail "$label: last history entry is in-progress (no after-op-id)"
    _record_fail "$label: dangling in-progress transaction"
  else
    _log_pass "$label"
    _record_pass
  fi
}

# ---------------------------------------------------------------------------
# .tt Workspace Integrity Assertions
# ---------------------------------------------------------------------------

# Print a human-readable tree of all bookmarks and their task files to stderr.
dump_task_structure() {
  printf '\n%b── Task structure dump ──%b\n' "$_CYAN" "$_RESET" >&2
  jj -R "$REPO" bookmark list --no-pager 2>/dev/null | awk '{print $1}' | while IFS= read -r bm; do
    [[ "$bm" == task/* || "$bm" == project/* ]] || continue
    local suffix="${bm#*/}"
    printf '  %s\n' "$bm" >&2
    local content
    content="$(jj -R "$REPO" file show -r "$bm" -- ".tt/task/$suffix/TASK.md" 2>/dev/null)" || continue
    local status title
    status="$(printf '%s' "$content" | sed -n 's/^status: *//p' | head -1)"
    title="$(printf '%s' "$content" | sed -n 's/^title: *//p' | head -1 | sed 's/^"//;s/"$//')"
    printf '    title: %s\n    status: %s\n' "$title" "$status" >&2
    printf '%s' "$content" | grep '^subtask: ' | while IFS= read -r st; do
      printf '    %s\n' "$st" >&2
    done
    printf '%s' "$content" | grep '^context: ' | while IFS= read -r ctx; do
      printf '    %s\n' "$ctx" >&2
    done
  done
  printf '\n' >&2
}

# Comprehensive structural integrity check of the .tt workspace state.
assert_tt_workspace_integrity() {
  local label="$1"
  local errors=0

  local -a bookmarks=()
  while IFS= read -r bm; do
    # `jj bookmark list` prints "<name>: <rev> …"; strip the trailing colon.
    bm="${bm%:}"
    [[ "$bm" == task/* || "$bm" == project/* ]] && bookmarks+=("$bm")
  done < <(jj -R "$REPO" bookmark list --no-pager 2>/dev/null | awk '{print $1}')

  for bm in "${bookmarks[@]}"; do
    local suffix="${bm#*/}"
    local task_file=".tt/task/$suffix/TASK.md"

    # Check 1: task file exists on own branch
    if ! file_exists_at_rev "$bm" "$task_file"; then
      printf '%b    ✗ %s: task file missing on own branch: %s%b\n' \
        "$_RED" "$label" "$task_file" "$_RESET" >&2
      ((errors++)) || true
      continue
    fi

    local content
    content="$(jj -R "$REPO" file show -r "$bm" -- "$task_file" 2>/dev/null)"

    # Check 2: every subtask: reference is a valid bookmark
    while IFS= read -r st_line; do
      local child_id="${st_line##*] }"
      if ! bookmark_exists "$child_id"; then
        printf '%b    ✗ %s: subtask reference to non-existent bookmark: %s (on %s)%b\n' \
          "$_RED" "$label" "$child_id" "$bm" "$_RESET" >&2
        ((errors++)) || true
      fi
    done < <(printf '%s' "$content" | grep '^subtask: ' | sed 's/^subtask: //')

    # Check 3: every context: reference has a corresponding file
    while IFS= read -r ctx_id; do
      local ctx_file=".tt/task/$suffix/${ctx_id}.md"
      if ! file_exists_at_rev "$bm" "$ctx_file"; then
        printf '%b    ✗ %s: context reference to missing file: %s (on %s)%b\n' \
          "$_RED" "$label" "$ctx_file" "$bm" "$_RESET" >&2
        ((errors++)) || true
      fi
    done < <(printf '%s' "$content" | grep '^context: ' | sed 's/^context: //')

  done

  # Check 4: no in-progress transaction
  get_history_lines
  local hcount="${#HISTORY_LINES[@]}"
  if [[ $hcount -gt 0 ]]; then
    local last_after
    last_after="$(history_after_op "${HISTORY_LINES[$((hcount-1))]}")"
    if [[ -z "$last_after" ]]; then
      printf '%b    ✗ %s: in-progress transaction in .tt/history%b\n' \
        "$_RED" "$label" "$_RESET" >&2
      ((errors++)) || true
    fi
  fi

  if [[ $errors -eq 0 ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: $errors workspace integrity error(s)"
    _record_fail "$label: $errors workspace integrity error(s)"
  fi
}

# ---------------------------------------------------------------------------
# Summary and Exit
# ---------------------------------------------------------------------------

# Print test summary and exit with appropriate code.
# Tallies results written by subshells via _record_pass/_record_fail/_record_skip.
# suite_summary
#
# Print pass/fail/skip totals for this suite.
# When _TT_TEST_RESULTS_DIR is set the runner owns the final summary; this
# becomes a no-op so each individual suite does not print its own summary box.
suite_summary() {
  # Runner owns the summary when it provides a shared results dir.
  [[ -n "${_TT_TEST_RESULTS_DIR:-}" ]] && return 0
  _harness_print_summary "$_RESULTS_DIR"
}

# _harness_print_summary RESULTS_DIR
# Print the summary box from a results directory.
_harness_print_summary() {
  local results_dir="$1"
  local pass=0 fail=0 skip=0
  if [[ -f "$results_dir/results" ]]; then
    while IFS= read -r rec; do
      case "$rec" in
        p) ((pass++)) || true ;;
        f) ((fail++)) || true ;;
        s) ((skip++)) || true ;;
      esac
    done < "$results_dir/results"
  fi

  local now total_elapsed
  now="$(_ms_now)"
  total_elapsed=$(( now - _SUITE_START ))
  printf '\n%b══════════════════════════════════════════════════════════════%b\n' "$_CYAN" "$_RESET" >&2
  printf '%b  Results: %d passed, %d failed, %d skipped  (%d.%03ds)%b\n' \
    "$_BOLD" "$pass" "$fail" "$skip" "$(( total_elapsed / 1000 ))" "$(( total_elapsed % 1000 ))" "$_RESET" >&2
  if [[ -f "$results_dir/failures" && -s "$results_dir/failures" ]]; then
    printf '\n%b  Failures:%b\n' "$_RED" "$_RESET" >&2
    while IFS= read -r f; do
      printf '%b    • %s%b\n' "$_RED" "$f" "$_RESET" >&2
    done < "$results_dir/failures"
  fi
  printf '%b══════════════════════════════════════════════════════════════%b\n' "$_CYAN" "$_RESET" >&2

  [[ $fail -eq 0 ]]
}

# run_tests TITLE
#
# Print the suite title, discover all test_* functions defined in the sourcing
# script, optionally filter them, then run them and print a summary.
#
# TITLE  Human-readable suite name, e.g. "tt task checkin".
#
# Environment variables (set by the runner; not intended for direct use):
#
#   _TT_TEST_RUN_ONLY
#     Internal. When set, run only the named test function and exit.
#     Set by the flat pool in test runner; never set directly by users.
#
#   _TT_TEST_FORCE_COLOR
#     Internal. When set, enable ANSI colors even though stderr is not a TTY
#     (because the subprocess output will be replayed on a real TTY by the runner).
#
#   _TT_TEST_FILTER_0, _TT_TEST_FILTER_1, ...
#     ERE patterns (bash =~ operator). A test is included if its full label
#     ("TITLE: function_name") matches ANY of the supplied patterns. When no
#     patterns are set all tests are included.
#
#   _TT_TEST_REGISTER=1
#     Registration pass: write the filtered test names (one per line) to
#     "$_TT_TEST_RESULTS_DIR/tests/$_TT_TEST_SUITE_INDEX" and exit without
#     running any tests. Used by the runner to build the flat test list
#     before the real run.
#
#   _TT_TEST_RESULTS_DIR
#     Shared results directory. _record_pass/fail/skip write here instead of
#     the local temp dir, and suite_summary becomes a no-op (the runner
#     prints a single summary at the end).
#
#   _TT_TEST_OFFSET, _TT_TEST_TOTAL
#     Starting index (0-based) and global total for [n/N] labels.
#
# Usage: call once at the end of a test file in place of suite_summary.
run_tests() {
  local title="${1:?run_tests requires a suite title argument}"

  # Discover all test_* functions in the sourcing script.
  local -a all_tests=()
  while IFS= read -r fn; do
    all_tests+=("$fn")
  done < <(compgen -A function test_)

  # Apply --filter patterns if any are set.
  local -a tests=()
  local -a filter_patterns=()
  local k=0
  while true; do
    local var="_TT_TEST_FILTER_${k}"
    [[ -z "${!var+set}" ]] && break
    filter_patterns+=("${!var}")
    (( k++ )) || true
  done

  if [[ ${#filter_patterns[@]} -eq 0 ]]; then
    tests=("${all_tests[@]}")
  else
    for fn in "${all_tests[@]}"; do
      local label="$title: $fn"
      local matched=false
      for pattern in "${filter_patterns[@]}"; do
        if [[ "$label" =~ $pattern ]]; then
          matched=true
          break
        fi
      done
      [[ "$matched" == true ]] && tests+=("$fn")
    done
  fi

  # Registration pass: write filtered test names and exit without running.
  if [[ "${_TT_TEST_REGISTER:-}" == "1" ]]; then
    local tests_dir="${_TT_TEST_RESULTS_DIR:?_TT_TEST_RESULTS_DIR required for registration}/tests"
    mkdir -p "$tests_dir"
    printf '%s\n' "${tests[@]}" > "$tests_dir/${_TT_TEST_SUITE_INDEX:?_TT_TEST_SUITE_INDEX required for registration}"
    return 0
  fi

  local suite_total=${#tests[@]}
  local global_offset="${_TT_TEST_OFFSET:-0}"
  local global_total="${_TT_TEST_TOTAL:-$suite_total}"

  if [[ ${#tests[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ -n "${_TT_TEST_RUN_ONLY:-}" ]]; then
    _harness_run_one "$title" "$global_offset" "$global_total" "$_TT_TEST_RUN_ONLY"
  else
    _harness_run_serial "$title" "$suite_total" "${tests[@]}"
  fi

  suite_summary
}

# _harness_run_serial TITLE TOTAL TEST...
# Run test functions sequentially, using _log_section for timing.
_harness_run_serial() {
  local title="$1" total="$2"; shift 2
  local global_offset="${_TT_TEST_OFFSET:-0}"
  local global_total="${_TT_TEST_TOTAL:-$total}"
  local i=0
  for fn in "$@"; do
    (( i++ )) || true
    local global_idx=$(( global_offset + i ))
    _log_section "[$global_idx/$global_total] $title: $fn"
    ( "$fn" )
  done
}


# _harness_run_one TITLE GLOBAL_OFFSET GLOBAL_TOTAL FN
# Run a single named test function (used by the flat pool in test runner).
_harness_run_one() {
  local title="$1" global_offset="$2" global_total="$3" fn="$4"
  local global_idx=$(( global_offset + 1 ))
  _log_section "[$global_idx/$global_total] $title: $fn"
  ( "$fn" )
  local now elapsed
  now="$(_ms_now)"
  elapsed=$(( now - _SECTION_START ))
  printf '%b  (%d.%03ds)%b\n' "$_YELLOW" "$(( elapsed / 1000 ))" "$(( elapsed % 1000 ))" "$_RESET" >&2
}

# Skip a test with a reason.
skip_test() {
  _log_skip "$1: $2"
  _record_skip
}

# ---------------------------------------------------------------------------
# Usage Instructions Assertion Helpers
# ---------------------------------------------------------------------------

# Assert that usage output starts with "Usage: <command-name>".
# Checks the first line begins with "Usage: " followed by the expected command name.
# Usage: assert_usage_command_name LABEL OUTPUT EXPECTED_COMMAND
assert_usage_command_name() {
  local label="$1" output="$2" expected="$3"
  local first_line
  first_line="$(printf '%s' "$output" | head -1)"
  local expected_prefix="Usage: ${expected}"
  # Check that first line starts with "Usage: <command-name>"
  if [[ "$first_line" == "${expected_prefix}"* ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected first line to start with '$expected_prefix', got: '$first_line'"
    _record_fail "$label: expected first line to start with '$expected_prefix', got: '$first_line'"
  fi
}

# Assert that a required argument appears both in the Usage: line AND as an
# indented description line. Use for positional arguments like <task-id> that
# are shown in the Usage: summary line.
# Usage: assert_required_usage_argument LABEL OUTPUT ARGUMENT [ALIAS]
assert_required_usage_argument() {
  local label="$1" output="$2" argument="$3" alias="${4:-}"
  local first_line
  first_line="$(printf '%s' "$output" | head -1)"
  local escaped_arg
  escaped_arg="$(_escape_ere "$argument")"

  # Check 1: argument appears in Usage line with word-boundary context
  local usage_has_arg=false
  if printf '%s' "$first_line" | grep -qE "(^|[^a-zA-Z0-9-])${escaped_arg}([^a-zA-Z0-9-]|\$)"; then
    usage_has_arg=true
  fi
  if [[ "$usage_has_arg" == true ]]; then
    _log_pass "$label (in Usage line)"
    _record_pass
  else
    _log_fail "$label (in Usage line): argument '$argument' not found in Usage line: '$first_line'"
    _record_fail "$label (in Usage line): argument '$argument' not found in Usage line"
  fi

  # Check 2: argument (with optional alias) starts an indented description line
  local escaped_alias=""
  if [[ -n "$alias" ]]; then
    escaped_alias="$(_escape_ere "$alias"), "
  fi
  local detail_has_arg=false
  if printf '%s' "$output" | grep -qE "^  ${escaped_alias}${escaped_arg}[^a-zA-Z0-9_]"; then
    detail_has_arg=true
  fi
  if [[ "$detail_has_arg" == true ]]; then
    _log_pass "$label (documented)"
    _record_pass
  else
    _log_fail "$label (documented): no indented description line found for '$argument'"
    _record_fail "$label (documented): no indented description line found for '$argument'"
  fi
}

# Assert that an optional argument (typically a --flag) appears as an indented
# description line. Skips the Usage-line check since options are often omitted
# from the Usage: summary line.
# Usage: assert_optional_usage_argument LABEL OUTPUT ARGUMENT [ALIAS]
assert_optional_usage_argument() {
  local label="$1" output="$2" argument="$3" alias="${4:-}"
  local escaped_arg
  escaped_arg="$(_escape_ere "$argument")"

  # Check: argument (with optional alias) starts an indented description line
  local escaped_alias=""
  if [[ -n "$alias" ]]; then
    escaped_alias="$(_escape_ere "$alias"), "
  fi
  local detail_has_arg=false
  if printf '%s' "$output" | grep -qE "^  ${escaped_alias}${escaped_arg}[^a-zA-Z0-9_]"; then
    detail_has_arg=true
  fi
  if [[ "$detail_has_arg" == true ]]; then
    _log_pass "$label (documented)"
    _record_pass
  else
    _log_fail "$label (documented): no indented description line found for '$argument'"
    _record_fail "$label (documented): no indented description line found for '$argument'"
  fi
}
