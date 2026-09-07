#!/usr/bin/env bash
# cursor-agent-hooks のテストです。
#
# $TMPDIR 配下に使い捨て Git リポジトリを作り、それに対して実行します。
# 既存リポジトリは触らず、終了時にすべて削除します。

set -uo pipefail

GATE="$(cd "$(dirname "$0")/.." && pwd)/bin/cursor-agent-hooks.sh"

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

# ---- フィクスチャ -----------------------------------------------------------

REPO=$(mktemp -d)
STATE=$(mktemp -d)
export CURSOR_AGENT_HOOKS_STATE_DIR="$STATE"

cleanup() { rm -rf "$REPO" "$STATE" "${OUTSIDE:-}" "${OTHER:-}" "${NON_GIT:-}"; }
trap cleanup EXIT

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
printf 'hello\n' >"$REPO/tracked.txt"
git -C "$REPO" add -A
git -C "$REPO" -c commit.gpgsign=false commit -qm init

# 実行したかどうかはマーカーファイルへの追記で判定します。
# 失敗系はファイルから出力し、ゲートがコマンドラインをエコーする分と区別します。
MARKER="$REPO/.ran"
MESSAGE="$REPO/.msg"
printf 'KABOOM: something is broken\n' >"$MESSAGE"
RUN_OK=(sh -c "echo ran >>'$MARKER'")
RUN_NG=(sh -c "echo ran >>'$MARKER'; cat '$MESSAGE'; exit 1")

runs() {
  if [ -f "$MARKER" ]; then wc -l <"$MARKER" | tr -d ' '; else printf ''; fi
}

payload() { printf '{"session_id":"%s","cwd":"%s"%s}' "$1" "$REPO" "${2:-}"; }

# Cursor と同様、プロジェクトルートを PWD にして呼び出します。
start() { payload "$1" "${2:-}" | (cd "$REPO" && "$GATE" session-start); }
stop() {
  local id=$1
  shift
  payload "$id" | (cd "$REPO" && "$GATE" stop -- "$@")
}
stop_default() {
  payload "$1" | (cd "$REPO" && "$GATE" stop)
}

printf '\ncursor-agent-hooks\n\n'

# ---- テスト ------------------------------------------------------------------

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

# ---- コンパクション ----------------------------------------------------------

start s2
BEFORE=$(cat "$STATE/s2")
printf 'more\n' >>"$REPO/tracked.txt"
start s2 ',"source":"compact"'
check "compaction keeps the original baseline" "$(cat "$STATE/s2")" "$BEFORE"

start s2 ',"source":"resume"'
check "resume refreshes the baseline" "$([ "$(cat "$STATE/s2")" != "$BEFORE" ] && echo yes || echo no)" "yes"

# ---- Cursor のペイロード -----------------------------------------------------

printf '{"conversation_id":"c1","workspace_roots":["%s"]}' "$REPO" | (cd "$REPO" && "$GATE" session-start)
check "cursor payload records a baseline" "$([ -s "$STATE/c1" ] && echo yes || echo no)" "yes"

BEFORE_RUNS=$(runs)
printf '{"conversation_id":"c1","status":"completed","loop_count":0,"workspace_roots":["%s"]}' "$REPO" |
  (cd "$REPO" && "$GATE" stop -- "${RUN_OK[@]}") >/dev/null
check "cursor payload skips an unchanged tree" "$(runs)" "$BEFORE_RUNS"

# ---- 失敗時の出力 ------------------------------------------------------------

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

# ---- 未追跡ファイルのリネーム ------------------------------------------------

printf 'payload\n' >"$REPO/untracked-src.txt"
start s4
BEFORE_RUNS=$(runs)
mv "$REPO/untracked-src.txt" "$REPO/untracked-dst.txt"
stop s4 "${RUN_OK[@]}" >/dev/null
check "stop runs after an untracked file is renamed" "$(runs)" "$((BEFORE_RUNS + 1))"

# ---- バイナリの再編集 --------------------------------------------------------

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

# ---- 読めない未追跡ファイル（フェイルセーフ） --------------------------------

start s6
ln -s /nonexistent "$REPO/broken-link"
BEFORE_RUNS=$(runs)
stop s6 "${RUN_OK[@]}" >/dev/null
check "stop runs when an untracked file is unreadable (fail safe)" "$(runs)" "$((BEFORE_RUNS + 1))"
BEFORE_RUNS=$(runs)
stop s6 "${RUN_OK[@]}" >/dev/null
check "unreadable untracked keeps failing safe" "$(runs)" "$((BEFORE_RUNS + 1))"
rm -f "$REPO/broken-link"

