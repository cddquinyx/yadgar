# Yadgar Claude Code Hooks

Yadgar ships hook scripts for every major Claude Code lifecycle event. The
easiest way to register them is:

```sh
yadgar install --client claude-code --hooks --scope global
```

(Migrated from the legacy `yadgar install-hooks --scope global` command,
which was hard-removed in v5.166.0 — Car 7 of the opencode port train.)

This copies scripts to `~/.claude/hooks/` and writes the settings below into
`~/.claude/settings.json`.

---

## Ready-to-paste settings.json snippets

If you prefer manual registration, copy the relevant blocks into your
`~/.claude/settings.json` under the `"hooks"` key.

Replace `/HOOKS_DIR/` with the directory where you copied the hook scripts
(default: `~/.claude/hooks/`).

### All hooks combined

```json
{
  "hooks": {
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/hook_runner.py' pre-compact-drain" }]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/hook_runner.py' session-start-context" }]
      },
      {
        "matcher": "compact",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/hook_runner.py' post-compact-rehydrate" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/hook_runner.py' post-tool-capture" }]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/hook_runner.py' prompt-recall" }]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/hook_runner.py' db-lockdown-check" }]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/yadgar-subagent-stop.py'" }]
      }
    ],
    "InstructionsLoaded": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/yadgar-instructions-loaded.py'" }]
      }
    ],
    "SubagentStart": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/yadgar-subagent-start.py'" }]
      }
    ],
    "FileChanged": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/yadgar-file-changed.py'" }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "python3 '/HOOKS_DIR/yadgar-stop-memory-checkpoint.py'" }]
      }
    ]
  }
}
```

---

## Hook reference

| Event | Script | Purpose |
|-------|--------|---------|
| `SessionStart` | `hook_runner.py session-start-context` | Inject hot memories + checkpoint on session open |
| `SessionStart` (compact) | `hook_runner.py post-compact-rehydrate` | Restore context after conversation compaction |
| `PreCompact` | `hook_runner.py pre-compact-drain` | Drain pending context before compaction |
| `UserPromptSubmit` | `hook_runner.py prompt-recall` | Auto-recall relevant memories on every prompt |
| `PostToolUse` | `hook_runner.py post-tool-capture` | Capture Write/Edit/Bash/Agent actions to action log |
| `PreToolUse` | `hook_runner.py db-lockdown-check` | Block direct `docker exec` into yadgar DB containers |
| `SubagentStop` | `yadgar-subagent-stop.py` | Extract `## Yadgar findings` bullets from agent reports |
| `InstructionsLoaded` | `yadgar-instructions-loaded.py` | Inject recalled context when CLAUDE.md loads (v5.3.2) |
| `SubagentStart` | `yadgar-subagent-start.py` | Pre-populate subagent context via recall at dispatch (v5.3.2) |
| `FileChanged` | `yadgar-file-changed.py` | Mirror team_inbox JSONL → action_log; memorize PLAN_*.md changes (v5.3.6) |
| `Stop` | `yadgar-stop-memory-checkpoint.py` | Persist session checkpoint on Claude Code exit |

---

## InstructionsLoaded hook (v5.3.2)

Fires when Claude Code loads a CLAUDE.md file. Throttled: only fires on
`load_reason ∈ {session_start, compact}`. Suppresses `nested_traversal`,
`path_glob_match`, and `include` to avoid spam on every nested include.

The hook calls `/hooks/instructions-loaded` on the daemon, which runs a
lightweight recall (~3 results) derived from the filename. The daemon
response text is printed to stdout — Claude Code injects it into the model
context.

**Payload fields used:**
- `file_path` — path of the loaded instructions file
- `load_reason` — controls throttle gate

---

## SubagentStart hook (v5.3.2)

Fires when Claude Code dispatches a subagent. Reads `agent_type`, `cwd`, and
`description` (or `prompt` as fallback) from the payload. POSTs to
`/hooks/subagent-start` on the daemon, which runs `recall(description)` and
returns relevant memories + anchors.

