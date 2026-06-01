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

**v1.3 — Implemented and tested.** ✅

- **778 lines** of Bash, split across 6 modules (1 CLI + 5 lib)
- **17 passing tests** covering all core features
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
