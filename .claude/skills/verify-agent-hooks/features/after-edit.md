# After-edit

After-edit runs the user's formatter with the edited file path appended, only when that path is a real file whose physical directory is under the invocation `$PWD`. Missing path, missing file, other project, or no command exit 0 without running anything.

## Sub-features

- `edit-in` runs the command for a file under `$REPO`.
- `edit-out` skips a file outside `$REPO`.
- `edit-missing` skips when `file_path` is absent.
- `edit-nocommand` no-ops when `after-edit` has no command (with or without a trailing `--`).

## How to get to it (user POV)

- Cursor `afterFileEdit` or Claude Code `PostToolUse` runs `agent-hooks after-edit -- <formatter...>`.
- The payload includes `file_path` (Cursor), or `tool_input.file_path` / `tool_input.notebook_path` (Claude Code).

## Driving it with verify-cli

Preconditions:

- `bin/doctor` has passed.
- `$REPO` is a fresh `bin/repo`. Reuse it across this feature's bullets in order.
- `$OUTSIDE` is a file **not** under `$REPO` (write one under the scratch root, not in this package).
- Use `$REPO` as printed by `bin/repo` (it realpaths). `bin/cli` also realpaths `--cwd`. The CLI compares physical paths, so `/var` vs `/private/var` no longer matters, but keep the printed prefix for readable evidence.

The published CLI appends `file_path` as the last argument. Use this command after `--` so the appended path is recorded:

`sh -c 'echo "$1" >>.formatted' x`

`$1` is the edited path (the dummy `x` is `$0`).

- **In project.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name edit-in --payload "{\"file_path\":\"$REPO/tracked.txt\"}" -- after-edit -- sh -c 'echo "$1" >>.formatted' x`. `exit.txt` is `0`. `$REPO/.formatted` contains the absolute path `$REPO/tracked.txt`.
- **Outside.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name edit-out --payload "{\"file_path\":\"$OUTSIDE\"}" -- after-edit -- sh -c 'echo "$1" >>.formatted' x`. `exit.txt` is `0`. `$REPO/.formatted` is unchanged (still one line).
- **Missing path.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name edit-missing --payload '{}' -- after-edit -- sh -c 'echo "$1" >>.formatted' x`. `exit.txt` is `0`. `$REPO/.formatted` is unchanged.
- **No command.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name edit-nocommand --payload "{\"file_path\":\"$REPO/tracked.txt\"}" -- after-edit`. `exit.txt` is `0`. `$REPO/.formatted` is unchanged.
- **Proof.** Keep `payload.json` and a copy of `.formatted` if you snapshot it by hand. Cleanup must not delete evidence.

## Gotchas

- After-edit discards the formatter's stdout/stderr. Proof is the marker file, not `stdout.txt`.
- After-edit always exits 0, including when the formatter fails. A failing formatter is not a product error.
- `$PWD` is the project root, not `payload.cwd`. `bin/cli` already `cd`s to `--cwd`.
- In-project compares physical directories (`pwd -P`), so a symlinked `$PWD` still matches. A relative `file_path` is resolved against `$PWD`.
- `file_path` must be an existing file. A directory path is skipped.
- Do not pass this package's own files as `file_path` while `--cwd` is the disposable repo — that is the outside case.
