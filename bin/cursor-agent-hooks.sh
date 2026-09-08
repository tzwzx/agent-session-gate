#!/usr/bin/env bash
# Do not use `set -e`: we must capture the verify command's status without
# exiting this script. Stay compatible with macOS bash 3.2.

set -u

VERSION="2.2.0"

STATE_DIR="${CURSOR_AGENT_HOOKS_STATE_DIR:-${TMPDIR:-/tmp}/cursor-agent-hooks}"

usage() {
  cat <<'EOF'
Cursor hooks toolkit: session-change gate and after-edit formatter.

Usage:
  cursor-agent-hooks session-start
  cursor-agent-hooks after-edit -- <command...>
  cursor-agent-hooks stop [-- <command...>]

Options:
  -h, --help       Show this help
  -v, --version    Show the version

All subcommands read the agent hook payload as JSON on stdin.

  session-start   Record the working-tree baseline for this session
  after-edit      Run <command> with the edited file path appended, only when
                  that file is inside the current project.
                  No default formatter; omit -- <command...> and it no-ops
  stop            Run <command> only when the working tree changed.
                  Default: .cursor/hooks/stop.sh
                  (no-op if it is missing or not executable)

Environment:
  CURSOR_AGENT_HOOKS_STATE_DIR   Where baselines are stored
                                 (default: $TMPDIR/cursor-agent-hooks)

Requirements: git and jq.
When either of them is missing, session-start/stop fail safe: the command
always runs. after-edit exits 0 without running the command if jq is missing.
EOF
}

# Hash tracked diffs plus untracked paths/contents. Print nothing when the
# state cannot be determined so callers treat empty as unknown and run the command.
worktree_hash() {
  local root hash
  root=$(git rev-parse --show-toplevel) || return 1
  hash=$(
    set -o pipefail
    cd "$root" || exit 1
    {
      git diff --binary --no-ext-diff --no-textconv HEAD
      git ls-files --others --exclude-standard -z &&
        git ls-files --others --exclude-standard -z | xargs -0 git hash-object --no-filters --
    } | git hash-object --stdin
  ) || return 1
  printf '%s\n' "$hash"
} 2>/dev/null

record_baseline() {
  [ -n "$SESSION_ID" ] || return 0
  mkdir -p "$STATE_DIR"
  worktree_hash >"$STATE_DIR/$SESSION_ID"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  -v | --version)
    printf '%s\n' "$VERSION"
    exit 0
    ;;
  session-start | after-edit | stop) ;;
  *)
    usage >&2
    exit 2
    ;;
esac

cmd=$1
shift

# after-edit always uses the caller's PWD as the project root. Do not follow
# workspace_roots[0] in a multi-root workspace.
if [ "$cmd" = after-edit ]; then
  [ "${1:-}" = "--" ] && shift
  [ $# -eq 0 ] && exit 0
  file=$(jq -r '.file_path // .tool_input.file_path // empty' 2>/dev/null) || file=
  [ -n "$file" ] && [ -f "$file" ] || exit 0
  root=$PWD
  case "$file" in
    "$root"/*) ;;
    *) exit 0 ;;
  esac
  "$@" "$file" >/dev/null 2>&1 || true
  exit 0
fi

# Cursor stop sends conversation_id; still accept session_id. Missing jq or
# broken JSON leaves these empty and we fail open (run the command).
SESSION_ID= HOOK_CWD= SOURCE=
eval "$(jq -r '@sh "SESSION_ID=\(.session_id // .conversation_id // "") HOOK_CWD=\(.cwd // (.workspace_roots // [])[0] // "") SOURCE=\(.source // "")"' 2>/dev/null)"

# Cursor launches project hooks from that root. Prefer PWD when it is a git
# worktree; do not follow workspace_roots[0]. Fall back to payload cwd only
# when PWD is outside a worktree.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$HOOK_CWD" ]; then
    cd "$HOOK_CWD" 2>/dev/null || true
  fi
fi

if [ "$cmd" = session-start ]; then
  # Compaction continues the same session. Overwriting here would drop edits
  # made before the compact.
  if [ "$SOURCE" != compact ]; then
    record_baseline
  fi
  exit 0
fi

[ "${1:-}" = "--" ] && shift
if [ $# -eq 0 ]; then
  if [ ! -x ".cursor/hooks/stop.sh" ]; then
    exit 0
  fi
  set -- .cursor/hooks/stop.sh
fi

STATE="$STATE_DIR/$SESSION_ID"
CURRENT=$(worktree_hash)

# Fail open: if session key, current hash, or baseline is missing, run verify.
if [ -n "$SESSION_ID" ] && [ -n "$CURRENT" ] && [ -f "$STATE" ] &&
  [ "$(<"$STATE")" = "$CURRENT" ]; then
  exit 0
fi

OUTPUT=$(NO_COLOR=1 "$@" 2>&1)
STATUS=$?

# Verify may rewrite files; record the post-run tree as the new baseline even
# on failure so an unfixable problem does not loop. The next stop then sees
# no change and passes.
record_baseline

# Emit both current and legacy keys; consumers disagree on which they read.
if [ $STATUS -ne 0 ]; then
  printf '%s failed. Fix the following.\n\n%s' "$*" "$OUTPUT" |
    jq -Rs '{decision: "block", reason: ., followup_message: .}' 2>/dev/null
fi

exit 0
