#!/usr/bin/env bash
# Unit tests for scripts/r2_budget_gate.sh. External binaries (curl, rclone,
# julia) are stubbed via tests/stubs on PATH; jq is used for real.
# Run: bash tests/test_r2_budget_gate.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/r2_budget_gate.sh"
STUBS="$ROOT/tests/stubs"
FIXTURES="$ROOT/tests/fixtures"

command -v jq >/dev/null || { echo "jq is required to run these tests" >&2; exit 1; }

PASS=0
FAIL=0

# t NAME FN — run test function FN in a subshell with stubs on PATH and a
# fresh scratch dir. The gate's required env is pre-populated with defaults;
# individual tests override as needed.
t() {
    local name=$1 fn=$2
    if (
        set -e
        TMP="$(mktemp -d)"
        trap 'rm -rf "$TMP"' EXIT
        export PATH="$STUBS:$PATH"
        export WORK="$TMP/work"
        export GITHUB_OUTPUT="$TMP/output.txt"
        export GITHUB_STEP_SUMMARY="$TMP/summary.md"
        export CLOUDFLARE_ANALYTICS_TOKEN=stub-token
        export R2_ACCOUNT_ID=stub-account
        export REMOTE="r2:testbucket"
        export REGEN_MODE=incremental
        export SHARDS=10
        export JW_DIR="$TMP/jw"
        export REGISTRY="$TMP/registry"
        export STORE_PREFIX="store/v2"
        export STUB_CURL_RESPONSE="$FIXTURES/graphql_ok.json"
        export STUB_PENDING=0
        mkdir -p "$WORK" "$JW_DIR/scripts" "$REGISTRY"
        printf 'STORE_PREFIX="store/v2"\n' > "$JW_DIR/scripts/symbolcache_common.sh"
        touch "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"
        "$fn"
    ); then
        PASS=$((PASS + 1)); echo "ok   - $name"
    else
        FAIL=$((FAIL + 1)); echo "FAIL - $name"
    fi
}

assert_eq() {
    [[ "$1" == "$2" ]] || { echo "  expected: '$2'"; echo "  actual:   '$1'"; return 1; } >&2
}

