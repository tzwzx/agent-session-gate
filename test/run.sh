#!/usr/bin/env bash
# Exercise the gate against a disposable git repo under $TMPDIR.

set -uo pipefail

GATE="$(cd "$(dirname "$0")/.." && pwd)/bin/agent-hooks.sh"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$3" "$2"
}

check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

REPO=$(mktemp -d)
STATE=$(mktemp -d)
export AGENT_HOOKS_STATE_DIR="$STATE"

cleanup() { rm -rf "$REPO" "$STATE" "${OUTSIDE:-}" "${OTHER:-}" "${NON_GIT:-}"; }
trap cleanup EXIT

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
printf 'hello\n' >"$REPO/tracked.txt"
git -C "$REPO" add -A
git -C "$REPO" -c commit.gpgsign=false commit -qm init

# Count runs via a marker file. Failure cases print from a file so the gate's
# command-line echo is not mistaken for the command output.
MARKER="$REPO/.ran"
MESSAGE="$REPO/.msg"
printf 'KABOOM: something is broken\n' >"$MESSAGE"
RUN_OK=(sh -c "echo ran >>'$MARKER'")
RUN_NG=(sh -c "echo ran >>'$MARKER'; cat '$MESSAGE'; exit 1")

runs() {
  if [ -f "$MARKER" ]; then wc -l <"$MARKER" | tr -d ' '; else printf ''; fi
}

payload() { printf '{"session_id":"%s","cwd":"%s"%s}' "$1" "$REPO" "${2:-}"; }

start() { payload "$1" "${2:-}" | (cd "$REPO" && "$GATE" session-start); }
stop() {
  local id=$1
  shift
  payload "$id" | (cd "$REPO" && "$GATE" stop -- "$@")
}
stop_default() {
  payload "$1" | (cd "$REPO" && "$GATE" stop)
}

printf '\nagent-hooks\n\n'

start s1
check "session-start records a baseline" "$([ -s "$STATE/s1" ] && echo yes || echo no)" "yes"

stop s1 "${RUN_OK[@]}" >/dev/null
check "stop skips while the tree is unchanged" "$(runs)" ""

printf 'edited\n' >>"$REPO/tracked.txt"
stop s1 "${RUN_OK[@]}" >/dev/null
check "stop runs after a tracked file changes" "$(runs)" "1"

printf 'new\n' >"$REPO/untracked.txt"
stop s1 "${RUN_OK[@]}" >/dev/null
check "stop runs after an untracked file appears" "$(runs)" "2"

stop s1 "${RUN_OK[@]}" >/dev/null
check "stop skips again once the tree settles" "$(runs)" "2"

stop no-baseline "${RUN_OK[@]}" >/dev/null
check "stop runs when no baseline exists (fail safe)" "$(runs)" "3"

printf '{"cwd":"%s"}' "$REPO" | (cd "$REPO" && "$GATE" stop -- "${RUN_OK[@]}") >/dev/null
check "stop runs without a session id (fail safe)" "$(runs)" "4"

start s2
BEFORE=$(cat "$STATE/s2")
printf 'more\n' >>"$REPO/tracked.txt"
start s2 ',"source":"compact"'
check "compaction keeps the original baseline" "$(cat "$STATE/s2")" "$BEFORE"

start s2 ',"source":"resume"'
check "resume refreshes the baseline" "$([ "$(cat "$STATE/s2")" != "$BEFORE" ] && echo yes || echo no)" "yes"

printf '{"conversation_id":"c1","workspace_roots":["%s"]}' "$REPO" | (cd "$REPO" && "$GATE" session-start)
check "cursor payload records a baseline" "$([ -s "$STATE/c1" ] && echo yes || echo no)" "yes"

BEFORE_RUNS=$(runs)
printf '{"conversation_id":"c1","status":"completed","loop_count":0,"workspace_roots":["%s"]}' "$REPO" |
  (cd "$REPO" && "$GATE" stop -- "${RUN_OK[@]}") >/dev/null
check "cursor payload skips an unchanged tree" "$(runs)" "$BEFORE_RUNS"

printf '{"session_id":"cc1","transcript_path":"/dev/null","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$REPO" |
  (cd "$REPO" && "$GATE" session-start)
check "claude code payload records a baseline" "$([ -s "$STATE/cc1" ] && echo yes || echo no)" "yes"

BEFORE_RUNS=$(runs)
printf '{"session_id":"cc1","transcript_path":"/dev/null","cwd":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$REPO" |
  (cd "$REPO" && "$GATE" stop -- "${RUN_OK[@]}") >/dev/null
