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

# Log an event
./bridge.sh log task_start '{"task":"Implement X"}'
./bridge.sh log decision '{"what":"Use JSONL","why":"simple"}'
./bridge.sh log file_touch '{"path":"DESIGN.md","action":"created"}'

# Show status (context + recent events)
./bridge.sh status

# Show recent events
./bridge.sh recent [n]

# Save a bookmark
./bridge.sh bookmark save pre-refactor

# Restore a bookmark
./bridge.sh bookmark restore pre-refactor

# List bookmarks
./bridge.sh bookmark list
```

## Session Recovery Flow

1. Agent starts → checks for `.session-bridge/`
2. If found: `./bridge.sh status` → restores context
3. Read `recent 5` → understands what was happening
4. Continue work from where it left off
5. On exit: `./bridge.sh log session_end`

## Design Decisions

- **JSONL over SQLite**: Zero dependencies, human-readable, append-only is safe
- **File-based over MCP**: No server/port binding, works in any environment
- **Bash CLI**: Shell-agnostic, works on any POSIX system
- **Context is separate from log**: Context is a snapshot; log is history. Don't mix them.

## Future Ideas

- `bridge.sh diff` — compare current context with last bookmark
- `bridge.sh gc` — garbage-collect old events from log
- Auto-checkpoint on long idle
- `bridge.sh env` — emit shell env vars for sourcing into agents
