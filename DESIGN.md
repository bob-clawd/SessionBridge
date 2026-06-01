# SessionBridge — Design Document

## Overview

SessionBridge is a lightweight, file-based tool that persists agent session state. It lets agents save and restore context across session restarts using simple append-only JSONL files.

## Architecture

```
session-bridge/
├── bridge.sh          # Main CLI entrypoint
├── lib/
│   ├── log.sh         # Event logging
│   ├── context.sh     # Active context management
│   ├── bookmarks.sh   # Bookmark save/restore
│   ├── diff.sh        # Context diff against bookmarks
│   └── utils.sh       # Shared helpers
├── DESIGN.md          # This file
├── README.md          # Project intro
└── test/              # Tests
    ├── test_log.sh
    ├── test_context.sh
    └── test_bookmarks.sh
```

## Data Files (all under `.session-bridge/`)

| File | Format | Purpose |
|------|--------|---------|
| `events.jsonl` | JSONL | Append-only event log |
| `context.json` | JSON | Current session context (overwritten) |
| `bookmarks/` | dir | Named bookmark state snapshots |
| `bookmarks/<name>.json` | JSON | Saved context snapshot |

## Event Schema (`events.jsonl`)

Each line is a JSON object:

```json
{
  "t": "2026-06-01T03:30:00+02:00",
  "e": "task_start",
  "data": { "task": "Implement log module" },
  "s": "session-uuid"
}
```

Fields:
- `t` — ISO 8601 timestamp
- `e` — event type (string)
- `data` — arbitrary JSON payload
- `s` — session identifier (optional, defaults to auto-generated)

## Event Types

| Type | When | data example |
|------|------|-------------|
| `session_start` | Agent session begins | `{ "reason": "cron" }` |
| `session_end` | Agent session ends | `{ "reason": "complete" }` |
| `heartbeat` | Periodic liveness check | `{ "events": 42, "active_tasks": 2, "summary": "Working on X" }` |
| `task_start` | Starting a task | `{ "task": "Implement X" }` |
| `task_end` | Task completed | `{ "task": "Implement X", "result": "done" }` |
| `decision` | Architectural decision | `{ "what": "Use JSONL not SQLite", "why": "simplicity" }` |
| `file_touch` | File read/written/created | `{ "path": "src/main.py", "action": "created" }` |
| `context_update` | Context state change | `{ "key": "current_task", "value": "..." }` |
| `checkpoint` | Manual state checkpoint | `{ "note": "before large refactor" }` |
| `bookmark_save` | Bookmark created | `{ "name": "pre-refactor" }` |
| `bookmark_restore` | Bookmark restored | `{ "name": "pre-refactor" }` |

## Context Schema (`context.json`)

```json
{
  "session_id": "uuid",
  "started_at": "2026-06-01T03:30:00+02:00",
  "active_tasks": [],
  "recent_decisions": [],
  "recent_files": [],
  "tags": {},
  "summary": "Working on log module"
}
```

## CLI Usage

```bash
# Initialize a session (creates .session-bridge/)
./bridge.sh init

# Initialize with auto-GC (keeps last 500 events, removes older ones)
SB_GC_KEEP=500 ./bridge.sh init "My session"

# Log an event
./bridge.sh log task_start '{"task":"Implement X"}'
./bridge.sh log decision '{"what":"Use JSONL","why":"simple"}'
./bridge.sh log file_touch '{"path":"DESIGN.md","action":"created"}'

# Log an event with tags
./bridge.sh log task_start '{"task":"Integrate DB"}' --tag database feature
./bridge.sh log decision '{"what":"Use JSONL"}' --tag arch

# List all tags with counts
./bridge.sh tag list

# Show events for a specific tag
./bridge.sh tag show database
./bridge.sh tag show database 5   # last 5

# Show status (context + recent events)
./bridge.sh status

# Show comprehensive session summary
./bridge.sh summary

# Show recent events
./bridge.sh recent [n]

# Emit shell env vars for agent sourcing
source <(./bridge.sh env)

# Garbage-collect old events (keep last 500 by default)
./bridge.sh gc [keep]

# Save a bookmark
./bridge.sh bookmark save pre-refactor

# Restore a bookmark
./bridge.sh bookmark restore pre-refactor

# List bookmarks
./bridge.sh bookmark list

# Diff current context against a bookmark
./bridge.sh diff pre-refactor
```

```bash
# End a session with summary
./bridge.sh end
./bridge.sh end "timeout"          # custom reason

# Log a heartbeat event
./bridge.sh heartbeat              # logs event + prints status line

# Auto-checkpoint on long idle
./bridge.sh autockpt               # default: 15 min idle threshold
./bridge.sh autockpt 60            # 60 min idle threshold
```

## Agent Integration (`bridge.sh env`)

Source the env output to import session state as shell variables:

```bash
source <(./bridge.sh env)
# Now available:
#   $SB_SESSION_ID      — current session UUID
#   $SB_STARTED_AT      — ISO timestamp of session start
#   $SB_SUMMARY         — session summary string
#   $SB_ACTIVE_TASKS    — newline-separated active tasks
#   $SB_EVENT_COUNT     — total events in log
#   $SB_COMPLETED_COUNT — number of completed tasks
#   $SB_BOOKMARK_COUNT   — number of saved bookmarks
#   $SB_SESSION_DIR     — absolute path to .session-bridge/
```