check "claude code payload skips an unchanged tree" "$(runs)" "$BEFORE_RUNS"

LEGACY_STATE=$(mktemp -d)
printf '{"session_id":"legacy","cwd":"%s"}' "$REPO" |
  (cd "$REPO" && unset AGENT_HOOKS_STATE_DIR && CURSOR_AGENT_HOOKS_STATE_DIR="$LEGACY_STATE" "$GATE" session-start)
check "legacy CURSOR_AGENT_HOOKS_STATE_DIR is still honored" "$([ -s "$LEGACY_STATE/legacy" ] && echo yes || echo no)" "yes"
rm -rf "$LEGACY_STATE"

start s3
printf 'break\n' >>"$REPO/tracked.txt"
OUT=$(stop s3 "${RUN_NG[@]}")
check "failure emits decision=block" "$(printf '%s' "$OUT" | jq -r '.decision')" "block"
check "failure emits followup_message for cursor" "$(printf '%s' "$OUT" | jq -r '.reason == .followup_message')" "true"
check "failure keeps the command output" "$(printf '%s' "$OUT" | jq -r '.reason' | grep -c 'KABOOM')" "1"
check "failure names the command" "$(printf '%s' "$OUT" | jq -r '.reason' | head -1 | grep -c '^sh -c .* failed\. Fix the following\.$')" "1"

BEFORE_RUNS=$(runs)
stop s3 "${RUN_NG[@]}" >/dev/null
check "an unfixed failure does not loop" "$(runs)" "$BEFORE_RUNS"

printf 'payload\n' >"$REPO/untracked-src.txt"
start s4
BEFORE_RUNS=$(runs)
mv "$REPO/untracked-src.txt" "$REPO/untracked-dst.txt"
stop s4 "${RUN_OK[@]}" >/dev/null
check "stop runs after an untracked file is renamed" "$(runs)" "$((BEFORE_RUNS + 1))"

printf '\0\1\2' >"$REPO/bin.dat"
git -C "$REPO" add bin.dat
git -C "$REPO" -c commit.gpgsign=false commit -qm bin
start s5
printf '\0\1\3' >"$REPO/bin.dat"
stop s5 "${RUN_OK[@]}" >/dev/null
BEFORE_RUNS=$(runs)
printf '\0\1\4' >"$REPO/bin.dat"
stop s5 "${RUN_OK[@]}" >/dev/null
check "stop runs after a same-length binary rewrite" "$(runs)" "$((BEFORE_RUNS + 1))"

start s6
ln -s /nonexistent "$REPO/broken-link"
BEFORE_RUNS=$(runs)
stop s6 "${RUN_OK[@]}" >/dev/null
check "stop runs when an untracked file is unreadable (fail safe)" "$(runs)" "$((BEFORE_RUNS + 1))"
BEFORE_RUNS=$(runs)
stop s6 "${RUN_OK[@]}" >/dev/null
check "unreadable untracked keeps failing safe" "$(runs)" "$((BEFORE_RUNS + 1))"
rm -f "$REPO/broken-link"

OUTSIDE=$(mktemp -d)
printf '{"session_id":"out","cwd":"%s"}' "$OUTSIDE" | (cd "$OUTSIDE" && "$GATE" session-start)
BEFORE_RUNS=$(runs)
printf '{"session_id":"out","cwd":"%s"}' "$OUTSIDE" | (cd "$OUTSIDE" && "$GATE" stop -- "${RUN_OK[@]}") >/dev/null
check "stop runs outside a git repository (fail safe)" "$(runs)" "$((BEFORE_RUNS + 1))"

ARGS="$REPO/.args"
STOP_SH="$REPO/.cursor/hooks/stop.sh"
printf 'export const probe={a:1}\n' >"$REPO/src.ts"
record_args() {
  (cd "$REPO" && "$GATE" after-edit -- sh -c 'printf "%s\n" "$*" >>"$0"' "$ARGS")
}
logged_args() {
  if [ -f "$ARGS" ]; then cat "$ARGS"; else printf ''; fi
}
install_stop_sh() {
  mkdir -p "$(dirname "$STOP_SH")"
  printf '%s\n' '#!/bin/sh' "echo ran >>'$MARKER'" >"$STOP_SH"
  chmod +x "$STOP_SH"
}

rm -f "$ARGS"
printf '{"file_path":"%s"}' "$REPO/src.ts" | record_args
check "after-edit appends the edited file path" "$(logged_args)" "$REPO/src.ts"

