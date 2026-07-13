# cloudindexer for LanguageServer.jl

Daily runs of the JuliaWorkspaces.jl based registry indexer. It creates cache files for every new
package version registered into General and pushes them into an R2 bucket for general availability.

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
