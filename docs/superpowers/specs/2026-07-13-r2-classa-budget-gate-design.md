# R2 Class A Budget Gate — Design

**Date:** 2026-07-13
**Status:** Approved

## Problem

The R2 bucket the daily symbol-cache regen uploads to is on Cloudflare's free
tier: 1,000,000 Class A operations per account per month. The workflow must
never start a run that could push the account over that limit. Today nothing
checks usage; a busy month (or a `full` regen) could breach it silently.

## Decision summary

Before any regen job starts, a gate computes month-to-date Class A usage plus
an exact upper bound on the operations the run would consume, and skips the
whole run if the sum exceeds the budget. The gate is fail-closed: if usage
cannot be determined, the run is skipped.

## Budget formula

Proceed iff:

```
used + planned <= budget
```

- **budget** — `R2_CLASSA_BUDGET` repo variable, default `1000000`. Set lower
  (e.g. `950000`) for standing headroom.
- **used** — month-to-date Class A operations, **account-wide** (the free tier
  is per account, not per bucket), for the current **calendar month in UTC**.
  Queried from the Cloudflare GraphQL Analytics API
  (`r2OperationsAdaptiveGroups`), filtered to the documented Class A action
  types (`PutObject`, `ListObjects`, `CopyObject`, `CreateMultipartUpload`,
  `UploadPart`, `UploadPartCopy`, `CompleteMultipartUpload`,
  `ListMultipartUploads`, `ListParts`, `PutBucket`, `ListBuckets`,
  `PutBucketEncryption`, `PutBucketCors`, `PutBucketLifecycleConfiguration`,
  `LifecycleStorageTierTransition`), summing `sum { requests }`.
- **planned** — exact upper bound for the whole run:

  ```
  planned = 2*P + 2*S + margin
  ```

  - `P` — pending version count from
    `jwcloudindex --dry-run --done-set done.txt <sweep args>` run over the full
    version set (no `--shard` split, same filters as the sweep, e.g.
    `--newest 3`). Each pending version costs at most 1 `PutObject` (artifacts
    are far below rclone's 200 MB multipart cutoff, so always a single PUT)
    plus at most 1 `ListObjects` when `rclone copy` lists the destination
    directory it is copying into — hence `2*P`.
  - `2*S` — per-shard fixed cost: each of the `S` sequential shard jobs
    uploads `index.tar.gz` and `tombstones.txt.gz` once (2 PUTs). Downloads
    (`GetObject`/`HeadObject`) are Class B and do not count.
  - `margin` — fixed buffer, default **10,000**, covering `ListObjects`
    pagination, rclone retries, and analytics sampling error. Overridable via
    the `R2_CLASSA_MARGIN` repo variable.

## Architecture

### Gate script: `scripts/r2_budget_gate.sh` (this repo)

A standalone bash script so the logic is locally testable and shellcheckable.
Inputs via environment variables:

| Variable | Meaning |
| --- | --- |
| `CLOUDFLARE_ANALYTICS_TOKEN` | API token, *Account Analytics: Read* scope |
| `R2_ACCOUNT_ID` | Cloudflare account tag (existing secret) |
| `REMOTE` | rclone remote + bucket (e.g. `r2:symbolcache`) |
| `REGEN_MODE` | `incremental` \| `full` — controls done.txt construction |
| `SWEEP_ARGS` | filters forwarded to the dry run (e.g. `--newest 3`) |
| `SHARDS` | shard count `S` |
| `JW_DIR` | path to a JuliaWorkspaces.jl checkout (project instantiated) |
| `REGISTRY` | path to an unpacked General registry |
| `R2_CLASSA_BUDGET` | budget, default 1000000 |
| `R2_CLASSA_MARGIN` | margin, default 10000 |

Steps:

1. **Query used:** `curl` the GraphQL endpoint; validate with `jq` that
   `errors` is empty/null and the sum parses as a non-negative integer.
   Anything else → nonzero exit (fail-closed).
2. **Build done.txt:** download `index.tar.gz` and `tombstones.txt.gz` from
   the bucket with `rclone copyto` (Class B; rclone exit 3/4 = absent,
   tolerated as first run; any other failure is fatal). `incremental` → successes ∪ tombstones;
   `full` → successes only.
3. **Count P:** run `jwcloudindex --dry-run --registry $REGISTRY
   --done-set done.txt $SWEEP_ARGS --out worklist.jsonl`; `P` = line count of
   the worklist.
4. **Decide:** compute `planned`, compare, and emit to `$GITHUB_OUTPUT`
   (`proceed`, `used`, `planned`, `pending`, `budget`) and a markdown table to
   `$GITHUB_STEP_SUMMARY`. On skip, print a `::warning` annotation. Exit 0 in
   both cases (skip is not an error); exit nonzero only on operational
   failure.

### Workflow changes: `.github/workflows/regen-symbolcache.yml`

The existing `plan` job grows the gate (it already gates `regen` via `needs`):

- Setup steps mirroring the regen job: clone JuliaWorkspaces.jl,
  `setup-julia`, install rclone + jq, instantiate the project, download the
  General registry (`JULIA_PKG_UNPACK_REGISTRY=true julia -e
  'using Pkg; Pkg.Registry.add("General")'` into a scratch depot, as
  `run_cloudindex_docker.sh` does).
- Checkout of this repo (currently `plan` has no checkout) to get the gate
  script.
- Run `scripts/r2_budget_gate.sh`; expose its outputs as job outputs.
- Timeout raised 15 → 30 minutes.

The `regen` job gains:

```yaml
if: needs.plan.outputs.proceed == 'true'
```

A skipped run therefore shows as *skipped* (no red X on scheduled runs), with
the warning annotation and step summary explaining why. There is **no
bypass/force input**: scheduled and manual runs alike go through the gate.

## Error handling

- Any gate failure (GraphQL error, expired token, malformed response, rclone
  or dry-run failure) fails the `plan` job → `regen` never runs. Fail-closed
  by construction.
- The GraphQL response is strictly validated; a missing/NaN sum is treated as
  failure, never as zero usage.

## Known caveats

- `r2OperationsAdaptiveGroups` uses adaptive sampling at high volumes, so
  `used` is a scaled, unbiased estimate rather than an exact count. The
  10,000 margin (plus optional budget headroom) absorbs this.
- The free-tier month is assumed to be the UTC calendar month. If Cloudflare
  bills on a different cycle anchor, the gate is conservative early in the
  calendar month and lenient late — acceptable at current usage levels.
- `used` is account-wide, so other consumers of the same Cloudflare account
  correctly count against the budget.

## New credentials

One new repo secret: `CLOUDFLARE_ANALYTICS_TOKEN` — Cloudflare API token
scoped to *Account Analytics: Read* for the account holding the bucket. The
existing R2 S3 keys cannot query analytics.

## Testing

- Run the gate script locally against the real analytics API with a token to
  validate the query and jq parsing.
- Exercise the arithmetic and exit codes locally with stubbed inputs (small
  fake registry / done set, overridden budget) — verify proceed, skip, and
  fail-closed paths.
- `shellcheck scripts/r2_budget_gate.sh`.
- One manual `workflow_dispatch` run to validate wiring end-to-end.