rm -f "$ARGS"
printf '{"tool_input":{"file_path":"%s"}}' "$REPO/src.ts" | record_args
check "after-edit reads tool_input.file_path" "$(logged_args)" "$REPO/src.ts"

rm -f "$ARGS"
printf '{"hook_event_name":"PostToolUse","tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' "$REPO/src.ts" | record_args
check "after-edit reads tool_input.notebook_path" "$(logged_args)" "$REPO/src.ts"

rm -f "$ARGS"
printf '{"tool_input":{"file_path":"src.ts"}}' | record_args
check "after-edit resolves a relative path against PWD" "$(logged_args)" "$REPO/src.ts"

rm -f "$ARGS"
LINK="$STATE/repo-link"
ln -s "$REPO" "$LINK"
printf '{"file_path":"%s"}' "$REPO/src.ts" | (cd "$LINK" && "$GATE" after-edit -- sh -c 'printf "%s\n" "$*" >>"$0"' "$ARGS")
check "after-edit accepts a project reached through a symlink" "$(logged_args)" "$REPO/src.ts"
rm -f "$LINK"

rm -f "$ARGS"
printf 'outside\n' >"$OUTSIDE/other.ts"
printf '{"file_path":"%s"}' "$OUTSIDE/other.ts" | record_args
check "after-edit skips a file outside the project" "$(logged_args)" ""

rm -f "$ARGS"
printf '{}' | record_args
check "after-edit skips a payload without file_path" "$(logged_args)" ""

rm -f "$ARGS"
printf '{"file_path":"%s"}' "$REPO/missing.ts" | record_args
check "after-edit skips a missing file" "$(logged_args)" ""

after_edit_rc=0
printf '{"file_path":"%s"}' "$REPO/src.ts" | (cd "$REPO" && "$GATE" after-edit -- sh -c 'exit 1') || after_edit_rc=$?
check "after-edit exits 0 when the command fails" "$after_edit_rc" "0"

rm -f "$ARGS"
printf '{"file_path":"%s"}' "$REPO/src.ts" | (cd "$REPO" && "$GATE" after-edit)
check "after-edit skips when no command follows" "$(logged_args)" ""

rm -f "$ARGS"
printf '{"file_path":"%s"}' "$REPO/src.ts" | (cd "$REPO" && "$GATE" after-edit --)
check "after-edit -- with no command is a no-op" "$(logged_args)" ""

rm -f "$STOP_SH"
start sd-missing
printf 'default-missing\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
stop_default sd-missing >/dev/null
check "stop no-ops when default stop.sh is missing" "$(runs)" "$BEFORE_RUNS"

install_stop_sh
start sd-default
printf 'default-present\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
stop_default sd-default >/dev/null
check "stop defaults to .cursor/hooks/stop.sh" "$(runs)" "$((BEFORE_RUNS + 1))"

BEFORE_RUNS=$(runs)
stop_default sd-default >/dev/null
check "stop skips default stop.sh when the tree is unchanged" "$(runs)" "$BEFORE_RUNS"

STOP_DEFAULT_LOG="$REPO/.stop-default"
printf '%s\n' '#!/bin/sh' "echo default-stop >>'$STOP_DEFAULT_LOG'" >"$STOP_SH"
chmod +x "$STOP_SH"
start sd-override
printf 'default-override\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
stop sd-override "${RUN_OK[@]}" >/dev/null
check "stop -- overrides the default stop.sh" "$(runs)" "$((BEFORE_RUNS + 1))"
check "stop -- does not run default stop.sh" "$( [ -f "$STOP_DEFAULT_LOG" ] && echo yes || echo no )" "no"

printf '%s\n' '#!/bin/sh' "echo ran >>'$MARKER'" >"$STOP_SH"
chmod +x "$STOP_SH"
start sd-empty-dash
printf 'default-empty-dash\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
payload sd-empty-dash | (cd "$REPO" && "$GATE" stop --) >/dev/null
check "stop -- with no command uses default stop.sh" "$(runs)" "$((BEFORE_RUNS + 1))"

printf '%s\n' '#!/bin/sh' "echo ran >>'$MARKER'" >"$STOP_SH"
chmod -x "$STOP_SH"
start sd-notx
printf 'default-notx\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
stop_default sd-notx >/dev/null
check "stop no-ops when default stop.sh is not executable" "$(runs)" "$BEFORE_RUNS"
rm -f "$STOP_SH"

