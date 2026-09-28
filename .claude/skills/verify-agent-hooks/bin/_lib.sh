#!/usr/bin/env bash
# Shared paths for verify-agent-hooks helpers. Source this file; do not run it.

set -euo pipefail

_VERIFY_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SKILL_DIR="$(cd "$_VERIFY_BIN_DIR/.." && pwd)"
REPO_ROOT="$(cd "$_VERIFY_BIN_DIR/../../../.." && pwd)"
CLI_SH="$REPO_ROOT/bin/agent-hooks.sh"
EVIDENCE_ROOT="$REPO_ROOT/test-results/verify-agent-hooks"
SCRATCH_PARENT="${TMPDIR:-/tmp}"

verify_require_run_id() {
  if [[ -z "${VERIFY_RUN_ID:-}" ]]; then
    echo "verify-agent-hooks: set VERIFY_RUN_ID before creating scratch or cleaning up (example: export VERIFY_RUN_ID=prove-stop)" >&2
    exit 2
  fi
}

verify_scratch_root() {
  verify_require_run_id
  printf '%s\n' "$SCRATCH_PARENT/agent-hooks-verify-${VERIFY_RUN_ID}"
}

verify_state_dir() {
  verify_require_run_id
  local dir
  dir="$(verify_scratch_root)/state"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

verify_evidence_dir() {
  local name="$1"
  mkdir -p "$EVIDENCE_ROOT/$name"
  printf '%s\n' "$EVIDENCE_ROOT/$name"
}

verify_realpath() {
  local target="$1"
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target"
}
