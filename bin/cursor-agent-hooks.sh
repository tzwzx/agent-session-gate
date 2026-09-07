#!/usr/bin/env bash
# Cursor のフック向けツールキットです。
#
#   cursor-agent-hooks session-start              セッションの基準状態を記録する
#   cursor-agent-hooks after-edit -- <command...> 編集された 1 ファイルだけを整形する
#   cursor-agent-hooks stop                       ツリーが変わったときだけ stop.sh を実行する
#   cursor-agent-hooks stop -- <command...>       ツリーが変わったときだけコマンドを実行する
#
# sessionStart / afterFileEdit / stop フックに接続します。
# 何も変更しないターン（質問への回答やコードの読解）では、stop フックは
# 検査一式を再実行せず即座に終了します。after-edit は編集されたファイルが
# 自プロジェクト内のときだけ、コマンドの末尾にそのパスを付けて実行します。
# フォーマッタ名はパッケージに持たず、常に -- 以降で渡します。
# コマンド未指定の stop は .cursor/hooks/stop.sh を使います。
#
# Cursor のフックでは conversation_id と followup_message を使う。
# session_id と decision / reason も後方互換のために受け付け、出力する。
#
# 注意: `set -e` は意図的に使わない。検証コマンドの終了ステータスを取得し、
# コマンドの失敗と同時にこのスクリプトまで終了しないようにする必要がある。
#
# 注意: macOS に付属する bash 3.2 と互換性を保つ。

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

# 作業ツリーの状態をハッシュ化します。追跡対象の変更と、未追跡ファイルの
# パス・内容を含めます。状態を特定できないときは何も出力せず、呼び出し側は
# 空の値を「不明」としてコマンド実行へフォールバックします。
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

# セッションキーがあるときだけ、現在の作業ツリーを基準状態として保存します。
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

# after-edit は常に呼び出し時の PWD をプロジェクトルートとする。
# マルチルートで workspace_roots[0] が別プロジェクトでも追従しない。
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

# Cursor の stop フックは conversation_id を渡しますが、既存の session_id も
# 受け付けます。jq が無い・JSON が壊れている場合は変数が空のままになり、
# フェイルセーフで検証コマンドを実行します。
SESSION_ID= HOOK_CWD= SOURCE=
eval "$(jq -r '@sh "SESSION_ID=\(.session_id // .conversation_id // "") HOOK_CWD=\(.cwd // (.workspace_roots // [])[0] // "") SOURCE=\(.source // "")"' 2>/dev/null)"

# Cursor はプロジェクトフックをそのルートで起動する。呼び出し時の PWD が
# Git 作業ツリー内ならそれを使い、マルチルートの workspace_roots[0] には
# 引っ張られない。PWD が作業ツリー外のときだけペイロードの cwd に戻る。
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$HOOK_CWD" ]; then
    cd "$HOOK_CWD" 2>/dev/null || true
  fi
fi

if [ "$cmd" = session-start ]; then
  # コンパクション後も同じセッションが続くため、基準状態を維持します。
  # ここで上書きすると、コンパクション前の編集が静かに失われます。
  if [ "$SOURCE" != compact ]; then
    record_baseline
  fi
  exit 0
fi

[ "${1:-}" = "--" ] && shift
# コマンド未指定ならプロジェクトの stop.sh。無い・実行不可なら何もしない。
if [ $# -eq 0 ]; then
  if [ ! -x ".cursor/hooks/stop.sh" ]; then
    exit 0
  fi
  set -- .cursor/hooks/stop.sh
fi

STATE="$STATE_DIR/$SESSION_ID"
CURRENT=$(worktree_hash)

# フェイルセーフ: セッションキー、現在の状態、基準状態のいずれかが無い場合は
# 比較を諦め、検証を実行します。
if [ -n "$SESSION_ID" ] && [ -n "$CURRENT" ] && [ -f "$STATE" ] &&
  [ "$(<"$STATE")" = "$CURRENT" ]; then
  exit 0
fi

OUTPUT=$(NO_COLOR=1 "$@" 2>&1)
STATUS=$?

# 検証コマンドは自動修正でファイルを書き換えることがあるため、実行後の状態を
# 新しい基準にします。失敗時も記録することで、直せない問題でエージェントが
# ループし続けるのを防ぎます。次の stop では変更なしと判断されて通過できます。
record_baseline

# 利用側が読むキーに差があるため、後方互換のキーも含めて出力します。
if [ $STATUS -ne 0 ]; then
  printf '%s failed. Fix the following.\n\n%s' "$*" "$OUTPUT" |
    jq -Rs '{decision: "block", reason: ., followup_message: .}' 2>/dev/null
fi

exit 0
