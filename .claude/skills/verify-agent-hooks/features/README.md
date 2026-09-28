# agent-hooks verification map

This directory is the maintained source for verifying the user-facing behavior of the agent-hooks CLI. Read the index before driving, then use the matching feature file as the recipe.

## Baseline preconditions

- `.claude/skills/verify-agent-hooks/bin/doctor` exits 0 (`git` and `jq` present).
- Set `VERIFY_RUN_ID`. Create each worktree with `bin/repo`.
- Drive only `bin/agent-hooks.sh` through `bin/cli`.
- Never pass `--cwd` equal to this package repo. `bin/cli` refuses that path (exit 2).
- Helpers isolate state under `$TMPDIR/agent-hooks-verify-$VERIFY_RUN_ID/state`.

## Driving conventions

- Start every recipe from a fresh `bin/repo` unless its preconditions say otherwise.
- Treat every command as literal. Keep `--help` vs `-h` and `--version` vs `-v` unchanged when a bullet names them.
- Feed JSON through `--payload`. Subcommands that read stdin need a payload even when the test is "missing session id".
- After a mutation, re-read the marker file or baseline in the disposable repo. Cleanup must not remove proof artifacts.

## Proof and skip reporting

- CLI proof is the command, stdout, stderr, exit code, and any marker the user-level command wrote.
- `stop` exiting 0 does not mean the command ran. The marker (or its absence) is the proof.
- Record the feature ID and entry point in `--name`.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features`
2. `How to get to it (user POV)`
3. `Driving it with verify-cli`
4. `Gotchas`

## Features

- [Help and version](./help.md) covers `--help`, `-h`, `--version`, `-v`, and an unknown command.
- [Stop gate](./stop.md) covers session-start, skip-on-unchanged, run-on-change, fail-open, and block JSON.
- [After-edit](./after-edit.md) covers in-project format, outside-project skip, missing path, and no command.
