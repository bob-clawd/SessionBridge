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

**v1.8 — Implemented and tested.** ✅

- **Bash CLI** — bridge.sh with 7 lib modules
- **30 passing tests** covering all core features
- **MCP Server** — agent-native integration via Model Context Protocol
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

### MCP Prompts

- `session_recovery` — Full context recovery for resuming work
- `activity_report` — Generate session activity report
