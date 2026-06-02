#!/usr/bin/env bash
# SessionBridge — MCP Server Test Suite
# Tests the MCP server via stdio transport using the JSON-RPC protocol
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP="$SCRIPT_DIR/mcp-server.js"
SB_DIR="$SCRIPT_DIR/.session-bridge"
export SB_BRIDGE="$SCRIPT_DIR/bridge.sh"

PASS=0
FAIL=0

# Save and restore .session-bridge state
_save_sb() {
    if [ -d "$SB_DIR" ]; then
        cp -r "$SB_DIR" /tmp/sb-saved-state
    fi
}

_restore_sb() {
    rm -rf "$SB_DIR"
    if [ -d /tmp/sb-saved-state ]; then
        cp -r /tmp/sb-saved-state "$SB_DIR"
        rm -rf /tmp/sb-saved-state
    fi
}

_clean_sb() {
    rm -rf "$SB_DIR" /tmp/sb-saved-state
}

# Send a JSON-RPC request to the MCP server via stdio and parse the response
mcp_call() {
    local request="$1"
    echo "$request" | node "$MCP" 2>/dev/null
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if ! echo "$haystack" | grep -q "$needle"; then
        echo "  FAIL: $msg"
        echo "    expected to contain: $needle"
        echo "    actual: $haystack"
        return 1
    fi
    echo "  PASS: $msg"
    return 0
}

assert_jq() {
    local json="$1"
    local filter="$2"
    local msg="${3:-}"
    if ! echo "$json" | jq -e "$filter" >/dev/null 2>&1; then
        echo "  FAIL: $msg"
        echo "    jq filter failed: $filter"
        echo "    json: $json"
        return 1
    fi
    echo "  PASS: $msg"
    return 0
}

run_test() {
    local name="$1"
    shift
    echo ""
    echo "--- $name ---"
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

# ── Tests ───────────────────────────────────────────────────────────────────

test_tools_list() {
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/list"}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    
    assert_jq "$resp" '.id == 1' "Response id should be 1" || return 1
    assert_jq "$resp" '.result.tools | length == 19' "Should list 19 tools" || return 1
    assert_jq "$resp" '.result.tools[] | select(.name == "sb_init") | length > 0' "Should include sb_init" || return 1
    assert_jq "$resp" '.result.tools[] | select(.name == "sb_heartbeat") | length > 0' "Should include sb_heartbeat" || return 1
    assert_jq "$resp" '.result.tools[] | select(.name == "sb_bookmark_delete") | length > 0' "Should include sb_bookmark_delete" || return 1
    assert_jq "$resp" '.result.tools[] | select(.name == "sb_tag_list") | length > 0' "Should include sb_tag_list" || return 1
    assert_jq "$resp" '.result.tools[] | select(.name == "sb_gc") | length > 0' "Should include sb_gc" || return 1
}

test_status_before_init() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_status","arguments":{}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    
    assert_contains "$resp" "not initialized" "Should return not initialized message" || return 1
}

test_init_then_status() {
    _clean_sb
    local req1
    req1=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Status Test"}}}
EOF
)
    mcp_call "$req1" >/dev/null 2>&1 || true
    
    local req2
    req2=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_status","arguments":{}}}
EOF
)
    local resp
    resp=$(mcp_call "$req2")
    
    assert_jq "$resp" '.id == 2' "Response id should be 2" || return 1
    assert_contains "$resp" "Status Test" "Status should include session name" || return 1
}

test_heartbeat_via_mcp() {
    _clean_sb
    local req1
    req1=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Heartbeat Test"}}}
EOF
)
    mcp_call "$req1" >/dev/null 2>&1 || true
    
    local req2
    req2=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_heartbeat","arguments":{}}}
EOF
)
    local resp
    resp=$(mcp_call "$req2")
    
    assert_contains "$resp" "Heartbeat" "Should return heartbeat message" || return 1
    assert_contains "$resp" "Heartbeat Test" "Should include session summary" || return 1
}

