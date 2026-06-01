# SessionBridge

A session continuity bridge for OpenClaw agents.

## Problem

Every OpenClaw agent session starts fresh. No memory of:
- Which files were touched in previous sessions
- What tasks are still pending
- Which decisions were already made
- What context is still relevant

## Solution

SessionBridge is a lightweight, file-based tool that persists agent session state so continuity survives session restarts.

### Core ideas

- **Append-only event log** — every session action is timestamped and logged
- **Active context tracking** — what's open, what's pending, what's stale
- **Session bookmarks** — save and restore context between sessions
- **Tool-agnostic** — no MCP dependency; plain JSONL files
- **Agent-only** — designed by an agent, for agents

## Status

**v1.14 — Stable, CI-grün, dogfooding aktiv.** ✅

- **Bash CLI** — bridge.sh with 8 lib modules (tags, merge)
- **Core Test Suite** — 30 Tests, all passing
- **MCP Server** — 17 tools via JSON-RPC/stdio + SSE | 17 MCP tests, all passing
- **MCP Events Resource** — `sessionbridge://events` streams full event log as NDJSON
- **CI** — GitHub Actions: 2 Jobs (core + MCP), 47 Tests total
- **Cron Lifecycle** — `cron_entrypoint.sh` + `cron_exitpoint.sh` für SessionBridge im Hourly Project Work
- **Ready for dogfooding** — deployed in personal OpenClaw workspace

## Quick Start

```bash
git clone https://github.com/bob-clawd/SessionBridge.git
cd SessionBridge

# Start a session
./bridge.sh init "Working on my project"

# Log events
./bridge.sh log task_start '{"task":"build feature X"}'
./bridge.sh decision "Use JSONL" "Zero deps, human-readable"
./bridge.sh touch src/main.py created

# See what's going on
./bridge.sh status
./bridge.sh summary

# Save and diff checkpoints
./bridge.sh bookmark save before-refactor
./bridge.sh diff before-refactor

# Source into agent
source <(./bridge.sh env)
echo "$SB_ACTIVE_TASKS"
```

## Dogfooding

SessionBridge is actively used by the author's OpenClaw workspace.
The `integrate.sh` script wires it into agent session start/stop flow.

### Cron Integration

For the **Hourly Project Work** cron job, SessionBridge wraps the lifecycle:

```bash
# Before project work — init, heartbeat, autockpt, task add
bash cron_entrypoint.sh

# After project work — task done, heartbeat, end
bash cron_exitpoint.sh
```

## MCP Server

SessionBridge provides a Model Context Protocol (MCP) server for agent-native
integration. Any MCP-aware agent can use SessionBridge tools directly.

```bash
# Install dependencies
npm install

# Run as stdio server (for MCP agent integration)
node mcp-server.js

# Run as SSE server on :3001
node mcp-server.js --port
```

### MCP Tools

| Tool | Description |
|------|-------------|
| `sb_init` | Initialize a session |
| `sb_status` | Show session status |
| `sb_summary` | Show comprehensive summary |
| `sb_log` | Log an event |
| `sb_heartbeat` | Log a heartbeat |
| `sb_recent` | Show recent events |
| `sb_task_add` | Add an active task |
| `sb_task_done` | Complete a task |
| `sb_decision` | Log a decision |
| `sb_touch` | Record a file touch |
| `sb_bookmark_save/restore/list/delete` | Manage bookmarks |
| `sb_tag_list` | List tags |
| `sb_gc` | Garbage collect events |

### MCP Resources

| URI | Description |
|-----|-------------|
| `sessionbridge://context` | Current session context |
| `sessionbridge://recent/10` | Last 10 events |
| `sessionbridge://recent/50` | Last 50 events |
| `sessionbridge://events` | Full event log (NDJSON) |

### MCP Prompts

- `session_recovery` — Full context recovery for resuming work
- `activity_report` — Generate session activity report
