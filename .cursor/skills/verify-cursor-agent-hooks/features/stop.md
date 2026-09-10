# Stop gate

Session-start records a working-tree hash. Stop runs the user's command only when that hash changed. Unchanged trees skip. Missing session, missing baseline, or a non-git cwd fail open (the command runs). A failing command still exits 0 from the hook and prints `decision: block` JSON.

## Sub-features

- `stop-record` writes a baseline file named after `session_id`.
- `stop-skip` does not run the command while the tree is unchanged.
- `stop-tracked` runs the command after `tracked.txt` changes.
- `stop-fail-open` runs the command when no baseline exists.
- `stop-block` emits JSON `decision=block` when the command exits non-zero, and the next unchanged stop does not loop.

## How to get to it (user POV)

- Cursor `sessionStart` runs `cursor-agent-hooks session-start` with a JSON payload on stdin.
- Cursor `stop` runs `cursor-agent-hooks stop` or `cursor-agent-hooks stop -- <command>`.
- A user can run the same commands in a terminal with a crafted payload.

## Driving it with verify-cli

Preconditions:

- `bin/doctor` has passed.
- `$REPO` is a fresh `bin/repo`. Reuse it across this feature's bullets in order.
- Payload: `{"session_id":"s1","cwd":"<abs-repo>"}` unless a bullet says otherwise.
- Marker command: `sh -c 'echo ran >>.ran'` (success) or `sh -c 'echo ran >>.ran; echo KABOOM; exit 1'` (failure).

- **Record.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name stop-record --payload "$PAYLOAD" -- session-start`. `exit.txt` is `0`. The file `$STATE_DIR/s1` exists and is non-empty (`STATE_DIR` is `stop-record/state-dir.txt`).
- **Skip.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name stop-skip --payload "$PAYLOAD" -- stop -- sh -c 'echo ran >>.ran'`. `exit.txt` is `0`. `$REPO/.ran` does not exist.
- **Tracked change.** Append a line to `$REPO/tracked.txt`. Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name stop-tracked --payload "$PAYLOAD" -- stop -- sh -c 'echo ran >>.ran'`. `exit.txt` is `0`. `$REPO/.ran` contains exactly one line `ran`.
- **Fail open.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name stop-fail-open --payload '{"session_id":"no-baseline","cwd":"'"$REPO"'"}' -- stop -- sh -c 'echo ran >>.ran'`. `exit.txt` is `0`. `$REPO/.ran` now has two lines.
- **Block.** Append another line to `$REPO/tracked.txt`. Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name stop-block --payload "$PAYLOAD" -- stop -- sh -c 'echo ran >>.ran; echo KABOOM; exit 1'`. `exit.txt` is `0`. `stdout.txt` is JSON with `.decision == "block"` and a `followup_message` that contains `KABOOM`. Run the failing command again with `--name stop-block-noloop`. `$REPO/.ran` gains no extra line from that second stop (the failure recorded a new baseline).
- **Proof.** Copy or quote `.ran` line counts into the evidence notes. Cleanup must not delete `test-results/verify-cursor-agent-hooks/`.

## Gotchas

- The hook process exits 0 even when it blocks the agent. Read stdout JSON, not `exit.txt`, for failure.
- A skip and a run both exit 0. The marker file is the only proof.
- Reusing a dirty `.ran` without counting lines will mis-attribute later bullets. Start this feature on a fresh `bin/repo`.
- Compaction (`source: compact`) must not refresh the baseline; that path is covered by the package tests and is not required for this feature's live proof.
- Never point `CURSOR_AGENT_HOOKS_STATE_DIR` at the default user directory.