test_init_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"MCP Test Session"}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    
    assert_jq "$resp" '.id == 2' "Response id should be 2" || return 1
    assert_contains "$resp" "Session initialized: MCP Test Session" "Should confirm initialization" || return 1
}

test_task_lifecycle_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Task Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_task_add","arguments":{"task":"MCP Task"}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    assert_contains "$resp" "Task added: MCP Task" "Should confirm task added" || return 1
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sb_task_done","arguments":{"task":"MCP Task"}}}
EOF
)
    resp=$(mcp_call "$req")
    assert_contains "$resp" "Task completed: MCP Task" "Should confirm task completed" || return 1
}

test_decision_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Decision Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_decision","arguments":{"what":"Use MCP","why":"Agent integration"}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    assert_contains "$resp" "Decision logged: Use MCP" "Should confirm decision logged" || return 1
}

test_recent_events_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Recent Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_log","arguments":{"event_type":"test_event","data":"{\"msg\":\"hello mcp\"}"}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    assert_contains "$resp" "Logged: test_event" "Should confirm event logged" || return 1
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sb_recent","arguments":{"count":5}}}
EOF
)
    resp=$(mcp_call "$req")
    assert_contains "$resp" "test_event" "Recent should include test_event" || return 1
}

test_touch_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Touch Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_touch","arguments":{"path":"src/main.js","action":"created"}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    assert_contains "$resp" "Logged: created src/main.js" "Should confirm touch logged" || return 1
}

test_bookmarks_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Bookmark Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_bookmark_save","arguments":{"name":"test-point"}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    assert_contains "$resp" "Bookmark saved: test-point" "Should confirm bookmark saved" || return 1
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sb_bookmark_list","arguments":{}}}
EOF
)
    resp=$(mcp_call "$req")
    assert_contains "$resp" "test-point" "Bookmark list should include test-point" || return 1
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"sb_bookmark_restore","arguments":{"name":"test-point"}}}
EOF
)
    resp=$(mcp_call "$req")
    assert_contains "$resp" "Bookmark restored" "Should confirm bookmark restored" || return 1
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"sb_bookmark_delete","arguments":{"name":"test-point"}}}
EOF
)
    resp=$(mcp_call "$req")
    assert_contains "$resp" "Bookmark deleted" "Should confirm bookmark deleted" || return 1
}

test_resources_list() {
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"resources/list"}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    
    assert_jq "$resp" '.result.resources | length == 5' "Should list 5 resources" || return 1
    assert_jq "$resp" '.result.resources[] | select(.uri == "sessionbridge://context") | length > 0' "Should include context resource" || return 1
    assert_jq "$resp" '.result.resources[] | select(.uri == "sessionbridge://recent/10") | length > 0' "Should include recent/10 resource" || return 1
    assert_jq "$resp" '.result.resources[] | select(.uri == "sessionbridge://recent/50") | length > 0' "Should include recent/50 resource" || return 1
    assert_jq "$resp" '.result.resources[] | select(.uri == "sessionbridge://events") | length > 0' "Should include events resource" || return 1
}

test_prompts_list() {
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"prompts/list"}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    
    assert_jq "$resp" '.result.prompts | length == 2' "Should list 2 prompts" || return 1
    assert_jq "$resp" '.result.prompts[] | select(.name == "session_recovery") | length > 0' "Should include session_recovery" || return 1
    assert_jq "$resp" '.result.prompts[] | select(.name == "activity_report") | length > 0' "Should include activity_report" || return 1
}

test_sb_log_error_before_init() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_log","arguments":{"event_type":"test"}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    assert_contains "$resp" "not initialized" "Should return not initialized before init" || return 1
}

