# After-edit

After-edit runs the user's formatter with the edited file path appended, only when that path is a real file inside the invocation `$PWD`. Missing path, missing file, other project, or no command after `--` exit 0 without running anything.

## Sub-features

- `edit-in` runs the command for a file under `$REPO`.
- `edit-out` skips a file outside `$REPO`.
- `edit-missing` skips when `file_path` is absent.
- `edit-nocommand` no-ops when `--` has no command.

## How to get to it (user POV)

- Cursor `afterFileEdit` runs `cursor-agent-hooks after-edit -- <formatter...>`.
- The payload includes `file_path` (or `tool_input.file_path`).

## Driving it with verify-cli

Preconditions:

- `bin/doctor` has passed.
- `$REPO` is a fresh `bin/repo`.
- `$OUTSIDE` is a file **not** under `$REPO` (write one under the scratch root, not in this package).
- Marker command: `sh -c 'printf "%s\n" "$1" >>"$0/.formatted"' "$REPO"` — the helpers append the file path as the last argument, so a clearer command is `tee` into a marker: `sh -c 'echo "$0" >>'"$REPO"'/.formatted'`.

Use this command after `--` so the appended path is recorded:

`sh -c 'echo "$1" >>.formatted' x`

The gate runs `<command...> <file_path>`, so `$1` in that `sh -c` is the edited path (the dummy `x` is `$0`).

- **In project.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name edit-in --payload "{\"file_path\":\"$REPO/tracked.txt\"}" -- after-edit -- sh -c 'echo "$1" >>.formatted' x`. `exit.txt` is `0`. `$REPO/.formatted` contains the absolute path `$REPO/tracked.txt`.
- **Outside.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name edit-out --payload "{\"file_path\":\"$OUTSIDE\"}" -- after-edit -- sh -c 'echo "$1" >>.formatted' x`. `exit.txt` is `0`. `$REPO/.formatted` is unchanged (still one line).
- **Missing path.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name edit-missing --payload '{}' -- after-edit -- sh -c 'echo "$1" >>.formatted' x`. `exit.txt` is `0`. `$REPO/.formatted` is unchanged.
- **No command.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name edit-nocommand --payload "{\"file_path\":\"$REPO/tracked.txt\"}" -- after-edit`. `exit.txt` is `0`. `$REPO/.formatted` is unchanged.
- **Proof.** Keep `payload.json` and a copy of `.formatted` if you snapshot it by hand. Cleanup must not delete evidence.

## Gotchas

- After-edit discards the formatter's stdout/stderr. Proof is the marker file, not `stdout.txt`.
- After-edit always exits 0, including when the formatter fails. A failing formatter is not a product error.
- `$PWD` is the project root, not `payload.cwd`. `bin/cli` already `cd`s to `--cwd`.
- `file_path` must be an existing file. A directory path is skipped.
- Do not pass this package's own files as `file_path` while `--cwd` is the disposable repo — that is the outside case.
