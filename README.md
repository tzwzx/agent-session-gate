# agent-hooks

Hooks toolkit for coding agents (Cursor, Claude Code, and anything with a compatible hook payload): a session-change gate for `stop`, plus an after-edit formatter that runs on the edited file only.

> Formerly `cursor-agent-hooks`. See [Migrating from cursor-agent-hooks](#-migrating-from-cursor-agent-hooks).

## 🤔 Why?

Running lint, typecheck and tests from a `Stop` hook is a great way to catch an agent's mistakes while the context is still fresh. The catch is that the hook fires on **every** turn, including the ones that changed nothing: answering a question, explaining a file, planning an approach.

If your working tree happens to be dirty from earlier work, a naive `git diff` guard fires on all of those turns too. A project with a 20 second check suite pays that 20 seconds per turn for the privilege of verifying code that nobody touched.

This package records the state of the working tree when the session starts and compares it on every stop. Unchanged means the checks are skipped outright.

```
turn that edits code         →  checks run     (~20s)
turn that answers a question →  skipped        (~0.03s)
```

A second problem is formatting on every edit. A hook that runs `oxfmt` (or Prettier, Biome, …) with no path argument formats the **whole project**, on every CPU core, for every `Edit`/`Write`. In a Cursor multi-root workspace every project's hook also runs, so one edit can start several full-tree formatters at once.

`after-edit` takes the edited `file_path` from the hook payload and appends it to the command you pass after `--`, and only if that file is inside the current project. The package does not pick a formatter; `oxfmt`, Prettier, Biome, and so on stay in the hook config.

```
one file edited  →  <your command> that-file.ts   (~0.1s)
other project    →  skipped
```

## 📦 Requirements

- `git` (session-start / stop)
- `jq`

If `git` or `jq` is missing, session-start / stop **fail safe**: they give up on the comparison and run your command, exactly as if no gate were installed. `after-edit` exits 0 without running the command if `jq` is missing.

## 🚀 Install

```bash
bun add -d github:tzwzx/agent-hooks
# or
npm i -D github:tzwzx/agent-hooks
```

> [!IMPORTANT]
> This package is invoked as a command from your agent's hook config and is never imported from code, so **dead-code analyzers report it as an unused dependency** and fail the build. Add it to the analyzer's ignore list:
>
> ```jsonc
> // fallow — .fallowrc.jsonc
> "ignoreDependencies": ["agent-hooks"]
> ```
> ```jsonc
> // knip — knip.json
> "ignoreDependencies": ["agent-hooks"]
> ```
>
> `depcheck` and similar tools need the same treatment.

## 🔌 Wiring

Call the binary under `node_modules/.bin`. That avoids `bunx` / `npx` resolution on every edit (hundreds of milliseconds each time).

### Cursor — `.cursor/hooks.json`

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "command": "./node_modules/.bin/agent-hooks session-start" }
    ],
    "afterFileEdit": [
      { "command": "./node_modules/.bin/agent-hooks after-edit -- ./node_modules/.bin/oxfmt --threads=1" }
    ],
    "stop": [
      { "command": "./node_modules/.bin/agent-hooks stop" }
    ]
  }
}
```

### Claude Code — `.claude/settings.json`

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "cd \"$CLAUDE_PROJECT_DIR\" && ./node_modules/.bin/agent-hooks session-start" }] }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|MultiEdit|Write",
        "hooks": [{ "type": "command", "command": "cd \"$CLAUDE_PROJECT_DIR\" && ./node_modules/.bin/agent-hooks after-edit -- ./node_modules/.bin/oxfmt --threads=1" }]
      }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "cd \"$CLAUDE_PROJECT_DIR\" && ./node_modules/.bin/agent-hooks stop" }] }
    ]
  }
}
```

Claude Code runs hooks in the session's current directory, which moves when the agent `cd`s into a subdirectory. The leading `cd "$CLAUDE_PROJECT_DIR"` pins the project root so the relative paths, the after-edit project filter and the default stop script all resolve against it.

### Common

`after-edit` has no default command. Pass the formatter after `--`. `stop` without `--` runs the first executable of `.cursor/hooks/stop.sh` and `.claude/hooks/stop.sh` when the working tree changed (no-op if neither exists or is executable).

```text
./node_modules/.bin/agent-hooks after-edit -- ./node_modules/.bin/prettier --write
./node_modules/.bin/agent-hooks stop -- bun run lint
```

Anything after `--` is your command. It can be a script, a binary, or a whole pipeline runner.

## 🧠 How it works

### session-start / stop

`session-start` hashes the working tree — tracked changes plus the paths and contents of untracked files — and stores it under `$TMPDIR` keyed by session.

`stop` hashes it again. Identical means nothing happened this turn, so it exits without running anything. Otherwise it runs the default stop script (or the command after `--`), records the new state, and on failure sends the agent back to work.