test_gc_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"GC Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    for i in 1 2 3 4 5; do
        req=$(cat <<EOF
{"jsonrpc":"2.0","id":$((i+1)),"method":"tools/call","params":{"name":"sb_log","arguments":{"event_type":"evt$i","data":"{\"n\":$i}"}}}
EOF
)
        mcp_call "$req" >/dev/null 2>&1 || true
    done
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"sb_gc","arguments":{"keep":2}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    assert_contains "$resp" "GC" "Should mention GC" || return 1
}

test_tag_list_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Tag Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_tag_list","arguments":{}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    assert_contains "$resp" "No tags" "Tag list should return empty result" || return 1
}

test_summary_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Summary Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_summary","arguments":{}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    assert_contains "$resp" "Summary Test" "Summary should include session name" || return 1
    assert_contains "$resp" "SessionBridge" "Summary should have header" || return 1
}


test_export_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"MCP Export Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_export","arguments":{}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    
    assert_contains "$resp" "SessionBridge Export" "Export via MCP should include header" || return 1
    assert_contains "$resp" "MCP Export Test" "Export via MCP should include session name" || return 1
    assert_contains "$resp" "Event Log" "Export via MCP should include event log section" || return 1
}

test_export_json_via_mcp() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"MCP JSON Export"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sb_export_json","arguments":{}}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    
    assert_jq "$resp" '.result.content[0].text | startswith("[")' "Export JSON via MCP should return JSON array" || return 1
    assert_contains "$resp" "session_start" "Export JSON should contain session_start event" || return 1
}

# ── Run all tests ───────────────────────────────────────────────────────────

echo "SessionBridge MCP Server Test Suite"
echo "==================================="

run_test "tools/list returns 19 tools" test_tools_list
run_test "status before init returns error" test_status_before_init
run_test "init via MCP" test_init_via_mcp
run_test "init then status" test_init_then_status
run_test "heartbeat via MCP" test_heartbeat_via_mcp
run_test "task lifecycle via MCP" test_task_lifecycle_via_mcp
run_test "decision via MCP" test_decision_via_mcp
run_test "recent events via MCP" test_recent_events_via_mcp
run_test "touch via MCP" test_touch_via_mcp
run_test "bookmarks via MCP (save/list/restore/delete)" test_bookmarks_via_mcp
run_test "tag list via MCP" test_tag_list_via_mcp
run_test "summary via MCP" test_summary_via_mcp
run_test "resources/list returns 5 resources" test_resources_list
run_test "prompts/list returns 2 prompts" test_prompts_list
run_test "sb_log error before init" test_sb_log_error_before_init
test_events_resource() {
    _clean_sb
    local req
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sb_init","arguments":{"summary":"Events Resource Test"}}}
EOF
)
    mcp_call "$req" >/dev/null 2>&1 || true
    
    for i in 1 2 3; do
        req=$(cat <<EOF
{"jsonrpc":"2.0","id":$((i+1)),"method":"tools/call","params":{"name":"sb_log","arguments":{"event_type":"evt$i","data":"{\"n\":$i}"}}}
EOF
)
        mcp_call "$req" >/dev/null 2>&1 || true
    done
    
    req=$(cat <<'EOF'
{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"sessionbridge://events"}}
EOF
)
    local resp
    resp=$(mcp_call "$req")
    
    assert_contains "$resp" "evt1" "Events resource should contain evt1" || return 1
    assert_contains "$resp" "evt2" "Events resource should contain evt2" || return 1
    assert_contains "$resp" "evt3" "Events resource should contain evt3" || return 1
    assert_jq "$resp" '.result.contents[0].mimeType == "application/x-ndjson"' "Events resource should have ndjson mime type" || return 1
}

run_test "events resource via MCP" test_events_resource
run_test "gc via MCP" test_gc_via_mcp
run_test "export via MCP" test_export_via_mcp
run_test "export JSON via MCP" test_export_json_via_mcp

echo ""
echo "========================"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "All MCP tests passed!" || echo "Some tests failed!"
exit $FAIL