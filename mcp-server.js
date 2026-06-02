#!/usr/bin/env node
/**
 * SessionBridge MCP Server
 *
 * Exposes SessionBridge functionality as Model Context Protocol tools,
 * allowing MCP-aware agents to interact with SessionBridge directly.
 *
 * Usage:
 *   node mcp-server.js          # stdio transport (default, for MCP agent)
 *   node mcp-server.js --port   # SSE transport on :3001
 *
 * Bridge path override: SB_BRIDGE=/path/to/bridge.sh
 */

const { Server } = require('@modelcontextprotocol/sdk/server/index.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const { SSEServerTransport } = require('@modelcontextprotocol/sdk/server/sse.js');
const {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListResourcesRequestSchema,
  ReadResourceRequestSchema,
  ListPromptsRequestSchema,
  GetPromptRequestSchema,
} = require('@modelcontextprotocol/sdk/types.js');
const { execSync } = require('child_process');
const http = require('http');
const path = require('path');
const fs = require('fs');

// ── Configuration ──────────────────────────────────────────────────────────

const BRIDGE = process.env.SB_BRIDGE || path.join(__dirname, 'bridge.sh');
const SESSION_DIR = path.join(__dirname, '.session-bridge');

// ── Helpers ────────────────────────────────────────────────────────────────

function runBridge(args, envOverrides = {}) {
  try {
    const cmd = `${JSON.stringify(BRIDGE)} ${args}`;
    const stdout = execSync(cmd, {
      cwd: __dirname,
      encoding: 'utf-8',
      timeout: 10000,
      maxBuffer: 1024 * 1024,
      env: { ...process.env, ...envOverrides },
    });
    return { ok: true, stdout: stdout.trim() };
  } catch (err) {
    return { ok: false, stderr: err.stderr || err.message || String(err), stdout: (err.stdout || '').trim() };
  }
}

function getContext() {
  const ctxFile = path.join(SESSION_DIR, 'context.json');
  try {
    return JSON.parse(fs.readFileSync(ctxFile, 'utf-8'));
  } catch {
    return null;
  }
}

function getEvents(n = 10) {
  const evtFile = path.join(SESSION_DIR, 'events.jsonl');
  try {
    const lines = fs.readFileSync(evtFile, 'utf-8').trim().split('\n');
    return lines.slice(-n).map(l => JSON.parse(l));
  } catch {
    return [];
  }
}

function isInitialized() {
  return fs.existsSync(path.join(SESSION_DIR, 'context.json'));
}

function shellEscape(str) {
  return `'${str.replace(/'/g, "'\\''")}'`;
}

// ── MCP Server ─────────────────────────────────────────────────────────────

const server = new Server(
  { name: 'sessionbridge-mcp', version: '1.17.0' },
  { capabilities: { tools: {}, resources: {}, prompts: {} } }
);

// ── Resources ──────────────────────────────────────────────────────────────

server.setRequestHandler(ListResourcesRequestSchema, async () => ({
  resources: [
    {
      uri: 'sessionbridge://context',
      name: 'Session Context',
      description: 'Current session context (active tasks, summary, decisions)',
      mimeType: 'application/json',
    },
    {
      uri: 'sessionbridge://recent/10',
      name: 'Recent Events',
      description: 'Last 10 events from the event log',
      mimeType: 'application/json',
    },
    {
      uri: 'sessionbridge://recent/50',
      name: 'Recent Events (50)',
      description: 'Last 50 events from the event log',
      mimeType: 'application/json',
    },
    {
      uri: 'sessionbridge://events',
      name: 'Full Event Log',
      description: 'Complete events.jsonl log (newline-delimited JSON)',
      mimeType: 'application/x-ndjson',
    },
    {
      uri: 'sessionbridge://top',
      name: 'Timesink Report',
      description: 'Time spent per task — derived from task_start/task_end pairs',
      mimeType: 'text/plain',
    },
  ],
}));

server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
  const uri = request.params.uri;

  if (uri === 'sessionbridge://context') {
    if (!isInitialized()) {
      throw new Error('SessionBridge not initialized. Call sb_init first.');
    }
    return {
      contents: [{ uri, mimeType: 'application/json', text: JSON.stringify(getContext(), null, 2) }],
    };
  }

  const recentMatch = uri.match(/^sessionbridge:\/\/recent\/(\d+)$/);
  if (recentMatch) {
    if (!isInitialized()) {
      throw new Error('SessionBridge not initialized.');
    }
    const n = parseInt(recentMatch[1], 10);
    return {
      contents: [{ uri, mimeType: 'application/json', text: JSON.stringify(getEvents(n), null, 2) }],
    };
  }

  if (uri === 'sessionbridge://events') {
    if (!isInitialized()) {
      throw new Error('SessionBridge not initialized. Call sb_init first.');
    }
    const evtFile = path.join(SESSION_DIR, 'events.jsonl');
    try {
      const text = fs.readFileSync(evtFile, 'utf-8');
      return {
        contents: [{ uri, mimeType: 'application/x-ndjson', text }],
      };
    } catch {
      throw new Error('Could not read events.jsonl');
    }
  }

  if (uri === 'sessionbridge://top') {
    if (!isInitialized()) {
      throw new Error('SessionBridge not initialized. Call sb_init first.');
    }
    const result = runBridge('top');
    if (result.ok) {
      return {
        contents: [{ uri, mimeType: 'text/plain', text: result.stdout }],
      };
    }
    throw new Error(result.stderr || 'Could not generate timesink report');
  }

  throw new Error(`Unknown resource: ${uri}`);
});

