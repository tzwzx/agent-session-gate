#!/usr/bin/env bash
# Test suite for agent-session-gate.
#
# Runs against a disposable git repository created under $TMPDIR. No existing
# repository is touched, and everything is removed on exit.

set -uo pipefail

GATE="$(cd "$(dirname "$0")/.." && pwd)/bin/agent-session-gate.sh"

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

# ---- fixture -----------------------------------------------------------------

REPO=$(mktemp -d)
STATE=$(mktemp -d)
export AGENT_SESSION_GATE_STATE_DIR="$STATE"

cleanup() { rm -rf "$REPO" "$STATE"; }
trap cleanup EXIT

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
printf 'hello\n' >"$REPO/tracked.txt"
git -C "$REPO" add -A
git -C "$REPO" -c commit.gpgsign=false commit -qm init

# A command that appends to a marker file so tests can tell whether it ran.
# The failing variant prints from a file so its output stays distinguishable
# from the command line itself, which the gate also echoes back.
MARKER="$REPO/.ran"
MESSAGE="$REPO/.msg"
printf 'KABOOM: something is broken\n' >"$MESSAGE"
RUN_OK=(sh -c "echo ran >>'$MARKER'")
RUN_NG=(sh -c "echo ran >>'$MARKER'; cat '$MESSAGE'; exit 1")

runs() {
  if [ -f "$MARKER" ]; then wc -l <"$MARKER" | tr -d ' '; else printf ''; fi
}

payload() { printf '{"session_id":"%s","cwd":"%s"%s}' "$1" "$REPO" "${2:-}"; }

start() { payload "$1" "${2:-}" | "$GATE" session-start; }
stop() {
  local id=$1
  shift
  payload "$id" | "$GATE" stop -- "$@"
}

printf '\nagent-session-gate\n\n'

# ---- tests -------------------------------------------------------------------

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

printf '{"cwd":"%s"}' "$REPO" | "$GATE" stop -- "${RUN_OK[@]}" >/dev/null
check "stop runs without a session id (fail safe)" "$(runs)" "4"

# ---- compaction --------------------------------------------------------------

start s2
BEFORE=$(cat "$STATE/s2")
printf 'more\n' >>"$REPO/tracked.txt"
start s2 ',"source":"compact"'
check "compaction keeps the original baseline" "$(cat "$STATE/s2")" "$BEFORE"

start s2 ',"source":"resume"'
check "resume refreshes the baseline" "$([ "$(cat "$STATE/s2")" != "$BEFORE" ] && echo yes || echo no)" "yes"

# ---- cursor payload ----------------------------------------------------------

printf '{"conversation_id":"c1","workspace_roots":["%s"]}' "$REPO" | "$GATE" session-start
check "cursor payload records a baseline" "$([ -s "$STATE/c1" ] && echo yes || echo no)" "yes"

BEFORE_RUNS=$(runs)
printf '{"conversation_id":"c1","status":"completed","loop_count":0,"workspace_roots":["%s"]}' "$REPO" |
  "$GATE" stop -- "${RUN_OK[@]}" >/dev/null
check "cursor payload skips an unchanged tree" "$(runs)" "$BEFORE_RUNS"

# ---- failure output ----------------------------------------------------------

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

# ---- untracked rename --------------------------------------------------------

printf 'payload\n' >"$REPO/untracked-src.txt"
start s4
BEFORE_RUNS=$(runs)
mv "$REPO/untracked-src.txt" "$REPO/untracked-dst.txt"
stop s4 "${RUN_OK[@]}" >/dev/null
check "stop runs after an untracked file is renamed" "$(runs)" "$((BEFORE_RUNS + 1))"

# ---- binary re-edit ----------------------------------------------------------

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

# ---- unreadable untracked (fail safe) ----------------------------------------

start s6
ln -s /nonexistent "$REPO/broken-link"
BEFORE_RUNS=$(runs)
stop s6 "${RUN_OK[@]}" >/dev/null
check "stop runs when an untracked file is unreadable (fail safe)" "$(runs)" "$((BEFORE_RUNS + 1))"
BEFORE_RUNS=$(runs)
stop s6 "${RUN_OK[@]}" >/dev/null
check "unreadable untracked keeps failing safe" "$(runs)" "$((BEFORE_RUNS + 1))"
rm -f "$REPO/broken-link"

# ---- outside a git repository ------------------------------------------------

OUTSIDE=$(mktemp -d)
printf '{"session_id":"out","cwd":"%s"}' "$OUTSIDE" | "$GATE" session-start
BEFORE_RUNS=$(runs)
printf '{"session_id":"out","cwd":"%s"}' "$OUTSIDE" | "$GATE" stop -- "${RUN_OK[@]}" >/dev/null
check "stop runs outside a git repository (fail safe)" "$(runs)" "$((BEFORE_RUNS + 1))"
rm -rf "$OUTSIDE"

# ---- unknown subcommand ------------------------------------------------------

unknown_rc=0
"$GATE" bogus </dev/null >/dev/null 2>&1 || unknown_rc=$?
check "unknown subcommand exits 2" "$unknown_rc" "2"

unknown_left=$(
  { "$GATE" bogus >/dev/null; cat; } 2>/dev/null <<'EOF'
KEEP
EOF
)
check "unknown subcommand does not read stdin" "$unknown_left" "KEEP"

# ---- summary -----------------------------------------------------------------

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
