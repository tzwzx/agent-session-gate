---
name: verify-agent-hooks
description: "Drive the agent-hooks CLI the way a user does — session-start/stop gate and after-edit formatter against a disposable git repo. Use when proving skip/run behavior, fail-open, or after-edit path filtering."
---

# Verify agent-hooks

agent-hooks is a short-lived bash CLI. There is no server, TUI, or browser. The published user path is `bin/agent-hooks.sh` (`package.json` `"bin": { "agent-hooks": "./bin/agent-hooks.sh" }`).

Users invoke it from an agent's hook config (Cursor, Claude Code, ...) with a JSON payload on stdin:

- `session-start` records a working-tree baseline under `AGENT_HOOKS_STATE_DIR` (default `$TMPDIR/agent-hooks`).
- `stop` re-hashes the tree and runs a command only when it changed (default: first executable of `.cursor/hooks/stop.sh` and `.claude/hooks/stop.sh`).
- `after-edit -- <command...>` appends `file_path` from the payload and runs the command only when that file is inside `$PWD`.

Do not treat `./test/run.sh` as a substitute for driving `bin/agent-hooks.sh` through this harness. The test script is a good recipe source; the proof is a transcript this run captured.

Read `features/README.md` before driving. Drive every entry point the chosen feature file lists.

## Launch

From the repo root:

```bash
export VERIFY_RUN_ID=verify-$(date +%Y%m%dT%H%M%S)
export PATH_VERIFY=".claude/skills/verify-agent-hooks/bin"
```

No install or build. Ready when `bin/doctor` exits 0. Each drive is a new process. Create a disposable git repo with `bin/repo` for every recipe that hashes a worktree.

Helpers set `AGENT_HOOKS_STATE_DIR` to `$TMPDIR/agent-hooks-verify-$VERIFY_RUN_ID/state`. Never use the default `$TMPDIR/agent-hooks` (that directory may hold a real agent session).

## Doctor

```bash
.claude/skills/verify-agent-hooks/bin/doctor
```

Read-only. Checks `git` and `jq` on PATH, package name `agent-hooks`, executable `bin/agent-hooks.sh`, `--help` names the three subcommands, and `--version` matches `package.json`.

Missing `jq` fails doctor. The product fail-opens without jq; that is a mapped edge, but this harness requires jq so payloads parse the same way a working install does.

## Drive

Harness: `bin/cli`. It `cd`s to `--cwd`, sets the isolated state dir, feeds `--payload` on stdin, and writes a transcript.

```bash
REPO="$("$PATH_VERIFY/repo")"
"$PATH_VERIFY/cli" --cwd "$REPO" --name <stem> --payload '{"session_id":"s1","cwd":"'"$REPO"'"}' -- session-start
"$PATH_VERIFY/cli" --cwd "$REPO" --name <stem> --payload '{"session_id":"s1","cwd":"'"$REPO"'"}' -- stop -- sh -c 'echo ran >>.ran'
```

| User action | Args | Observable |
| --- | --- | --- |
| Help | `--help` or `-h` | usage on stdout; exit `0` |
| Version | `--version` or `-v` | stdout is `package.json` version; exit `0` |
| Unknown command | `wat` | usage on stderr; exit `2` |
| Record baseline | `session-start` + payload | exit `0`; `$STATE_DIR/<session_id>` is non-empty |
| Unchanged stop | `stop -- <cmd>` | `<cmd>` does not run; exit `0` |
| Changed stop | edit a file, then `stop -- <cmd>` | `<cmd>` runs; exit `0` |
| Failed stop | `stop -- <failing cmd>` | stdout is JSON with `decision: block`; process exit still `0` |
| After-edit in project | `after-edit -- <cmd>` + in-project `file_path` | `<cmd>` runs with that path appended |
| After-edit outside | `file_path` outside `$PWD` | `<cmd>` does not run; exit `0` |

`bin/cli` **refuses** (exit 2) when `--cwd` is this package repo.

## Evidence

Proof root: `test-results/verify-agent-hooks/` (survives cleanup). Each drive writes `argv.txt`, `cwd.txt`, `state-dir.txt`, `payload.json`, `stdout.txt`, `stderr.txt`, `exit.txt`.

Proof standards:

- Drive `bin/agent-hooks.sh`, not `test/run.sh`.
- Capture the command and the result. For the gate, the result is whether a marker file in the disposable repo was written, not only the process exit (stop almost always exits 0).
- For a mutation, re-read the marker or the baseline file. A silent exit 0 is not proof of a skip.
- For `decision: block`, parse stdout JSON. Do not grep the raw command output only.
- Never write baselines into the default `$TMPDIR/agent-hooks`.

Record the feature id and entry point in `--name`.

## Cleanup

```bash
.claude/skills/verify-agent-hooks/bin/cleanup
```

Removes `$TMPDIR/agent-hooks-verify-$VERIFY_RUN_ID` (repos + isolated state). Never deletes `test-results/verify-agent-hooks/`. Never kills by process name. Processes are short-lived.

If a drive fails, cleanup that `VERIFY_RUN_ID` before retrying so leftover `.ran` markers do not leak. Confirm the failed attempt's evidence directory is still present.

## Helpers

All bash helpers are executable. They resolve the repo root from their own location.

```bash
.claude/skills/verify-agent-hooks/bin/doctor
VERIFY_RUN_ID=<id> .claude/skills/verify-agent-hooks/bin/repo
VERIFY_RUN_ID=<id> .claude/skills/verify-agent-hooks/bin/cli --cwd DIR --name STEM [--payload JSON] -- <args>
VERIFY_RUN_ID=<id> .claude/skills/verify-agent-hooks/bin/cleanup
```

- `doctor` — read-only readiness.
- `repo` — prints a new git repo with one committed `tracked.txt`.
- `cli` — runs the published script; always exits 0 itself; read `exit.txt`.
- `cleanup` — scratch only; leaves evidence.

`bin/_lib.sh` is sourced. Do not call it directly.

## Isolate

Two runs may proceed in parallel with different `VERIFY_RUN_ID` values. They must not share a disposable repo or state dir.

Do not drive:

- `session-start` / `stop` with `--cwd` equal to this package (refused).
- any hook against the default `AGENT_HOOKS_STATE_DIR`.
- a second stop in a repo that still has a leftover `.ran` unless the feature says to reuse it.

If you cannot get a disposable git repo, refuse rather than using this checkout.
