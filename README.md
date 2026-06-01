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

**Concept phase** — nothing works yet. See `DESIGN.md` when it exists.
