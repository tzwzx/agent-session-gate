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

Requirements: git and jq.
When either of them is missing the gate fails safe: the command always runs.
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
  session-start | stop) ;;
  *)
    usage >&2
    exit 2
    ;;
esac

cmd=$1
shift

# Cursor の stop フックは conversation_id を渡しますが、既存の session_id も
# 受け付けます。jq が無い・JSON が壊れている場合は変数が空のままになり、
# フェイルセーフで検証コマンドを実行します。
SESSION_ID= HOOK_CWD= SOURCE=
eval "$(jq -r '@sh "SESSION_ID=\(.session_id // .conversation_id // "") HOOK_CWD=\(.cwd // (.workspace_roots // [])[0] // "") SOURCE=\(.source // "")"' 2>/dev/null)"

# フックプロセスの作業ディレクトリはエージェント次第なので、git を操作する前に
# ペイロードが示すワークスペースへ移動します。
if [ -n "$HOOK_CWD" ]; then
  cd "$HOOK_CWD" 2>/dev/null || true
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
[ $# -eq 0 ] && exit 0

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