# Last value written for KEY in $GITHUB_OUTPUT.
output_val() {
    grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

# --- query_used -------------------------------------------------------------

test_query_used_ok() {
    source "$GATE"
    assert_eq "$(query_used)" "123456"
}

test_query_used_empty_groups_is_zero() {
    export STUB_CURL_RESPONSE="$FIXTURES/graphql_empty.json"
    source "$GATE"
    assert_eq "$(query_used)" "0"
}

test_query_used_no_account_fails() {
    export STUB_CURL_RESPONSE="$FIXTURES/graphql_noaccount.json"
    source "$GATE"
    ! query_used
}

test_query_used_graphql_errors_fail() {
    export STUB_CURL_RESPONSE="$FIXTURES/graphql_errors.json"
    source "$GATE"
    ! query_used
}

test_query_used_curl_failure_fails() {
    export STUB_CURL_EXIT=22
    source "$GATE"
    ! query_used
}

test_query_used_malformed_sum_fails() {
    export STUB_CURL_RESPONSE="$FIXTURES/graphql_malformed.json"
    source "$GATE"
    ! query_used
}

t "query_used sums requests"            test_query_used_ok
t "query_used empty groups -> 0"        test_query_used_empty_groups_is_zero
t "query_used no account -> failure"    test_query_used_no_account_fails
t "query_used graphql errors -> failure" test_query_used_graphql_errors_fail
t "query_used curl failure -> failure"  test_query_used_curl_failure_fails
t "query_used malformed sum -> failure"  test_query_used_malformed_sum_fails

# --- build_done_set ----------------------------------------------------------

# Creates index.tar.gz (2 success keys) and tombstones.txt.gz (1 key) fixtures
# in $TMP and points the rclone stub at them.
make_remote_fixtures() {
    mkdir -p "$TMP/fix"
    printf 'uuid-a/hash1\nuuid-b/hash2\n' > "$TMP/fix/index.txt"
    tar -czf "$TMP/fix/index.tar.gz" -C "$TMP/fix" index.txt
    printf 'uuid-c/hash3\n' | gzip > "$TMP/fix/tombstones.txt.gz"
    export STUB_INDEX_FILE="$TMP/fix/index.tar.gz"
    export STUB_TOMBSTONES_FILE="$TMP/fix/tombstones.txt.gz"
}

test_done_set_incremental_unions_tombstones() {
    make_remote_fixtures
    source "$GATE"
    build_done_set
    assert_eq "$(sort "$WORK/done.txt" | tr '\n' ' ')" "uuid-a/hash1 uuid-b/hash2 uuid-c/hash3 "
}

test_done_set_full_skips_tombstones() {
    make_remote_fixtures
    export REGEN_MODE=full
    source "$GATE"
    build_done_set
    assert_eq "$(sort "$WORK/done.txt" | tr '\n' ' ')" "uuid-a/hash1 uuid-b/hash2 "
}

test_done_set_tolerates_absent_remote_files() {
    # No STUB_INDEX_FILE / STUB_TOMBSTONES_FILE -> rclone stub exits 1.
    source "$GATE"
    build_done_set
    assert_eq "$(wc -l < "$WORK/done.txt" | tr -d ' ')" "0"
}

test_done_set_rejects_unknown_mode() {
    export REGEN_MODE=bogus
    source "$GATE"
    ! build_done_set
}

test_done_set_fails_on_rclone_transport_error() {
    export STUB_RCLONE_EXIT=1   # not a not-found code -> hard failure
    source "$GATE"
    ! build_done_set
}

t "done set: incremental unions tombstones" test_done_set_incremental_unions_tombstones
t "done set: full skips tombstones"         test_done_set_full_skips_tombstones
t "done set: tolerates absent remote files" test_done_set_tolerates_absent_remote_files
t "done set: rejects unknown mode"          test_done_set_rejects_unknown_mode
t "done set: rclone transport error -> failure" test_done_set_fails_on_rclone_transport_error

# --- count_pending -----------------------------------------------------------

test_count_pending_counts_worklist_lines() {
    export STUB_PENDING=7
    source "$GATE"
    touch "$WORK/done.txt"
    assert_eq "$(count_pending)" "7"
}

test_count_pending_forwards_sweep_args_and_done_set() {
    export STUB_PENDING=1
    export STUB_JULIA_ARGS_FILE="$TMP/julia_args"
    export SWEEP_ARGS="--newest 3"
    source "$GATE"
    touch "$WORK/done.txt"
    count_pending >/dev/null
    grep -qx -- "--dry-run" "$STUB_JULIA_ARGS_FILE"
    grep -qx -- "--newest" "$STUB_JULIA_ARGS_FILE"
    grep -qx -- "3" "$STUB_JULIA_ARGS_FILE"
    grep -qx -- "$WORK/done.txt" "$STUB_JULIA_ARGS_FILE"
    grep -qx -- "$REGISTRY" "$STUB_JULIA_ARGS_FILE"
    # The whole-run count must not be shard-limited.
    ! grep -qx -- "--shard" "$STUB_JULIA_ARGS_FILE"
}

t "count_pending: counts worklist lines"       test_count_pending_counts_worklist_lines
t "count_pending: forwards args, no --shard"   test_count_pending_forwards_sweep_args_and_done_set

# --- decide_and_report / main ------------------------------------------------

test_decide_proceed_under_budget() {
    source "$GATE"
    decide_and_report 500000 100
    assert_eq "$(output_val proceed)" "true"
    # planned = 2*100 + 2*10 + 10000 = 10220
    assert_eq "$(output_val planned)" "10220"
    assert_eq "$(output_val used)" "500000"
    assert_eq "$(output_val pending)" "100"
    assert_eq "$(output_val budget)" "1000000"
}

test_decide_skip_over_budget() {
    source "$GATE"
    decide_and_report 990000 100
    assert_eq "$(output_val proceed)" "false"
}

test_decide_exactly_at_budget_proceeds() {
    # planned = 2*100 + 2*10 + 10000 = 10220; used + planned == budget.
    export R2_CLASSA_BUDGET=20220
    source "$GATE"
    decide_and_report 10000 100
    assert_eq "$(output_val proceed)" "true"
}

test_decide_honors_margin_var() {
    export R2_CLASSA_MARGIN=0
    source "$GATE"
    decide_and_report 0 0
    # planned = 0 + 2*10 + 0 = 20
    assert_eq "$(output_val planned)" "20"
}

test_decide_writes_step_summary() {
    source "$GATE"
    decide_and_report 1 2
    grep -q "R2 Class A budget gate" "$GITHUB_STEP_SUMMARY"
}

t "decide: proceeds under budget"      test_decide_proceed_under_budget
t "decide: skips over budget"          test_decide_skip_over_budget
t "decide: exact budget proceeds (<=)" test_decide_exactly_at_budget_proceeds
t "decide: honors R2_CLASSA_MARGIN"    test_decide_honors_margin_var
t "decide: writes step summary"        test_decide_writes_step_summary

test_main_end_to_end_proceed() {
    make_remote_fixtures
    export STUB_PENDING=5
    bash "$GATE"
    assert_eq "$(output_val proceed)" "true"
    # planned = 2*5 + 2*10 + 10000 = 10030
    assert_eq "$(output_val planned)" "10030"
    assert_eq "$(output_val used)" "123456"
}

test_main_end_to_end_skip_exits_zero() {
    make_remote_fixtures
    export STUB_PENDING=5
    export R2_CLASSA_BUDGET=100000   # used=123456 > budget -> skip, exit 0
    bash "$GATE"
    assert_eq "$(output_val proceed)" "false"
}

test_main_fail_closed_on_analytics_failure() {
    make_remote_fixtures
    export STUB_CURL_EXIT=22
    ! bash "$GATE"
}

test_main_rejects_missing_env() {
    unset R2_ACCOUNT_ID
    ! bash "$GATE"
}

t "main: e2e proceed"                    test_main_end_to_end_proceed
t "main: e2e over-budget skip, exit 0"   test_main_end_to_end_skip_exits_zero
t "main: fail-closed on analytics error" test_main_fail_closed_on_analytics_failure
t "main: rejects missing env"            test_main_rejects_missing_env

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
