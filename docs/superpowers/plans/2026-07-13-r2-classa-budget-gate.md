# R2 Class A Budget Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skip the daily symbol-cache regen when month-to-date R2 Class A operations plus an exact upper bound for the run would exceed the free tier's 1M/month budget.

**Architecture:** A standalone bash script (`scripts/r2_budget_gate.sh`) queries month-to-date Class A usage from Cloudflare's GraphQL Analytics API, counts the run's pending uploads via `jwcloudindex --dry-run`, and emits `proceed=true|false`. The existing `plan` job in the workflow runs it; the `regen` matrix job gets `if: needs.plan.outputs.proceed == 'true'`. Fail-closed: any operational failure fails `plan`, so `regen` never runs blind.

**Tech Stack:** bash, jq, curl, rclone, Julia (JuliaWorkspaces.jl's `jwcloudindex` CLI), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-07-13-r2-classa-budget-gate-design.md`

## Global Constraints

- Budget formula: proceed iff `used + 2*P + 2*SHARDS + margin <= budget`.
- Defaults: budget `1000000` (`R2_CLASSA_BUDGET` repo var), margin `10000` (`R2_CLASSA_MARGIN` repo var).
- `used` is **account-wide**, **UTC calendar month**, from `r2OperationsAdaptiveGroups`, filtered to the Class A action list (see script code, copied from https://developers.cloudflare.com/r2/pricing/).
- Fail-closed: analytics/rclone/dry-run failures exit nonzero. A skip (over budget) exits 0 with `proceed=false`.
- Empty analytics result rows = legitimate zero usage; malformed/error responses = hard failure, never zero.
- No force/bypass input; scheduled and manual runs both go through the gate.
- All bash uses `set -euo pipefail`; scripts must pass `shellcheck`.
- New repo secret required (manual, user action): `CLOUDFLARE_ANALYTICS_TOKEN` (*Account Analytics: Read*).

---

### Task 1: Test harness, stubs, and the analytics usage query

**Files:**
- Create: `scripts/r2_budget_gate.sh`
- Create: `tests/test_r2_budget_gate.sh`
- Create: `tests/stubs/curl`, `tests/stubs/rclone`, `tests/stubs/julia`
- Create: `tests/fixtures/graphql_ok.json`, `tests/fixtures/graphql_empty.json`, `tests/fixtures/graphql_noaccount.json`, `tests/fixtures/graphql_errors.json`

**Interfaces:**
- Produces: `query_used()` — no args, reads `CLOUDFLARE_ANALYTICS_TOKEN` + `R2_ACCOUNT_ID` from env, echoes a non-negative integer (month-to-date Class A ops) on stdout, returns nonzero on any API/parse failure.
- Produces: test harness conventions used by Tasks 2–3: `t NAME FN` runner, `assert_eq ACTUAL EXPECTED`, `output_val KEY` (reads `$GITHUB_OUTPUT`), env stubs `STUB_CURL_RESPONSE`, `STUB_CURL_EXIT`, `STUB_INDEX_FILE`, `STUB_TOMBSTONES_FILE`, `STUB_PENDING`, `STUB_JULIA_ARGS_FILE`; the gate script is `source`-able (sourcing does not run `main`).

- [ ] **Step 1: Create the stub binaries**

`tests/stubs/curl`:

```bash
#!/usr/bin/env bash
# curl stub: exits STUB_CURL_EXIT if nonzero, else cats STUB_CURL_RESPONSE.
set -u
if [[ "${STUB_CURL_EXIT:-0}" != 0 ]]; then
    exit "$STUB_CURL_EXIT"
fi
cat "${STUB_CURL_RESPONSE:?STUB_CURL_RESPONSE not set}"
```

`tests/stubs/rclone`:

```bash
#!/usr/bin/env bash
# rclone stub: only supports `copyto SRC DEST`. STUB_INDEX_FILE /
# STUB_TOMBSTONES_FILE supply payloads; unset -> exit 1 (object absent).
set -u
[[ "$1" == "copyto" ]] || { echo "rclone stub: unsupported: $*" >&2; exit 9; }
src=$2 dest=$3
case "$src" in
    */index.tar.gz)
        [[ -n "${STUB_INDEX_FILE:-}" ]] || exit 1
        cp "$STUB_INDEX_FILE" "$dest" ;;
    */tombstones.txt.gz)
        [[ -n "${STUB_TOMBSTONES_FILE:-}" ]] || exit 1
        cp "$STUB_TOMBSTONES_FILE" "$dest" ;;
    *) exit 1 ;;
esac
```

`tests/stubs/julia`:

```bash
#!/usr/bin/env bash
# julia stub for the gate's dry run: records argv to STUB_JULIA_ARGS_FILE
# (one arg per line), writes STUB_PENDING JSONL lines to the --out file.
set -u
printf '%s\n' "$@" > "${STUB_JULIA_ARGS_FILE:-/dev/null}"
out=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--out" ]] && out=$a
    prev=$a
done
[[ -n "$out" ]] || { echo "julia stub: no --out in argv" >&2; exit 9; }
n="${STUB_PENDING:-0}"
: > "$out"
for ((i = 0; i < n; i++)); do
    echo "{\"name\":\"Pkg$i\",\"status\":\"pending\"}" >> "$out"
done
```

Make them executable: `chmod +x tests/stubs/curl tests/stubs/rclone tests/stubs/julia`

- [ ] **Step 2: Create the GraphQL response fixtures**

`tests/fixtures/graphql_ok.json`:

```json
{"data":{"viewer":{"accounts":[{"r2OperationsAdaptiveGroups":[{"sum":{"requests":123456}}]}]}},"errors":null}
```

`tests/fixtures/graphql_empty.json` (no operations this month — valid zero):

```json
{"data":{"viewer":{"accounts":[{"r2OperationsAdaptiveGroups":[]}]}},"errors":null}
```

`tests/fixtures/graphql_noaccount.json` (wrong account tag — must fail):

```json
{"data":{"viewer":{"accounts":[]}},"errors":null}
```

`tests/fixtures/graphql_errors.json` (must fail):

```json
{"data":null,"errors":[{"message":"authentication error"}]}
```

- [ ] **Step 3: Write the test harness with the `query_used` tests**

`tests/test_r2_budget_gate.sh`:

```bash
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

t "query_used sums requests"            test_query_used_ok
t "query_used empty groups -> 0"        test_query_used_empty_groups_is_zero
t "query_used no account -> failure"    test_query_used_no_account_fails
t "query_used graphql errors -> failure" test_query_used_graphql_errors_fail
t "query_used curl failure -> failure"  test_query_used_curl_failure_fails

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bash tests/test_r2_budget_gate.sh`
Expected: all 5 tests FAIL (gate script does not exist yet), exit nonzero.

- [ ] **Step 5: Write the gate script with `query_used`**

`scripts/r2_budget_gate.sh`:

```bash
#!/usr/bin/env bash
#
# R2 Class A budget gate for the symbol-cache regen workflow.
#
# Decides whether a regen run fits in the R2 free tier's monthly Class A
# operation budget: queries month-to-date usage (account-wide, UTC calendar
# month) from Cloudflare's GraphQL Analytics API, computes an upper bound on
# the operations the run would consume, and reports proceed/skip.
#
#   planned = 2*P + 2*SHARDS + margin
#     P       pending versions (jwcloudindex --dry-run): 1 PutObject per
#             artifact + at most 1 ListObjects while `rclone copy` lists the
#             destination directory it copies into
#     2*S     per-shard index.tar.gz + tombstones.txt.gz uploads
#     margin  list pagination / rclone retries / analytics sampling slack
#
# Proceed iff used + planned <= budget. Fail-closed: any operational failure
# (analytics API, rclone, dry run) exits nonzero; an over-budget skip is a
# successful run with proceed=false.
#
# Required env:
#   CLOUDFLARE_ANALYTICS_TOKEN  API token with Account Analytics:Read
#   R2_ACCOUNT_ID               Cloudflare account tag
#   REMOTE                      rclone remote + bucket, e.g. r2:symbolcache
#   REGEN_MODE                  incremental | full
#   SHARDS                      sweep segment count
#   JW_DIR                      JuliaWorkspaces.jl checkout (instantiated)
#   REGISTRY                    unpacked General registry path
# Optional env:
#   SWEEP_ARGS                  filters forwarded to the dry run (default: "")
#   R2_CLASSA_BUDGET            default 1000000
#   R2_CLASSA_MARGIN            default 10000
#   WORK                        scratch dir (default: fresh mktemp)
#
# Writes proceed/used/planned/pending/budget to $GITHUB_OUTPUT and a summary
# table to $GITHUB_STEP_SUMMARY when those are set.
set -euo pipefail

# Class A operations per
# https://developers.cloudflare.com/r2/pricing/#class-a-operations
CLASS_A_ACTIONS='["ListBuckets","PutBucket","ListObjects","PutObject","CopyObject","CompleteMultipartUpload","CreateMultipartUpload","LifecycleStorageTierTransition","ListMultipartUploads","UploadPart","UploadPartCopy","ListParts","PutBucketEncryption","PutBucketCors","PutBucketLifecycleConfiguration"]'

# Month-to-date Class A operations, account-wide, UTC calendar month.
# Echoes a non-negative integer. Zero rows is a valid zero; a transport
# error, GraphQL error, unmatched account, or malformed sum is a failure.
query_used() {
    local start now payload response used
    start="$(date -u +%Y-%m-01T00:00:00Z)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    payload="$(jq -n \
        --arg account "$R2_ACCOUNT_ID" \
        --arg start "$start" \
        --arg now "$now" \
        --argjson actions "$CLASS_A_ACTIONS" \
        '{query: "query($account: string!, $start: Time!, $now: Time!, $actions: [string!]) { viewer { accounts(filter: {accountTag: $account}) { r2OperationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: $start, datetime_leq: $now, actionType_in: $actions}) { sum { requests } } } } }",
          variables: {account: $account, start: $start, now: $now, actions: $actions}}')"
    response="$(curl -fsS --max-time 60 https://api.cloudflare.com/client/v4/graphql \
        -H "Authorization: Bearer $CLOUDFLARE_ANALYTICS_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$payload")" || {
        echo "[gate] ERROR: analytics API request failed" >&2
        return 1
    }
    used="$(jq -er '
        if (.errors // []) != [] then error("graphql errors") else . end
        | .data.viewer.accounts
        | if length == 0 then error("no account matched accountTag") else . end
        | [.[0].r2OperationsAdaptiveGroups[].sum.requests] | add // 0 | round
    ' <<<"$response")" || {
        echo "[gate] ERROR: unexpected analytics response: $response" >&2
        return 1
    }
    [[ "$used" =~ ^[0-9]+$ ]] || {
        echo "[gate] ERROR: non-integer usage value: $used" >&2
        return 1
    }
    echo "$used"
}

# main is added in a later task.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "[gate] ERROR: main not implemented yet" >&2
    exit 3
fi
```

Make it executable: `chmod +x scripts/r2_budget_gate.sh`

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_r2_budget_gate.sh`
Expected: `5 passed, 0 failed`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/r2_budget_gate.sh tests/
git commit -m "feat: R2 budget gate — analytics usage query with test harness"
```

---

### Task 2: Done-set construction and pending-version count

**Files:**
- Modify: `scripts/r2_budget_gate.sh` (append functions before the `BASH_SOURCE` guard)
- Modify: `tests/test_r2_budget_gate.sh` (add tests before the final summary lines)

**Interfaces:**
- Consumes: harness helpers from Task 1 (`t`, `assert_eq`, stub env vars); `STORE_PREFIX` (exported by harness; set by sourcing `$JW_DIR/scripts/symbolcache_common.sh` in production `main`).
- Produces: `build_done_set()` — writes `$WORK/done.txt` (keys to skip), mirroring `regen_symbolcache.sh` steps 1–2: `incremental` = successes ∪ tombstones, `full` = successes only, unknown mode = failure; tolerates absent remote files. `count_pending()` — echoes the pending-version count (line count of the dry-run worklist), returns nonzero if the dry run fails.

- [ ] **Step 1: Add the failing tests**

Insert into `tests/test_r2_budget_gate.sh` before the `echo`/summary block at the end (after the last `t ... query_used ...` line):

```bash
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

t "done set: incremental unions tombstones" test_done_set_incremental_unions_tombstones
t "done set: full skips tombstones"         test_done_set_full_skips_tombstones
t "done set: tolerates absent remote files" test_done_set_tolerates_absent_remote_files
t "done set: rejects unknown mode"          test_done_set_rejects_unknown_mode

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
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `bash tests/test_r2_budget_gate.sh`
Expected: the 5 Task-1 tests pass; the 6 new tests FAIL (`build_done_set`/`count_pending` not defined). Exit nonzero.

- [ ] **Step 3: Implement `build_done_set` and `count_pending`**

Insert into `scripts/r2_budget_gate.sh` after `query_used` and before the `BASH_SOURCE` guard:

```bash
# done.txt = keys to skip, mirroring regen_symbolcache.sh steps 1-2.
# incremental: successes ∪ tombstones; full: successes only (retry tombstones).
build_done_set() {
    local pfx="$STORE_PREFIX" state="$STORE_PREFIX/_state"
    touch "$WORK/successes.txt"
    if rclone copyto "${REMOTE}/${pfx}/index.tar.gz" "$WORK/index.tar.gz" 2>/dev/null; then
        tar -xzO -f "$WORK/index.tar.gz" index.txt > "$WORK/successes.txt" || true
    else
        echo "[gate] no existing index.tar.gz (first run or empty remote)"
    fi
    touch "$WORK/tombstones.txt"
    if rclone copyto "${REMOTE}/${state}/tombstones.txt.gz" "$WORK/tombstones.txt.gz" 2>/dev/null; then
        gzip -dc "$WORK/tombstones.txt.gz" > "$WORK/tombstones.txt" || true
    else
        echo "[gate] no existing tombstones.txt.gz (first run or empty remote)"
    fi
    if [[ "$REGEN_MODE" == "incremental" ]]; then
        sort -u "$WORK/successes.txt" "$WORK/tombstones.txt" > "$WORK/done.txt"
    elif [[ "$REGEN_MODE" == "full" ]]; then
        sort -u "$WORK/successes.txt" > "$WORK/done.txt"
    else
        echo "[gate] ERROR: REGEN_MODE must be 'incremental' or 'full', got '$REGEN_MODE'" >&2
        return 1
    fi
}

# Exact pending-version count for the whole run: dry-run worklist size over
# the full version set (deliberately no --shard — the gate bounds the sum of
# all segments).
count_pending() {
    # SWEEP_ARGS is intentionally word-split, same as the regen job's usage.
    # shellcheck disable=SC2086
    julia --project="$JW_DIR" \
        -e 'using JuliaWorkspaces; exit(JuliaWorkspaces.CloudIndexApp.cli_main(ARGS))' -- \
        --dry-run --registry "$REGISTRY" --done-set "$WORK/done.txt" \
        --out "$WORK/worklist.jsonl" ${SWEEP_ARGS:-} >&2 || {
        echo "[gate] ERROR: dry-run enumeration failed" >&2
        return 1
    }
    wc -l < "$WORK/worklist.jsonl" | tr -d ' '
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_r2_budget_gate.sh`
Expected: `11 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/r2_budget_gate.sh tests/test_r2_budget_gate.sh
git commit -m "feat: R2 budget gate — done-set build and pending count"
```

---

### Task 3: Decision, reporting, and `main`

**Files:**
- Modify: `scripts/r2_budget_gate.sh` (add `decide_and_report` + `main`, replace the placeholder `BASH_SOURCE` guard body)
- Modify: `tests/test_r2_budget_gate.sh` (add tests before the final summary lines)

**Interfaces:**
- Consumes: `query_used`, `build_done_set`, `count_pending` from Tasks 1–2; the `make_remote_fixtures` test helper defined in Task 2's test additions (it must remain above these tests in the file).
- Produces: `decide_and_report USED PENDING` — computes `planned = 2*PENDING + 2*SHARDS + margin`, writes `proceed`/`used`/`planned`/`pending`/`budget` lines to `$GITHUB_OUTPUT` (when set), a markdown table to `$GITHUB_STEP_SUMMARY` (when set), and a `::warning` annotation on skip. `main` — validates env, sources `$JW_DIR/scripts/symbolcache_common.sh` for `STORE_PREFIX`, chains the functions. Running the script (not sourcing) invokes `main`. Task 4 relies on the exact `$GITHUB_OUTPUT` keys `proceed`, `used`, `planned`, `pending`, `budget`.

- [ ] **Step 1: Add the failing tests**

Insert into `tests/test_r2_budget_gate.sh` before the final summary block:

```bash
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
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `bash tests/test_r2_budget_gate.sh`
Expected: 11 existing tests pass, 9 new tests FAIL. Exit nonzero.

- [ ] **Step 3: Implement `decide_and_report` and `main`**

In `scripts/r2_budget_gate.sh`, insert after `count_pending`:

```bash
# Compute the decision and report it to the log, $GITHUB_OUTPUT and
# $GITHUB_STEP_SUMMARY (each only when set).
decide_and_report() {
    local used=$1 pending=$2
    local budget margin planned proceed
    budget="${R2_CLASSA_BUDGET:-1000000}"
    margin="${R2_CLASSA_MARGIN:-10000}"
    planned=$((2 * pending + 2 * SHARDS + margin))
    if (( used + planned <= budget )); then
        proceed=true
    else
        proceed=false
    fi

    echo "[gate] used=$used planned=$planned (pending=$pending shards=$SHARDS margin=$margin) budget=$budget proceed=$proceed"
    if [[ "$proceed" == false ]]; then
        echo "::warning title=R2 Class A budget gate::Skipping regen: month-to-date Class A ops ($used) + planned upper bound ($planned) exceed budget ($budget)."
    fi
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "proceed=$proceed"
            echo "used=$used"
            echo "planned=$planned"
            echo "pending=$pending"
            echo "budget=$budget"
        } >> "$GITHUB_OUTPUT"
    fi
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo "### R2 Class A budget gate"
            echo ""
            echo "| used (month-to-date) | planned (upper bound) | budget | pending versions | proceed |"
            echo "| ---: | ---: | ---: | ---: | :--- |"
            echo "| $used | $planned | $budget | $pending | $proceed |"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
}

main() {
    : "${CLOUDFLARE_ANALYTICS_TOKEN:?}" "${R2_ACCOUNT_ID:?}" "${REMOTE:?}" \
      "${REGEN_MODE:?}" "${SHARDS:?}" "${JW_DIR:?}" "${REGISTRY:?}"
    [[ "$SHARDS" =~ ^[0-9]+$ ]] || {
        echo "[gate] ERROR: SHARDS must be an integer, got '$SHARDS'" >&2
        exit 2
    }
    WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/r2_budget_gate.XXXXXX")}"
    mkdir -p "$WORK"
    # shellcheck disable=SC1091
    source "$JW_DIR/scripts/symbolcache_common.sh"   # provides STORE_PREFIX

    local used pending
    used="$(query_used)"
    echo "[gate] month-to-date Class A ops (account-wide): $used"
    build_done_set
    echo "[gate] done.txt has $(wc -l < "$WORK/done.txt") entries (mode=$REGEN_MODE)"
    pending="$(count_pending)"
    echo "[gate] pending versions this run: $pending"
    decide_and_report "$used" "$pending"
}
```

And replace the placeholder guard at the bottom:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_r2_budget_gate.sh`
Expected: `20 passed, 0 failed`, exit 0.

- [ ] **Step 5: Shellcheck both scripts**

Run: `shellcheck scripts/r2_budget_gate.sh tests/test_r2_budget_gate.sh`
Expected: no output, exit 0. (If shellcheck is not installed: `sudo pacman -S shellcheck` on this machine, or note it and rely on CI review.) Fix any findings; the two intentional suppressions (`SC2086` on `$SWEEP_ARGS`, `SC1091` on the sourced common file) are already inline.

- [ ] **Step 6: Commit**

```bash
git add scripts/r2_budget_gate.sh tests/test_r2_budget_gate.sh
git commit -m "feat: R2 budget gate — decision, reporting, and main"
```

---

### Task 4: Workflow wiring and docs

**Files:**
- Modify: `.github/workflows/regen-symbolcache.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `scripts/r2_budget_gate.sh` CLI contract from Tasks 1–3 (env vars in, `$GITHUB_OUTPUT` keys `proceed`/`used`/`planned`/`pending`/`budget` out, exit 0 on both proceed and skip, nonzero on operational failure).
- Produces: `needs.plan.outputs.proceed` consumed by the `regen` job's `if:`.

- [ ] **Step 1: Extend the `plan` job**

In `.github/workflows/regen-symbolcache.yml`, replace the entire `plan:` job with:

```yaml
  plan:
    # Setup + budget gate. Expands the `shards` count into the JSON list the
    # matrix below needs (workflow expressions can't generate ranges), and
    # runs scripts/r2_budget_gate.sh: regen only starts when month-to-date R2
    # Class A ops + this run's upper bound fit in the free-tier budget.
    # Fail-closed — if the gate can't determine usage, this job fails and
    # regen never runs.
    runs-on:
      group: cloudindexer-self-hosted-32vcpu-64gb
    timeout-minutes: 30
    env:
      SHARDS: ${{ inputs.shards || '10' }}
      JW_REF: main
      R2_BUCKET: ${{ vars.R2_BUCKET || 'symbolcache' }}
      REGEN_MODE: ${{ inputs.mode || 'incremental' }}
      SWEEP_ARGS: ${{ inputs.sweep_args || '--newest 3' }}
      R2_CLASSA_BUDGET: ${{ vars.R2_CLASSA_BUDGET || '1000000' }}
      R2_CLASSA_MARGIN: ${{ vars.R2_CLASSA_MARGIN || '10000' }}
      CLOUDFLARE_ANALYTICS_TOKEN: ${{ secrets.CLOUDFLARE_ANALYTICS_TOKEN }}
      R2_ACCOUNT_ID: ${{ secrets.R2_ACCOUNT_ID }}
      # Same env-var-defined rclone remote as the regen job (the gate
      # downloads index.tar.gz + tombstones.txt.gz to build its done set).
      RCLONE_CONFIG_R2_TYPE: s3
      RCLONE_CONFIG_R2_PROVIDER: Cloudflare
      RCLONE_CONFIG_R2_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
      RCLONE_CONFIG_R2_ENDPOINT: https://${{ secrets.R2_ACCOUNT_ID }}.r2.cloudflarestorage.com
      RCLONE_CONFIG_R2_REGION: auto
      RCLONE_CONFIG_R2_NO_CHECK_BUCKET: "true"
      RCLONE_CONFIG_R2_ACL: private
    outputs:
      list: ${{ steps.gen.outputs.list }}
      total: ${{ steps.gen.outputs.total }}
      proceed: ${{ steps.gate.outputs.proceed }}
      used: ${{ steps.gate.outputs.used }}
      planned: ${{ steps.gate.outputs.planned }}
      pending: ${{ steps.gate.outputs.pending }}
    steps:
      - name: Generate shard list
        id: gen
        run: |
          set -euo pipefail
          if ! [[ "$SHARDS" =~ ^[0-9]+$ ]] || (( SHARDS < 1 || SHARDS > 64 )); then
            echo "Invalid shards count '$SHARDS' (need an integer in 1..64)" >&2
            exit 1
          fi
          echo "total=$SHARDS" >> "$GITHUB_OUTPUT"
          echo "list=[$(seq -s, 0 $((SHARDS - 1)))]" >> "$GITHUB_OUTPUT"
          echo "Sweeping in $SHARDS sequential segments"

      - name: Check out cloudindexer
        uses: actions/checkout@v4

      - name: Verify gate credentials are set
        run: |
          set -euo pipefail
          if [[ -z "${CLOUDFLARE_ANALYTICS_TOKEN:-}" || -z "${R2_ACCOUNT_ID:-}" ]]; then
            echo "Missing gate secrets (CLOUDFLARE_ANALYTICS_TOKEN / R2_ACCOUNT_ID)" >&2
            exit 1
          fi

      - name: Clone latest JuliaWorkspaces.jl
        run: |
          set -euo pipefail
          rm -rf JuliaWorkspaces.jl
          git clone --depth 1 --branch "$JW_REF" \
            https://github.com/julia-vscode/JuliaWorkspaces.jl.git JuliaWorkspaces.jl
          echo "JW_DIR=$PWD/JuliaWorkspaces.jl" >> "$GITHUB_ENV"

      - name: Set up Julia
        uses: julia-actions/setup-julia@v3
        with:
          # Matches the checked-in Manifest (julia_version = 1.12.5).
          version: "1.12"

      - name: Install rclone and jq
        run: |
          set -euo pipefail
          # Don't use rclone from apt: Ubuntu LTS pins old builds (24.04 ships
          # 1.60.1 from 2022) that predate most of rclone's Cloudflare R2
          # compatibility work, and every upload fails with "501
          # NotImplemented". Install the current stable release instead.
          export DEBIAN_FRONTEND=noninteractive
          sudo apt-get update -qq
          sudo apt-get install -y --no-install-recommends jq curl unzip
          curl -fsSL https://rclone.org/install.sh | sudo bash
          rclone version
          jq --version

      - name: Instantiate package project
        run: |
          set -euo pipefail
          julia --project="$JW_DIR" -e 'using Pkg; Pkg.instantiate()'

      - name: Download General registry
        run: |
          set -euo pipefail
          # Unpacked so RegistryInstance can read it directly (same pattern as
          # run_cloudindex_docker.sh). Trailing ':' appends the default depots
          # so Pkg itself doesn't recompile from scratch.
          REGDEPOT="$RUNNER_TEMP/regdepot"
          mkdir -p "$REGDEPOT"
          JULIA_DEPOT_PATH="$REGDEPOT:" JULIA_PKG_UNPACK_REGISTRY=true \
            julia --startup-file=no -e 'using Pkg; Pkg.Registry.add("General")'
          test -f "$REGDEPOT/registries/General/Registry.toml"
          echo "REGISTRY=$REGDEPOT/registries/General" >> "$GITHUB_ENV"

      - name: R2 Class A budget gate
        id: gate
        run: |
          set -euo pipefail
          REMOTE="r2:$R2_BUCKET" bash scripts/r2_budget_gate.sh
```

- [ ] **Step 2: Gate the `regen` job**

In the `regen:` job, add an `if:` line directly under `needs: plan`:

```yaml
  regen:
    needs: plan
    # Skipped (not failed) when the budget gate says the run wouldn't fit in
    # the R2 free tier's monthly Class A allowance.
    if: needs.plan.outputs.proceed == 'true'
```

Also update the workflow's top-of-file comment block: after the paragraph about segments, add:

```yaml
# Before anything runs, a budget gate (scripts/r2_budget_gate.sh, in the plan
# job) checks that month-to-date R2 Class A operations plus this run's upper
# bound fit in the free tier's 1M/month allowance; if not, the regen jobs are
# skipped. Requires the CLOUDFLARE_ANALYTICS_TOKEN secret (Account
# Analytics:Read).
```

- [ ] **Step 3: Validate the workflow YAML**

Run: `actionlint .github/workflows/regen-symbolcache.yml` if available; otherwise `python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/regen-symbolcache.yml')); print('YAML OK')"`.
Expected: no errors / `YAML OK`. (If neither tool is available, install actionlint or rely on a syntax check when the workflow is pushed — GitHub rejects invalid workflow files at push time.)

Also re-run the gate tests to confirm nothing regressed: `bash tests/test_r2_budget_gate.sh` → `20 passed, 0 failed`.

- [ ] **Step 4: Document the gate in the README**

Append to `README.md`:

```markdown
## R2 Class A budget gate

The workflow only starts a regen when it fits in the R2 free tier's monthly
Class A allowance. Before the sweep, `scripts/r2_budget_gate.sh` (run in the
`plan` job) queries month-to-date account-wide Class A operations from the
Cloudflare GraphQL Analytics API and computes an upper bound for the run
(`2 * pending versions + 2 * shards + margin`). If `used + planned` exceeds
the budget, the regen jobs are skipped (shown as *skipped*, with a warning
annotation and a step-summary table). The gate is fail-closed: if usage can't
be determined, the run doesn't start.

Configuration:

- Secret `CLOUDFLARE_ANALYTICS_TOKEN` (required): Cloudflare API token with
  *Account Analytics: Read* for the account holding the bucket.
- Repo variable `R2_CLASSA_BUDGET` (optional, default `1000000`): total
  monthly budget; set lower for standing headroom.
- Repo variable `R2_CLASSA_MARGIN` (optional, default `10000`): fixed slack
  for list pagination, retries, and analytics sampling error.

Tests: `bash tests/test_r2_budget_gate.sh` (stubs curl/rclone/julia; needs jq).
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/regen-symbolcache.yml README.md
git commit -m "ci: gate regen on R2 Class A budget"
```

- [ ] **Step 6: Manual follow-ups (user actions — surface these at handoff)**

Not automatable from this repo; list them in the final report:

1. Create a Cloudflare API token scoped to *Account Analytics: Read* and add it as the `CLOUDFLARE_ANALYTICS_TOKEN` repo secret.
2. Optionally run the gate script locally against the real API to validate the GraphQL query end-to-end before the next scheduled run:

```bash
export CLOUDFLARE_ANALYTICS_TOKEN=...   # the new token
export R2_ACCOUNT_ID=...                # same value as the repo secret
export REMOTE=r2:symbolcache REGEN_MODE=incremental SHARDS=10
export SWEEP_ARGS="--newest 3"
export JW_DIR=/path/to/JuliaWorkspaces.jl   # instantiated checkout
export REGISTRY=/path/to/depot/registries/General
# rclone remote "r2" must be configured locally (RCLONE_CONFIG_R2_* or config file)
bash scripts/r2_budget_gate.sh
```

3. Trigger one manual `workflow_dispatch` run and check the step summary table.