Because the hash covers untracked files, a brand new file the agent just wrote counts as a change. Renaming an untracked file counts too. A plain `git diff` guard misses those.

Both subcommands prefer the invocation `$PWD` when it is inside a Git worktree, so a multi-root payload's `workspace_roots[0]` cannot pull them into another project.

### after-edit

`after-edit` reads the edited path from `file_path` (Cursor `afterFileEdit`), `tool_input.file_path` (Claude Code `Edit` / `MultiEdit` / `Write`) or `tool_input.notebook_path` (Claude Code `NotebookEdit`). A relative path is resolved against `$PWD`. It ignores the event when the path is missing, not a file, or outside `$PWD`, and otherwise runs:

```text
<your command...> <file_path>
```

The inside-`$PWD` check compares physical paths, so a project reached through a symlink (for example `/var` vs `/private/var` on macOS) still matches.

stdout and stderr are discarded. A failing formatter still exits 0 so the agent edit is not blocked (fail-open). No command after `--` is also a no-op.

`after-edit` always uses the invocation `$PWD` as the project root. It does not follow payload `cwd` or `workspace_roots[0]`. Project hooks run from the project root, including in a multi-root workspace, so each root filters to its own files; an edit in project A does not format project B.

## 🤖 Agent compatibility

| | Cursor | Claude Code |
|---|---|---|
| Session key | `conversation_id` | `session_id` |
| Session start | `sessionStart` | `SessionStart` (`source: compact` keeps the baseline) |
| Edited path | `afterFileEdit` → `file_path` | `PostToolUse` → `tool_input.file_path` / `tool_input.notebook_path` |
| Failed check | reads `followup_message` | reads `decision: "block"` + `reason` |

`stop` prints `decision`, `reason` and `followup_message` together, so the same output works for both. Other agents work as long as their payload uses one of these keys and they read one of these outputs.

## 🛟 Fail-safe behavior

The stop gate is built to over-run rather than under-run. It runs your command whenever it cannot prove nothing changed:

- No session key in the payload
- No baseline recorded (the hook was installed mid-session)
- `git` or `jq` unavailable
- Not inside a git repository

It also avoids two traps:

- **Compaction** does not reset the baseline. Resetting it would silently drop the edits made before the context was compacted.
- **An unfixable failure does not loop.** The state is recorded on failure too, so an agent that stops without editing anything is allowed through on the next stop instead of being sent back forever.

`after-edit` is the opposite direction: it under-runs rather than format the wrong tree. Missing path, missing file, other project, missing `jq`, or a missing formatter command all exit 0 without running anything.

## ⚙️ Options

```
agent-hooks session-start
agent-hooks after-edit -- <command...>
agent-hooks stop [-- <command...>]

  -h, --help       Show this help
  -v, --version    Show the version
```

| Environment variable | Default |
|---|---|
| `AGENT_HOOKS_STATE_DIR` | `$TMPDIR/agent-hooks` |

`CURSOR_AGENT_HOOKS_STATE_DIR` is still read when `AGENT_HOOKS_STATE_DIR` is unset.

## ⚠️ Caveats

- The first stop of a session runs the checks if no baseline was recorded, so make sure the `session-start` hook is wired up too.
- Changes made by someone else while the session is open count as changes. That is intentional: the gate is about "is the tree the same as I last saw it", not about attributing edits.
- State lives in `$TMPDIR` and is disposable. Losing it just means one extra run.
- `after-edit` always uses `$PWD` as the project root. Cursor starts project hooks there; do not `cd` elsewhere before invoking it. In Claude Code, `cd "$CLAUDE_PROJECT_DIR"` first (see [Wiring](#-wiring)).
- `session-start` / `stop` also prefer `$PWD` when it is inside a Git worktree. Payload `cwd` / `workspace_roots[0]` is used only when the invocation `$PWD` is not in a Git worktree.

## 🔀 Migrating from cursor-agent-hooks

1. Replace the dependency: `bun remove cursor-agent-hooks && bun add -d github:tzwzx/agent-hooks` (or the `npm` equivalent).
2. In your hook config, replace `node_modules/.bin/cursor-agent-hooks` with `node_modules/.bin/agent-hooks`.
3. Rename `cursor-agent-hooks` to `agent-hooks` in your dead-code analyzer's `ignoreDependencies`.
4. Optionally rename `CURSOR_AGENT_HOOKS_STATE_DIR` to `AGENT_HOOKS_STATE_DIR`. The old name still works.

The default state directory moved from `$TMPDIR/cursor-agent-hooks` to `$TMPDIR/agent-hooks`, so the first stop of an already running session runs the checks once.

## 🧪 Tests

```bash
bun run test   # `bun test` would invoke Bun's own runner instead
# or
npm test
```

Runs against a disposable git repository under `$TMPDIR`. No existing repository is touched.

## 📄 License

MIT