# ---- Git リポジトリの外 ------------------------------------------------------

OUTSIDE=$(mktemp -d)
printf '{"session_id":"out","cwd":"%s"}' "$OUTSIDE" | (cd "$OUTSIDE" && "$GATE" session-start)
BEFORE_RUNS=$(runs)
printf '{"session_id":"out","cwd":"%s"}' "$OUTSIDE" | (cd "$OUTSIDE" && "$GATE" stop -- "${RUN_OK[@]}") >/dev/null
check "stop runs outside a git repository (fail safe)" "$(runs)" "$((BEFORE_RUNS + 1))"

# ---- after-edit --------------------------------------------------------------

ARGS="$REPO/.args"
OXFMT="$REPO/node_modules/.bin/oxfmt"
OXFMT_LOG="$REPO/.oxfmt-args"
STOP_SH="$REPO/.cursor/hooks/stop.sh"
printf 'export const probe={a:1}\n' >"$REPO/src.ts"
record_args() {
  (cd "$REPO" && "$GATE" after-edit -- sh -c 'printf "%s\n" "$*" >>"$0"' "$ARGS")
}
logged_args() {
  if [ -f "$ARGS" ]; then cat "$ARGS"; else printf ''; fi
}
logged_oxfmt() {
  if [ -f "$OXFMT_LOG" ]; then cat "$OXFMT_LOG"; else printf ''; fi
}
install_oxfmt() {
  mkdir -p "$(dirname "$OXFMT")"
  printf '%s\n' '#!/bin/sh' 'echo NOISE' "printf '%s\\n' \"\$*\" >>'$OXFMT_LOG'" >"$OXFMT"
  chmod +x "$OXFMT"
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

# ---- after-edit / stop のデフォルト ------------------------------------------

rm -f "$ARGS" "$OXFMT" "$OXFMT_LOG"
printf '{"file_path":"%s"}' "$REPO/src.ts" | (cd "$REPO" && "$GATE" after-edit)
check "after-edit no-ops when default oxfmt is missing" "$(logged_args)$(logged_oxfmt)" ""

install_oxfmt
rm -f "$OXFMT_LOG"
OUT=$(printf '{"file_path":"%s"}' "$REPO/src.ts" | (cd "$REPO" && "$GATE" after-edit))
check "after-edit defaults to oxfmt --threads=1" "$(logged_oxfmt)" "--threads=1 $REPO/src.ts"
check "after-edit default discards formatter output" "$OUT" ""

rm -f "$ARGS" "$OXFMT_LOG"
printf '{"file_path":"%s"}' "$REPO/src.ts" | record_args
check "after-edit -- overrides the default oxfmt" "$(logged_args)" "$REPO/src.ts"
check "after-edit -- does not run default oxfmt" "$(logged_oxfmt)" ""

rm -f "$OXFMT_LOG"
printf '{"file_path":"%s"}' "$REPO/src.ts" | (cd "$REPO" && "$GATE" after-edit --)
check "after-edit -- with no command uses default oxfmt" "$(logged_oxfmt)" "--threads=1 $REPO/src.ts"

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

# ---- マルチルートのルート選択 ------------------------------------------------

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

rm -f "$OXFMT" "$OXFMT_LOG"
mkdir -p "$OTHER/node_modules/.bin"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$*\" >>'$OTHER/.oxfmt-args'" >"$OTHER/node_modules/.bin/oxfmt"
chmod +x "$OTHER/node_modules/.bin/oxfmt"
printf '{"file_path":"%s","cwd":"%s","workspace_roots":["%s"]}' "$REPO/src.ts" "$OTHER" "$OTHER" |
  (cd "$REPO" && "$GATE" after-edit)
check "after-edit does not use oxfmt from workspace_roots[0]" "$( [ -f "$OTHER/.oxfmt-args" ] && echo yes || echo no )" "no"

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

# ---- 未知のサブコマンド ------------------------------------------------------

unknown_rc=0
"$GATE" bogus </dev/null >/dev/null 2>&1 || unknown_rc=$?
check "unknown subcommand exits 2" "$unknown_rc" "2"

unknown_left=$(
  { "$GATE" bogus >/dev/null; cat; } 2>/dev/null <<'EOF'
KEEP
EOF
)
check "unknown subcommand does not read stdin" "$unknown_left" "KEEP"

# ---- 結果 --------------------------------------------------------------------

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