// ── Prompts ────────────────────────────────────────────────────────────────

server.setRequestHandler(ListPromptsRequestSchema, async () => ({
  prompts: [
    {
      name: 'session_recovery',
      description: 'Session recovery prompt — loads context, recent events, and suggests next steps',
      arguments: [],
    },
    {
      name: 'activity_report',
      description: 'Generate an activity report for the current session',
      arguments: [
        { name: 'events', description: 'Number of recent events to include (default: 10)', required: false },
      ],
    },
  ],
}));

server.setRequestHandler(GetPromptRequestSchema, async (request) => {
  const name = request.params.name;
  const args = request.params.arguments || {};

  if (name === 'session_recovery') {
    if (!isInitialized()) {
      return {
        messages: [
          {
            role: 'user',
            content: {
              type: 'text',
              text: 'SessionBridge is not initialized. Run sb_init to start a new session.',
            },
          },
        ],
      };
    }

    const ctx = getContext();
    const events = getEvents(5);

    return {
      messages: [
        {
          role: 'user',
          content: {
            type: 'text',
            text: [
              '# SessionBridge Recovery',
              '',
              `**Session:** ${ctx.summary}`,
              `**Started:** ${ctx.started_at}`,
              `**Event Count:** ${ctx.events || '(see events file)'}`,
              '',
              ctx.active_tasks.length > 0 ? `**Active Tasks:**\n${ctx.active_tasks.map(t => `- ${t}`).join('\n')}` : '**Active Tasks:** None',
              '',
              ctx.completed_tasks.length > 0 ? `**Completed Tasks:**\n${ctx.completed_tasks.slice(-5).map(t => `- ${t}`).join('\n')}` : '',
              '',
              ctx.recent_decisions.length > 0 ? `**Recent Decisions:**\n${ctx.recent_decisions.slice(-3).map(d => `- ${d.what}: ${d.why}`).join('\n')}` : '',
              '',
              '**Recent Events:**',
              events.map(e => `- [${e.e}] ${JSON.stringify(e.data)}`).join('\n'),
              '',
              '**Next Steps:**',
              '- Continue working on active tasks',
              '- Log events with `sb_log` to track progress',
              '- Use `sb_bookmark_save` to snapshot important states',
              '- Use `sb_heartbeat` to log periodic progress',
            ].join('\n'),
          },
        },
      ],
    };
  }

  if (name === 'activity_report') {
    const eventCount = parseInt(args.events, 10) || 10;
    if (!isInitialized()) {
      return {
        messages: [{ role: 'user', content: { type: 'text', text: 'SessionBridge not initialized.' } }],
      };
    }

    const ctx = getContext();
    const events = getEvents(eventCount);

    const taskSection = ctx.active_tasks.length > 0
      ? `**Active Tasks:**\n${ctx.active_tasks.map(t => `- ${t}`).join('\n')}`
      : '**Active Tasks:** None';

    const completedSection = ctx.completed_tasks.length > 0
      ? `**Completed Tasks (${ctx.completed_tasks.length} total):**\n${ctx.completed_tasks.slice(-5).map(t => `- ${t}`).join('\n')}`
      : '';

    return {
      messages: [
        {
          role: 'user',
          content: {
            type: 'text',
            text: [
              '# SessionBridge Activity Report',
              '',
              `**Session:** ${ctx.summary}`,
              `**Started:** ${ctx.started_at}`,
              '',
              taskSection,
              '',
              completedSection,
              '',
              ctx.recent_decisions.length > 0
                ? `**Recent Decisions:**\n${ctx.recent_decisions.slice(-3).map(d => `- ${d.what}: ${d.why}`).join('\n')}`
                : '',
              '',
              `**Last ${eventCount} Events:**`,
              events.map(e => `- [${e.t}] **${e.e}** — ${JSON.stringify(e.data)}`).join('\n'),
            ].join('\n'),
          },
        },
      ],
    };
  }

  throw new Error(`Unknown prompt: ${name}`);
});

