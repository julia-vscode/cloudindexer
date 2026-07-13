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
        | [.[0].r2OperationsAdaptiveGroups[].sum.requests] as $reqs
        | if ($reqs | all(type == "number")) then ($reqs | add // 0 | round) else error("malformed group: non-numeric sum.requests") end
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