The injected context reaches the subagent AT DISPATCH TIME — the orchestrator
does not need to prepend context manually.

**Empirical note:** SubagentStart payload schema was not verified against a
live Claude Code event as of v5.3.2. The script handles missing fields with
safe defaults. Verify the actual field names (`description` vs `prompt`,
presence of `agent_id`) from a real Claude Code run and update if needed.

**Payload fields used:**
- `agent_type` — used for context header and daemon query param
- `cwd` — project directory
- `description` (fallback: `prompt`) — used as recall query

---

## FileChanged hook (v5.3.6)

Fires when a watched file changes on disk. Registered with empty matcher (fires
on all changes); the hook script filters to two use cases:

### M1 — Agent Teams JSONL inbox mirror

Watches `~/.claude/team_inbox/**/*.jsonl`. When a peer agent appends a message,
the hook reads new lines since last call (position-tracked in daemon memory) and
writes one `action_log` entry per JSONL line with `tool=team_message` and tags
`["team-message", "from-subagent"]`. Gives the curator full visibility into
inter-agent communication.

**Payload fields used:**
- `file_path` — path to changed JSONL file
- `file_action` — only `created` / `modified` are processed; `deleted` is skipped

### Q4 — PLAN_*.md auto-memorize

Watches `**/docs/PLAN_*.md`. When a plan file is modified, reads its content
and calls `memorize()` with tags `["_plan", "plan-file"]`. Hash-deduped:
identical content on repeat calls is skipped.

**Payload fields used:**
- `file_path` — path to changed markdown file
- `file_action` — only `created` / `modified` are processed

### Matcher note

`FileChanged` uses literal filename matching per Claude Code 2026 docs (no
regex or glob). The empty matcher `""` is used — script-side `re` patterns
handle the team_inbox and docs/PLAN_* filtering.

---

## Per-directory opt-out (v5.195.0)

Create an empty file named `.yadgar-disabled` at the root of a project, or in
any ancestor directory, and every memory/context hook exits silently for
sessions started anywhere under it: nothing is injected, nothing is captured,
no session-end sentinel is written, and the daemon is never contacted. The
check (`yadgar/core/hooks/_optout.py::hooks_disabled`) reads the hook
payload's `cwd` — falling back to `CLAUDE_PROJECT_DIR`, then the process cwd —
and walks every ancestor, so one marker covers a whole tree. A directory that
cannot be resolved is treated as NOT opted out: the marker is an explicit
choice, never a default.

Covered:

- the six `hook_runner.py` / `yadgar hook <event>` events (`post-tool-capture`,
  `session-start-context`, `post-compact-rehydrate`, `pre-compact-drain`,
  `prompt-recall`, `block-reflect`) — checked once in `dispatch`, before the
  handler runs;
- `yadgar-stop-memory-checkpoint.py` (allows the stop, no checkpoint prompt);
- `yadgar-session-end-capture.py`, `yadgar-file-changed.py`,
  `yadgar-instructions-loaded.py`, `yadgar-subagent-start.py` — including the
  inline fallbacks that run when the `yadgar` package is not importable.

Not covered, on purpose: `yadgar-pretooluse-router.py`. Its guards (db
lockdown, hook-config tamper, git-commit bypass, terraform family, push to
default branch) exist to stop the agent bypassing hard rules, and a file the
agent can create must not be able to switch them off — the same reasoning as
the router's own G5 guard. Disable individual guards through `disabled_guards`
in `~/.claude/yadgar-hook-exceptions.json` instead.

Why not Claude Code's `disableAllHooks`? The settings schema documents it as
"Disable all hooks and statusLine execution": it takes the status line and
every non-yadgar hook down with it. The marker only affects yadgar.

Why a file and not a runtime-config row (ADR-0163, as `code_graph.enabled`
is)? The hooks must decide before any daemon round trip, and the opt-out
exists precisely so the daemon never sees the tree.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `YADGAR_PORT` | `8765` | Daemon HTTP port |
| `YADGAR_MCP_AUTH_TOKEN` | (empty) | Bearer token for daemon auth |