// ── Tools ──────────────────────────────────────────────────────────────────

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'sb_init',
      description: 'Initialize a new SessionBridge session',
      inputSchema: {
        type: 'object',
        properties: {
          summary: { type: 'string', description: 'Session summary/description', default: 'Session initialized' },
          gc_keep: { type: 'number', description: 'Auto-GC: keep only last N events', default: 500 },
          tags: { type: 'array', items: { type: 'string' }, description: 'Session-level tags', default: [] },
        },
      },
    },
    {
      name: 'sb_status',
      description: 'Show current session status (tasks, events, decisions)',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'sb_summary',
      description: 'Show a comprehensive session summary report',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'sb_log',
      description: 'Log an event to the session log',
      inputSchema: {
        type: 'object',
        required: ['event_type'],
        properties: {
          event_type: { type: 'string', description: 'Event type (task_start, decision, file_touch, etc.)' },
          data: { type: 'string', description: 'JSON data string (e.g. \'{"task":"Build X"}\')', default: '{}' },
        },
      },
    },
    {
      name: 'sb_heartbeat',
      description: 'Log a periodic heartbeat event with session status (events count, active tasks, summary)',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'sb_recent',
      description: 'Show recent events from the event log',
      inputSchema: {
        type: 'object',
        properties: {
          count: { type: 'number', description: 'Number of events to show', default: 10 },
        },
      },
    },
    {
      name: 'sb_task_add',
      description: 'Add an active task to the session',
      inputSchema: {
        type: 'object',
        required: ['task'],
        properties: {
          task: { type: 'string', description: 'Task name/description' },
        },
      },
    },
    {
      name: 'sb_task_done',
      description: 'Mark a task as completed',
      inputSchema: {
        type: 'object',
        required: ['task'],
        properties: {
          task: { type: 'string', description: 'Task name to mark as done' },
        },
      },
    },
    {
      name: 'sb_decision',
      description: 'Log an architectural or design decision',
      inputSchema: {
        type: 'object',
        required: ['what'],
        properties: {
          what: { type: 'string', description: 'What was decided' },
          why: { type: 'string', description: 'Rationale (optional)', default: '' },
        },
      },
    },
    {
      name: 'sb_touch',
      description: 'Record a file touch (read/wrote/created)',
      inputSchema: {
        type: 'object',
        required: ['path'],
        properties: {
          path: { type: 'string', description: 'File path' },
          action: { type: 'string', description: 'Action: read/wrote/created', default: 'read' },
        },
      },
    },
    {
      name: 'sb_bookmark_save',
      description: 'Save current context as a named bookmark',
      inputSchema: {
        type: 'object',
        required: ['name'],
        properties: {
          name: { type: 'string', description: 'Bookmark name (e.g. pre-refactor)' },
        },
      },
    },
    {
      name: 'sb_bookmark_restore',
      description: 'Restore context from a named bookmark',
      inputSchema: {
        type: 'object',
        required: ['name'],
        properties: {
          name: { type: 'string', description: 'Bookmark name to restore' },
        },
      },
    },
    {
      name: 'sb_bookmark_list',
      description: 'List all saved bookmarks',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'sb_bookmark_delete',
      description: 'Delete a saved bookmark',
      inputSchema: {
        type: 'object',
        required: ['name'],
        properties: {
          name: { type: 'string', description: 'Bookmark name to delete' },
        },
      },
    },
    {
      name: 'sb_tag_list',
      description: 'List all known tags with event counts',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'sb_gc',
      description: 'Garbage-collect old events, keeping only the last N',
      inputSchema: {
        type: 'object',
        properties: {
          keep: { type: 'number', description: 'Number of events to keep', default: 500 },
        },
      },
    },
    {
      name: 'sb_export',
      description: 'Export session log as a Markdown report (human-readable summary)',
      inputSchema: {
        type: 'object',
        properties: {
          output: { type: 'string', description: 'Output file path (optional, prints to stdout if omitted)' },
        },
      },
    },
    {
      name: 'sb_export_json',
      description: 'Export session log as a JSON dump',
      inputSchema: {
        type: 'object',
        properties: {
          output: { type: 'string', description: 'Output file path (optional, prints to stdout if omitted)' },
        },
      },
    },
    {
      name: 'sb_top',
      description: 'Timesink report — show time spent per task (derived from task_start/task_end pairs)',
      inputSchema: {
        type: 'object',
        properties: {
          limit: { type: 'number', description: 'Show only top N tasks by duration (0 = all)', default: 0 },
        },
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const safe = (v) => String(v ?? '');

  switch (name) {
    case 'sb_init': {
      const summary = safe(args?.summary || 'Session initialized');
      const tags = args?.tags || [];
      const envOverrides = {};
      if (args?.gc_keep) envOverrides.SB_GC_KEEP = String(args.gc_keep);
      let cmd = `init ${shellEscape(summary)}`;
      if (tags.length > 0) {
        cmd += ' --tag ' + tags.map(t => shellEscape(t)).join(' --tag ');
      }
      const result = runBridge(cmd, envOverrides);
      return { content: [{ type: 'text', text: result.ok ? `Session initialized: ${summary}` : `Error: ${result.stderr}` }] };
    }

    case 'sb_status': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized. Run sb_init first.' }] };
      const result = runBridge('status');
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    case 'sb_summary': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const result = runBridge('summary');
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    case 'sb_log': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const eventType = safe(args?.event_type);
      const data = args?.data ? `'${args.data.replace(/'/g, "'\\''")}'` : '';
      const result = runBridge(`log ${eventType} ${data}`);
      return { content: [{ type: 'text', text: result.ok ? `Logged: ${eventType}` : `Error: ${result.stderr}` }] };
    }

    case 'sb_heartbeat': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const result = runBridge('heartbeat');
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    case 'sb_recent': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const count = args?.count || 10;
      const result = runBridge(`recent ${count}`);
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    case 'sb_task_add': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const taskName = safe(args?.task);
      const result = runBridge(`task add ${shellEscape(taskName)}`);
      return { content: [{ type: 'text', text: result.ok ? `Task added: ${taskName}` : `Error: ${result.stderr}` }] };
    }

    case 'sb_task_done': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const doneTask = safe(args?.task);
      const result = runBridge(`task done ${shellEscape(doneTask)}`);
      return { content: [{ type: 'text', text: result.ok ? `Task completed: ${doneTask}` : `Error: ${result.stderr}` }] };
    }

    case 'sb_decision': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const what = safe(args?.what);
      const why = safe(args?.why || '');
      const result = runBridge(`decision ${shellEscape(what)} ${shellEscape(why)}`);
      return { content: [{ type: 'text', text: result.ok ? `Decision logged: ${what}` : `Error: ${result.stderr}` }] };
    }

    case 'sb_touch': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const filePath = safe(args?.path);
      const action = safe(args?.action || 'read');
      const result = runBridge(`touch ${shellEscape(filePath)} ${shellEscape(action)}`);
      return { content: [{ type: 'text', text: result.ok ? `Logged: ${action} ${filePath}` : `Error: ${result.stderr}` }] };
    }

    case 'sb_bookmark_save': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const bmName = safe(args?.name);
      const result = runBridge(`bookmark save ${shellEscape(bmName)}`);
      return { content: [{ type: 'text', text: result.ok ? `Bookmark saved: ${bmName}` : `Error: ${result.stderr}` }] };
    }

    case 'sb_bookmark_restore': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const restoreName = safe(args?.name);
      const result = runBridge(`bookmark restore ${shellEscape(restoreName)}`);
      return { content: [{ type: 'text', text: result.ok ? `Bookmark restored: ${restoreName}` : `Error: ${result.stderr}` }] };
    }

    case 'sb_bookmark_list': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const result = runBridge('bookmark list');
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    case 'sb_bookmark_delete': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const delName = safe(args?.name);
      const result = runBridge(`bookmark delete ${shellEscape(delName)}`);
      return { content: [{ type: 'text', text: result.ok ? `Bookmark deleted: ${delName}` : `Error: ${result.stderr}` }] };
    }

    case 'sb_tag_list': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const result = runBridge('tag list');
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    case 'sb_gc': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const keep = args?.keep || 500;
      const result = runBridge(`gc ${keep}`);
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    case 'sb_export': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const outFile = args?.output ? shellEscape(args.output) : '';
      const result = runBridge(`export ${outFile}`);
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    case 'sb_export_json': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const jOutFile = args?.output ? shellEscape(args.output) : '';
      const result = runBridge(`export-json ${jOutFile}`);
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    case 'sb_top': {
      if (!isInitialized()) return { content: [{ type: 'text', text: 'SessionBridge not initialized.' }] };
      const topLimit = args?.limit || 0;
      const result = runBridge(`top ${topLimit}`);
      return { content: [{ type: 'text', text: result.ok ? result.stdout : `Error: ${result.stderr}` }] };
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

// ── Transport ──────────────────────────────────────────────────────────────

async function main() {
  const useSSE = process.argv.includes('--port') || process.argv.includes('--sse');
  const port = parseInt(process.env.PORT || '3001', 10);

  if (useSSE) {
    const app = http.createServer(async (req, res) => {
      if (req.method === 'POST' && req.url === '/mcp') {
        const transport = new SSEServerTransport('/mcp', res);
        await server.connect(transport);
        req.on('close', () => {
          // session cleanup happens on close
        });
      } else {
        res.writeHead(404);
        res.end();
      }
    });
    app.listen(port);
    console.error(`SessionBridge MCP server (SSE) listening on :${port}`);
  } else {
    const transport = new StdioServerTransport();
    await server.connect(transport);
    console.error('SessionBridge MCP server (stdio) running...');
  }
}

main().catch((err) => {
  console.error('Fatal:', err);
  process.exit(1);
});