CLAUDE_STOP_SH="$REPO/.claude/hooks/stop.sh"
mkdir -p "$(dirname "$CLAUDE_STOP_SH")"
printf '%s\n' '#!/bin/sh' "echo ran >>'$MARKER'" >"$CLAUDE_STOP_SH"
chmod +x "$CLAUDE_STOP_SH"
start sd-claude
printf 'default-claude\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
stop_default sd-claude >/dev/null
check "stop falls back to .claude/hooks/stop.sh" "$(runs)" "$((BEFORE_RUNS + 1))"

printf '%s\n' '#!/bin/sh' "echo default-stop >>'$STOP_DEFAULT_LOG'" >"$CLAUDE_STOP_SH"
install_stop_sh
start sd-both
printf 'default-both\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
stop_default sd-both >/dev/null
check "stop prefers .cursor/hooks/stop.sh when both exist" "$(runs)" "$((BEFORE_RUNS + 1))"
check "stop runs only one default stop.sh" "$( [ -f "$STOP_DEFAULT_LOG" ] && echo yes || echo no )" "no"
rm -f "$STOP_SH" "$CLAUDE_STOP_SH"

OTHER=$(mktemp -d)
git -C "$OTHER" init -q
git -C "$OTHER" config user.email test@example.com
git -C "$OTHER" config user.name test
printf 'other\n' >"$OTHER/tracked.txt"
git -C "$OTHER" add -A
git -C "$OTHER" -c commit.gpgsign=false commit -qm init

payload_other() {
  printf '{"session_id":"%s","cwd":"%s","workspace_roots":["%s"]}' "$1" "$OTHER" "$OTHER"
}

start_other_payload() { payload_other "$1" | (cd "$REPO" && "$GATE" session-start); }
stop_other_payload() {
  local id=$1
  shift
  payload_other "$id" | (cd "$REPO" && "$GATE" stop -- "$@")
}

start_other_payload mr-run
printf 'multi-root-repo\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
stop_other_payload mr-run "${RUN_OK[@]}" >/dev/null
check "stop uses PWD project when payload points at another root" "$(runs)" "$((BEFORE_RUNS + 1))"

start_other_payload mr-skip
printf 'multi-root-other\n' >>"$OTHER/tracked.txt"
BEFORE_RUNS=$(runs)
stop_other_payload mr-skip "${RUN_OK[@]}" >/dev/null
check "stop ignores payload workspace_roots[0] when PWD is a git worktree" "$(runs)" "$BEFORE_RUNS"

rm -f "$ARGS"
printf '{"file_path":"%s","cwd":"%s","workspace_roots":["%s"]}' "$REPO/src.ts" "$OTHER" "$OTHER" | record_args
check "after-edit uses PWD and ignores workspace_roots[0]" "$(logged_args)" "$REPO/src.ts"

mkdir -p "$OTHER/.cursor/hooks"
printf '%s\n' '#!/bin/sh' "echo ran >>'$MARKER'" >"$OTHER/.cursor/hooks/stop.sh"
chmod +x "$OTHER/.cursor/hooks/stop.sh"
rm -f "$STOP_SH"
start_other_payload mr-stop-default
printf 'multi-root-stop-default\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
payload_other mr-stop-default | (cd "$REPO" && "$GATE" stop) >/dev/null
check "stop does not use stop.sh from workspace_roots[0]" "$(runs)" "$BEFORE_RUNS"

NON_GIT=$(mktemp -d)
printf '{"session_id":"fb1","cwd":"%s"}' "$REPO" | (cd "$NON_GIT" && "$GATE" session-start)
printf 'fallback-cwd\n' >>"$REPO/tracked.txt"
BEFORE_RUNS=$(runs)
printf '{"session_id":"fb1","cwd":"%s"}' "$REPO" | (cd "$NON_GIT" && "$GATE" stop -- "${RUN_OK[@]}") >/dev/null
check "stop falls back to payload cwd when PWD is not a git worktree" "$(runs)" "$((BEFORE_RUNS + 1))"

rm -rf "$OUTSIDE" "$OTHER" "$NON_GIT"

unknown_rc=0
"$GATE" bogus </dev/null >/dev/null 2>&1 || unknown_rc=$?
check "unknown subcommand exits 2" "$unknown_rc" "2"

unknown_left=$(
  { "$GATE" bogus >/dev/null; cat; } 2>/dev/null <<'EOF'
KEEP
EOF
)
check "unknown subcommand does not read stdin" "$unknown_left" "KEEP"

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
