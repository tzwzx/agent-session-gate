#!/usr/bin/env bash
# AI コーディングエージェントのセッション中に作業ツリーが変わったときだけ
# 検証コマンドを実行する。
#
#   agent-session-gate session-start          セッションの基準状態を記録する
#   agent-session-gate stop -- <command...>   ツリーが変わったときだけコマンドを実行する
#
# エージェントの sessionStart と stop フックに接続する。何も変更しないターン
#（質問への回答やコードの読解）では、stop フックは検査一式を再実行せず即座に終了する。
#
# Cursor のフックでは conversation_id と followup_message を使う。
# session_id と decision / reason も後方互換のために受け付け、出力する。
#
# 注意: `set -e` は意図的に使わない。検証コマンドの終了ステータスを取得し、
# コマンドの失敗と同時にこのスクリプトまで終了しないようにする必要がある。
#
# 注意: macOS に付属する bash 3.2 と互換性を保つ。

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

# 作業ツリーの状態をハッシュ化する。追跡対象の変更と未追跡ファイルの内容を含める。
# 状態を特定できないときは何も出力せず、呼び出し側は空の値を「不明」として
# コマンド実行へフォールバックする。
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

# $INPUT に保持したフックのペイロードから jq 式を読み取る。
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

# Cursor の stop フックは conversation_id を渡すが、既存の session_id も受け付ける。
SESSION_ID=$(payload '.session_id // .conversation_id // empty')

# フックプロセスの作業ディレクトリはエージェント次第なので、git を操作する前に
# ペイロードが示すワークスペースへ移動する。
HOOK_CWD=$(payload '.cwd // (.workspace_roots // [])[0] // empty')
if [ -n "$HOOK_CWD" ]; then
  cd "$HOOK_CWD" 2>/dev/null || true
fi

case "${1:-}" in
  session-start)
    # コンパクション後も同じセッションが続くため、基準状態を維持する。
    # ここで上書きすると、コンパクション前の編集が静かに失われる。
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

    # フェイルセーフ: セッションキー、現在の状態、基準状態のいずれかが無い場合は
    # 比較を諦め、検証を実行する。
    if [ -n "$SESSION_ID" ] && [ -n "$CURRENT" ] && [ -f "$STATE" ] &&
      [ "$(cat "$STATE")" = "$CURRENT" ]; then
      exit 0
    fi

    OUTPUT=$(NO_COLOR=1 "$@" 2>&1)
    STATUS=$?

    # 検証コマンドは自動修正でファイルを書き換えることがあるため、実行後の状態を
    # 新しい基準にする。失敗時も記録することで、直せない問題でエージェントが
    # ループし続けるのを防ぐ。次の stop では変更なしと判断されて通過できる。
    if [ -n "$SESSION_ID" ]; then
      mkdir -p "$STATE_DIR"
      worktree_hash >"$STATE"
    fi

    # 利用側が読むキーに差があるため、後方互換のキーも含めて出力する。
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