## Garbage Collection (`bridge.sh gc`)

Remove old events from the log to keep it manageable:

```bash
./bridge.sh gc          # keep last 500 events
./bridge.sh gc 100      # keep last 100 events
```

Uses atomic temp-file rename, safe for concurrent use.

## Auto-GC on Init

Set the `SB_GC_KEEP` environment variable to automatically garbage-collect
old events before initializing a new session:

```bash
# Keep only last 500 events before init
SB_GC_KEEP=500 ./bridge.sh init "My session"

# Keep only last 100 events
SB_GC_KEEP=100 ./bridge.sh init "Tight session"
```

This is useful in cron-driven agent sessions where the event log grows
unbounded. Set and forget in your crontab or Heartbeat config.

## Session Summary (`bridge.sh summary`)

Produces a comprehensive, human-readable report of the current session
state, including:

- Session name and ID
- Event, task, decision, and file counts
- Active tasks (unfinished work)
- Recently completed tasks
- Saved bookmarks
- Recent decisions with rationale
- Last 5 events from the log
- Tips for next steps

Useful as an agent's entry point to quickly understand where it left off.

## Session End (`bridge.sh end`)

End the current session, log a `session_end` event, and print a full summary report:

```bash
./bridge.sh end                    # logs session_end with reason "completed"
./bridge.sh end "timeout"          # logs session_end with custom reason
./bridge.sh end "shutdown"         # logs session_end with reason "shutdown"
```

The `end` command:
1. Logs a `session_end` event with the specified reason
2. Prints the full summary report (same as `bridge.sh summary`)
3. Useful in cron jobs, shutdown hooks, or agent termination flows

## Heartbeat Logging (`bridge.sh heartbeat`)

Log a periodic heartbeat event with current session status. Designed for
cron or periodic monitoring integration:

```bash
./bridge.sh heartbeat
# Output: Heartbeat: 42 events, 2 active tasks — Working on feature X
```

The heartbeat event includes:
- `events` — total event count in the log
- `active_tasks` — number of currently active tasks
- `summary` — the session summary string

Useful for:
- Cron jobs that periodically log session liveness
- Heartbeat/file monitoring integrations
- Long-running session health checks

## Auto-Checkpoint (`bridge.sh autockpt`)

Automatically log a checkpoint if the session has been idle beyond a threshold.
Useful as a cron job or heartbeat integration to detect stale sessions.

```bash
./bridge.sh autockpt          # check if idle > 15 min, log if so
./bridge.sh autockpt 60       # check if idle > 60 min
```

Output if idle:
```
Auto-checkpoint: session idle for 124m — checkpoint logged.
```

Output if not idle:
```
Auto-checkpoint: not idle yet (30s idle, need 900s). 870s remaining.
```

The logged checkpoint event includes `auto: true` and the idle duration
in seconds, making it detectable by monitoring tools.

## Session Recovery Flow

1. Agent starts → checks for `.session-bridge/`
2. If found: `./bridge.sh summary` → full context restore
3. Read active tasks → understands what was pending
4. Read recent decisions → knows why previous choices were made
5. Continue work from where it left off
6. On exit: `./bridge.sh log session_end`

## Design Decisions

- **JSONL over SQLite**: Zero dependencies, human-readable, append-only is safe
- **File-based over MCP**: No server/port binding, works in any environment
- **Bash CLI**: Shell-agnostic, works on any POSIX system
- **Context is separate from log**: Context is a snapshot; log is history. Don't mix them.
- **jq --arg for safe injection**: All string interpolation goes through `jq --arg` to prevent JSON injection from arbitrary task/file names.

## MCP Server (`mcp-server.js`)

A Model Context Protocol server that wraps SessionBridge functionality for
agent-native integration. Built with the `@modelcontextprotocol/sdk`.

### Architecture

```
MCP Agent ←→ MCP Stdio/SSE ←→ mcp-server.js ←exec→ bridge.sh ←→ .session-bridge/
```

### Exposed Components

**Tools (17):** sb_init, sb_status, sb_summary, sb_log, sb_heartbeat,
sb_recent, sb_task_add, sb_task_done, sb_decision, sb_touch,
sb_bookmark_{save,restore,list,delete}, sb_tag_list, sb_gc

**Resources (3):** sessionbridge://context, sessionbridge://recent/10,
sessionbridge://recent/50

**Prompts (2):** session_recovery, activity_report

### Transport

- **stdio** (default) — for direct MCP agent integration
- **SSE** (`--port` flag) — for remote access on :3001

### Why MCP?

- Standard protocol — any MCP-aware agent can use SessionBridge
- No shell dependency — agents call typed JSON-RPC tools
- Resources provide structured data, Prompts provide resume context

## Completed Items

- ✅ `bridge.sh tags` — tag-based filtering of events (v1.5)
- ✅ `bridge.sh merge` — merge events from multiple sessions (v1.6)
- ✅ `bridge.sh end` — session end with automatic summary (v1.7)
- ✅ `bridge.sh heartbeat` — periodic liveness heartbeat (v1.7)
- ✅ `bridge.sh autockpt` — auto-checkpoint on long idle (v1.8)
- ✅ **MCP server** — agent-native integration (v1.9)

## Future Ideas
