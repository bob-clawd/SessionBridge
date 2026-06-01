#!/usr/bin/env bash
# SessionBridge — Test suite
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$SCRIPT_DIR/bridge.sh"
PASS=0
FAIL=0

setup() {
    TESTDIR=$(mktemp -d /tmp/sb-test-XXXXXX)
    cd "$TESTDIR"
}

teardown() {
    cd /
    rm -rf "$TESTDIR"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [ "$expected" != "$actual" ]; then
        echo "  FAIL: $msg"
        echo "    expected: $expected"
        echo "    actual:   $actual"
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

# --- Tests ---

test_init() {
    setup
    local output
    output=$("$BRIDGE" init "Test session" 2>&1)
    # Should have created .session-bridge/
    [ -d ".session-bridge" ] || { echo "No .session-bridge dir"; teardown; return 1; }
    [ -f ".session-bridge/events.jsonl" ] || { echo "No events file"; teardown; return 1; }
    [ -f ".session-bridge/context.json" ] || { echo "No context file"; teardown; return 1; }
    [ -d ".session-bridge/bookmarks" ] || { echo "No bookmarks dir"; teardown; return 1; }
    # Validate event JSON
    cat .session-bridge/events.jsonl | jq . >/dev/null 2>&1 || { echo "Invalid JSON in events"; teardown; return 1; }
    teardown
}

test_log_with_data() {
    setup
    "$BRIDGE" init "Log test" >/dev/null 2>&1
    "$BRIDGE" log custom '{"hello":"world"}' >/dev/null 2>&1
    local count
    count=$(wc -l < .session-bridge/events.jsonl | tr -d ' ')
    [ "$count" -eq 2 ] || { echo "Expected 2 events, got $count"; teardown; return 1; }
    cat .session-bridge/events.jsonl | jq -e 'select(.e=="custom" and .data.hello=="world")' >/dev/null 2>&1 || { echo "Custom event not found"; teardown; return 1; }
    teardown
}

test_log_without_data() {
    setup
    "$BRIDGE" init >/dev/null 2>&1
    "$BRIDGE" log bare_event >/dev/null 2>&1
    cat .session-bridge/events.jsonl | jq -e 'select(.e=="bare_event" and .data == {})' >/dev/null 2>&1 || { echo "Bare event invalid"; teardown; return 1; }
    teardown
}

test_task_lifecycle() {
    setup
    "$BRIDGE" init "Tasks" >/dev/null 2>&1
    "$BRIDGE" task add "Task A" >/dev/null 2>&1
    "$BRIDGE" task done "Task A" >/dev/null 2>&1
    # Validate events
    cat .session-bridge/events.jsonl | jq -e 'select(.e=="task_start" and .data.task=="Task A")' >/dev/null 2>&1 || { echo "task_start missing"; teardown; return 1; }
    cat .session-bridge/events.jsonl | jq -e 'select(.e=="task_end" and .data.result=="completed")' >/dev/null 2>&1 || { echo "task_end missing"; teardown; return 1; }
    teardown
}

test_decision() {
    setup
    "$BRIDGE" init >/dev/null 2>&1
    "$BRIDGE" decision "Use X" "Because Y" >/dev/null 2>&1
    cat .session-bridge/events.jsonl | jq -e 'select(.e=="decision" and .data.what=="Use X" and .data.why=="Because Y")' >/dev/null 2>&1 || { echo "Decision not found"; teardown; return 1; }
    teardown
}

test_touch() {
    setup
    "$BRIDGE" init >/dev/null 2>&1
    "$BRIDGE" touch src/main.py created >/dev/null 2>&1
    cat .session-bridge/events.jsonl | jq -e 'select(.e=="file_touch" and .data.path=="src/main.py" and .data.action=="created")' >/dev/null 2>&1 || { echo "touch not found"; teardown; return 1; }
    teardown
}

test_env_emits_vars() {
    setup
    "$BRIDGE" init "Env test" >/dev/null 2>&1
    "$BRIDGE" task add "Task A" >/dev/null 2>&1

    # Source the env output
    eval "$("$BRIDGE" env 2>/dev/null)"

    [ -n "$SB_SESSION_ID" ] || { echo "SB_SESSION_ID empty"; teardown; return 1; }
    [ "$SB_SUMMARY" = "Env test" ] || { echo "SB_SUMMARY wrong: $SB_SUMMARY"; teardown; return 1; }
    [ "$SB_EVENT_COUNT" -ge 2 ] 2>/dev/null || { echo "SB_EVENT_COUNT wrong: $SB_EVENT_COUNT"; teardown; return 1; }
    [ -n "$SB_COMPLETED_COUNT" ] || { echo "SB_COMPLETED_COUNT empty"; teardown; return 1; }
    [ "$SB_BOOKMARK_COUNT" = "0" ] 2>/dev/null || { echo "SB_BOOKMARK_COUNT wrong: $SB_BOOKMARK_COUNT"; teardown; return 1; }

    teardown
}

test_env_task_vars() {
    setup
    "$BRIDGE" init >/dev/null 2>&1
    "$BRIDGE" task add "Complex task name" >/dev/null 2>&1

    eval "$("$BRIDGE" env 2>/dev/null)"

    echo "$SB_ACTIVE_TASKS" | grep -q "Complex task name" || {
        echo "SB_ACTIVE_TASKS missing task: $SB_ACTIVE_TASKS"; teardown; return 1;
    }

    teardown
}

test_gc_removes_old_events() {
    setup
    "$BRIDGE" init >/dev/null 2>&1

    # Add some events
    for i in $(seq 1 10); do
        "$BRIDGE" log test "{\"n\":$i}" >/dev/null 2>&1
    done

    local before
    before=$(wc -l < .session-bridge/events.jsonl | tr -d ' ')
    [ "$before" -eq 11 ] || { echo "Expected 11 events before gc, got $before"; teardown; return 1; }

    # GC keep 3
    "$BRIDGE" gc 3 >/dev/null 2>&1

    local after
    after=$(wc -l < .session-bridge/events.jsonl | tr -d ' ')
    [ "$after" -eq 3 ] || { echo "Expected 3 events after gc, got $after"; teardown; return 1; }

    # Verify the kept events are the latest ones
    local last_event
    last_event=$(tail -1 .session-bridge/events.jsonl | jq -r '.data.n // empty')
    [ "$last_event" = "10" ] || { echo "Last event should be n=10, got $last_event"; teardown; return 1; }

    teardown
}

test_gc_noop_when_under_limit() {
    setup
    "$BRIDGE" init >/dev/null 2>&1
    "$BRIDGE" log test1 '{}' >/dev/null 2>&1
    "$BRIDGE" log test2 '{}' >/dev/null 2>&1

    local before
    before=$(wc -l < .session-bridge/events.jsonl | tr -d ' ')
    "$BRIDGE" gc 100 >/dev/null 2>&1
    local after
    after=$(wc -l < .session-bridge/events.jsonl | tr -d ' ')
    [ "$after" -eq "$before" ] || { echo "GC should be noop, $before -> $after"; teardown; return 1; }

    teardown
}

test_bookmark_save_restore() {
    setup
    "$BRIDGE" init "Bookmarks" >/dev/null 2>&1
    "$BRIDGE" task add "Important task" >/dev/null 2>&1
    "$BRIDGE" bookmark save checkpoint-a >/dev/null 2>&1
    # Save a context field
    local ctx_before
    ctx_before=$(cat .session-bridge/context.json | jq -r '.active_tasks[0]')
    [ "$ctx_before" = "Important task" ] || { echo "Context mismatch before restore"; teardown; return 1; }
    # Verify bookmark file exists
    [ -f ".session-bridge/bookmarks/checkpoint-a.json" ] || { echo "Bookmark file missing"; teardown; return 1; }
    # Restore
    "$BRIDGE" bookmark restore checkpoint-a >/dev/null 2>&1
    teardown
}

test_bookmark_list() {
    setup
    "$BRIDGE" init >/dev/null 2>&1
    "$BRIDGE" bookmark save snap1 >/dev/null 2>&1
    local list_output
    list_output=$("$BRIDGE" bookmark list 2>&1)
    echo "$list_output" | grep -q "snap1" || { echo "Bookmark not listed"; teardown; return 1; }
    teardown
}

test_recent() {
    setup
    "$BRIDGE" init >/dev/null 2>&1
    "$BRIDGE" log event1 '{"n":1}' >/dev/null 2>&1
    "$BRIDGE" log event2 '{"n":2}' >/dev/null 2>&1
    local recent
    recent=$("$BRIDGE" recent 2 2>&1)
    echo "$recent" | grep -q "event2" || { echo "Recent missing latest event"; teardown; return 1; }
    teardown
}

test_checkpoint() {
    setup
    "$BRIDGE" init >/dev/null 2>&1
    "$BRIDGE" checkpoint "snapshot before refactor" >/dev/null 2>&1
    cat .session-bridge/events.jsonl | jq -e 'select(.e=="checkpoint" and .data.note=="snapshot before refactor")' >/dev/null 2>&1 || { echo "Checkpoint not found"; teardown; return 1; }
    teardown
}

test_summary() {
    setup
    "$BRIDGE" init "Summary test" >/dev/null 2>&1
    "$BRIDGE" task add "Task 1" >/dev/null 2>&1
    "$BRIDGE" decision "Use JSONL" "Simple" >/dev/null 2>&1
    "$BRIDGE" touch src/main.py created >/dev/null 2>&1
    local output
    output=$("$BRIDGE" summary 2>&1)
    echo "$output" | grep -q "Summary test" || { echo "Summary missing session name"; teardown; return 1; }
    echo "$output" | grep -q "Task 1" || { echo "Summary missing active task"; teardown; return 1; }
    echo "$output" | grep -q "Use JSONL" || { echo "Summary missing decision"; teardown; return 1; }
    echo "$output" | grep -q "SessionBridge" || { echo "Summary header missing"; teardown; return 1; }
    teardown
}

test_auto_gc_on_init() {
    setup
    "$BRIDGE" init "Pre-gc" >/dev/null 2>&1
    # Add 20 events
    for i in $(seq 1 20); do
        "$BRIDGE" log test "{\"n\":$i}" >/dev/null 2>&1
    done
    local before
    before=$(wc -l < .session-bridge/events.jsonl | tr -d ' ')
    [ "$before" -eq 21 ] || { echo "Expected 21 events, got $before"; teardown; return 1; }
    # Re-init with auto-gc (keep 5)
    SB_GC_KEEP=5 "$BRIDGE" init "Post-gc" >/dev/null 2>&1
    local after
    after=$(wc -l < .session-bridge/events.jsonl | tr -d ' ')
    # Should have: 5 kept + 1 new session_start
    [ "$after" -eq 6 ] || { echo "Expected 6 events after auto-gc+init, got $after"; teardown; return 1; }
    teardown
}

test_multiple_sessions() {
    setup
    "$BRIDGE" init "Session 1" >/dev/null 2>&1
    "$BRIDGE" log session1_event '{"id":1}' >/dev/null 2>&1
    # Second init should create new session (in same dir)
    "$BRIDGE" init "Session 2" >/dev/null 2>&1
    "$BRIDGE" log session2_event '{"id":2}' >/dev/null 2>&1
    local sessions
    sessions=$(cat .session-bridge/events.jsonl | jq -r '[.[] | select(.e=="session_start") | .data.summary] | join(", ")' 2>/dev/null)
    # Events from both sessions should exist
    local count
    count=$(wc -l < .session-bridge/events.jsonl | tr -d ' ')
    [ "$count" -eq 4 ] || { echo "Expected 4 events across sessions, got $count"; teardown; return 1; }
    teardown
}

# --- Run all tests ---

echo "SessionBridge Test Suite"
echo "========================"

run_test "init creates directory structure" test_init
run_test "log with data" test_log_with_data
run_test "log without data defaults to {}" test_log_without_data
run_test "task lifecycle (add + done)" test_task_lifecycle
run_test "decision logging" test_decision
run_test "file touch logging" test_touch
run_test "bookmark save and restore" test_bookmark_save_restore
run_test "bookmark list" test_bookmark_list
run_test "recent events" test_recent
run_test "checkpoint" test_checkpoint
run_test "multiple sessions" test_multiple_sessions
run_test "env emits vars" test_env_emits_vars
run_test "env task variables" test_env_task_vars
run_test "gc removes old events" test_gc_removes_old_events
run_test "gc noop under limit" test_gc_noop_when_under_limit
run_test "summary report" test_summary
run_test "auto-gc on init" test_auto_gc_on_init

echo ""
echo "========================"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || echo "Some tests failed!"
exit $FAIL
