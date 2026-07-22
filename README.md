# agent-session-gate

Run your checks on an AI coding agent's stop hook — but only when the session actually changed something.

## 🤔 Why?

Running lint, typecheck and tests from a `Stop` hook is a great way to catch an agent's mistakes while the context is still fresh. The catch is that the hook fires on **every** turn, including the ones that changed nothing: answering a question, explaining a file, planning an approach.

If your working tree happens to be dirty from earlier work, a naive `git diff` guard fires on all of those turns too. A project with a 20 second check suite pays that 20 seconds per turn for the privilege of verifying code that nobody touched.

This gate records the state of the working tree when the session starts and compares it on every stop. Unchanged means the checks are skipped outright.

```
turn that edits code       →  checks run     (~20s)
turn that answers a question →  skipped        (~0.03s)
```

## 📦 Requirements

- `git`
- `jq`
- `shasum` or `sha1sum`

If any of them is missing the gate **fails safe**: it gives up on the comparison and runs your command, exactly as if no gate were installed.

## 🚀 Install

```bash
bun add -d github:tzwzx/agent-session-gate
# or
npm i -D github:tzwzx/agent-session-gate
```

## 🔌 Wiring

Two hooks: one records the baseline, one guards the checks.

### Claude Code — `.claude/settings.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bunx agent-session-gate session-start" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "bunx agent-session-gate stop -- bun run lint" }
        ]
      }
    ]
  }
}
```

### Cursor — `.cursor/hooks.json`

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "command": "bunx agent-session-gate session-start" }
    ],
    "stop": [
      { "command": "bunx agent-session-gate stop -- bun run lint" }
    ]
  }
}
```

### Codex CLI — `.codex/hooks.json`

Same shape as Claude Code.

### rulesync — `.rulesync/hooks.json`

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "command": "bunx agent-session-gate session-start" }
    ],
    "stop": [
      { "command": "bunx agent-session-gate stop -- bun run lint" }
    ]
  }
}
```

Anything after `--` is your command. It can be a script, a binary, or a whole pipeline runner.

## 🧠 How it works

`session-start` hashes the working tree — tracked changes plus the content of untracked files — and stores it under `$TMPDIR` keyed by session.

`stop` hashes it again. Identical means nothing happened this turn, so it exits without running anything. Otherwise it runs your command, records the new state, and on failure sends the agent back to work.

Because the hash covers untracked files, a brand new file the agent just wrote counts as a change. A plain `git diff` guard misses those.

## 🤖 Agent compatibility

The hook payload and the response format differ per agent, so both spellings are read and all response keys are emitted.

| | Session key | Sent back to work via |
|---|---|---|
| Claude Code | `session_id` | `decision` + `reason` |
| Codex CLI | `session_id` | `decision` + `reason` |
| Cursor | `conversation_id` | `followup_message` |

## 🛟 Fail-safe behaviour

The gate is built to over-run rather than under-run. It runs your command whenever it cannot prove nothing changed:

- No session key in the payload
- No baseline recorded (the hook was installed mid-session)
- `git`, `jq` or `shasum` unavailable
- Not inside a git repository

It also avoids two traps:

- **Compaction** does not reset the baseline. Resetting it would silently drop the edits made before the context was compacted.
- **An unfixable failure does not loop.** The state is recorded on failure too, so an agent that stops without editing anything is allowed through on the next stop instead of being sent back forever.

## ⚙️ Options

```
agent-session-gate session-start
agent-session-gate stop -- <command...>

  -h, --help       Show help
  -v, --version    Show the version
```

| Environment variable | Default |
|---|---|
| `AGENT_SESSION_GATE_STATE_DIR` | `$TMPDIR/agent-session-gate` |

## ⚠️ Caveats

- The first stop of a session runs the checks if no baseline was recorded, so make sure the `session-start` hook is wired up too.
- Changes made by someone else while the session is open count as changes. That is intentional: the gate is about "is the tree the same as I last saw it", not about attributing edits.
- State lives in `$TMPDIR` and is disposable. Losing it just means one extra run.

## 🧪 Tests

```bash
bun run test   # `bun test` would invoke Bun's own runner instead
# or
npm test
```

Runs against a disposable git repository under `$TMPDIR`. No existing repository is touched.

## 📄 License

MIT
