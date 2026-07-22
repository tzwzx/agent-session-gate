#!/usr/bin/env bash
# Run a verification command only when the working tree changed during the
# current AI coding agent session.
#
#   agent-session-gate session-start          Record the baseline for this session
#   agent-session-gate stop -- <command...>   Run <command> only if the tree changed
#
# Wire these into the agent's SessionStart and Stop hooks. On turns that change
# nothing (answering a question, reading code) the Stop hook exits immediately
# instead of re-running the whole check suite.
#
# Supported agents (hook payload keys differ per agent):
#   Claude Code / Codex CLI   session_id        decision + reason
#   Cursor                    conversation_id   followup_message
#
# Note: `set -e` is deliberately NOT used. This script has to capture the exit
# status of a failing verification command rather than dying together with it.
#
# Note: must stay compatible with the bash 3.2 that ships with macOS.

set -u

VERSION="1.0.0"

STATE_DIR="${AGENT_SESSION_GATE_STATE_DIR:-${TMPDIR:-/tmp}/agent-session-gate}"

JQ_CMD=$(command -v jq 2>/dev/null || echo "")
SHA_CMD=$(command -v shasum 2>/dev/null || command -v sha1sum 2>/dev/null || echo "")

usage() {
  cat <<'EOF'
Run a verification command only when the working tree changed this session.

Usage:
  agent-session-gate session-start
  agent-session-gate stop -- <command...>

Options:
  -h, --help       Show this help
  -v, --version    Show the version

Both subcommands read the agent hook payload as JSON on stdin.

Environment:
  AGENT_SESSION_GATE_STATE_DIR   Where baselines are stored
                                 (default: $TMPDIR/agent-session-gate)

Requirements: git, jq, and shasum (or sha1sum).
When any of them is missing the gate fails safe: the command always runs.
EOF
}

# Hash the working tree state: tracked changes plus the content of untracked
# files. Prints nothing when the state cannot be determined, and callers treat
# an empty value as "unknown" and fall back to running the command.
worktree_hash() {
  local root
  [ -n "$SHA_CMD" ] || return 1
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  (
    cd "$root" || exit 1
    git diff HEAD 2>/dev/null
    git ls-files --others --exclude-standard -z 2>/dev/null |
      xargs -0 "$SHA_CMD" 2>/dev/null
  ) | "$SHA_CMD" | cut -d ' ' -f 1
}

# Read a jq expression from the hook payload held in $INPUT.
payload() {
  [ -n "$JQ_CMD" ] || return 0
  printf '%s' "$INPUT" | "$JQ_CMD" -r "$1" 2>/dev/null
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
esac

INPUT=$(cat)

# The session key is named differently per agent. Cursor only exposes
# conversation_id on its stop hook, so both spellings are accepted.
SESSION_ID=$(payload '.session_id // .conversation_id // empty')

# The working directory of a hook process is up to the agent, so move to the
# workspace the payload points at before touching git.
HOOK_CWD=$(payload '.cwd // (.workspace_roots // [])[0] // empty')
if [ -n "$HOOK_CWD" ]; then
  cd "$HOOK_CWD" 2>/dev/null || true
fi

case "${1:-}" in
  session-start)
    # A compaction continues the same session, so the baseline must survive it.
    # Overwriting here would silently drop edits made before the compaction.
    if [ "$(payload '.source // empty')" != "compact" ] && [ -n "$SESSION_ID" ]; then
      mkdir -p "$STATE_DIR"
      worktree_hash >"$STATE_DIR/$SESSION_ID"
    fi
    ;;

  stop)
    shift
    [ "${1:-}" = "--" ] && shift
    [ $# -eq 0 ] && exit 0

    STATE="$STATE_DIR/$SESSION_ID"
    CURRENT=$(worktree_hash)

    # Fail safe: when the session key, the current state or the baseline is
    # missing, give up on the comparison and verify anyway.
    if [ -n "$SESSION_ID" ] && [ -n "$CURRENT" ] && [ -f "$STATE" ] &&
      [ "$(cat "$STATE")" = "$CURRENT" ]; then
      exit 0
    fi

    OUTPUT=$(NO_COLOR=1 "$@" 2>&1)
    STATUS=$?

    # Verification commands usually rewrite files through their auto-fixers, so
    # the state after the run becomes the new baseline. Recording it on failure
    # too is what stops an agent that cannot fix the problem from looping: the
    # next stop sees an unchanged tree and is allowed through.
    if [ -n "$SESSION_ID" ]; then
      mkdir -p "$STATE_DIR"
      worktree_hash >"$STATE"
    fi

    # Agents read different keys to be sent back to work, so emit all of them.
    if [ $STATUS -ne 0 ] && [ -n "$JQ_CMD" ]; then
      printf '%s failed. Fix the following.\n\n%s' "$*" "$OUTPUT" |
        "$JQ_CMD" -Rs '{decision: "block", reason: ., followup_message: .}'
    fi
    ;;

  *)
    usage >&2
    exit 2
    ;;
esac

exit 0
