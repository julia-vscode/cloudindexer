# Self-hosted runner for symbol-cache regeneration

The [`Regenerate symbol cache`](../.github/workflows/regen-symbolcache.yml)
workflow runs daily on a **self-hosted** GitHub Actions runner. It clones the
latest `julia-vscode/JuliaWorkspaces.jl` and runs its
`scripts/regen_symbolcache.sh` against the Cloudflare R2 bucket.

The workflow targets the org-wide self-hosted runner group
**`cloudindexer-self-hosted-32vcpu-64gb`** (via `runs-on: { group: ... }`).

## Why self-hosted

The sweep (`run_cloudindex_docker.sh`) runs one Docker container per
package/version worker (`julia:1.12`), with cgroup CPU/memory limits and a
shared read-only General registry. That needs a persistent host with Docker and
enough CPU/RAM/disk, which the GitHub-hosted runners don't provide.

## Host prerequisites

The workflow installs `rclone` and `jq` via `apt-get`, so those do **not** need
to be preinstalled. Everything else must be present:

| Requirement | Notes |
| --- | --- |
| Ubuntu / Debian | The install step uses `apt-get`. rclone from apt must be **>= 1.59** for `provider = Cloudflare` (Ubuntu 24.04 / Debian 12 are fine; Ubuntu 22.04 / Debian 11 ship 1.53 — install a newer rclone via `curl https://rclone.org/install.sh \| sudo bash` in that case). |
| Passwordless `sudo` | The runner user needs `sudo` for `apt-get install`, or preinstall `rclone` + `jq` and drop that step. |
| Docker daemon | The runner user must be in the `docker` group (`sudo usermod -aG docker <user>`), or the sweep must be invokable via sudo. Workers run as `julia:1.12` containers. |
| `git`, `curl` | For cloning the repo. Standard on Linux. |
| `gzip`, `tar` | Used by the regen script. Standard on Linux. |
| Disk space | The Julia depot, General registry, and per-worker stores are sizable. Budget tens of GB of free space under the runner's work dir and `/tmp`. |

`julia` is provided per-run by `julia-actions/setup-julia` (pinned to 1.12,
matching the JuliaWorkspaces Manifest), so juliaup on the host is optional.

## Runner group

The workflow uses the org-wide runner group
`cloudindexer-self-hosted-32vcpu-64gb`, so no per-repo runner registration is
needed. The remaining setup is granting access:

1. In the org: **Settings → Actions → Runner groups →
   `cloudindexer-self-hosted-32vcpu-64gb`**, ensure the `cloudindexer`
   repository is in the group's list of allowed repositories.
2. Confirm the runners in the group satisfy the host prerequisites above
   (Docker daemon reachable — `docker run --rm hello-world`, passwordless
   `sudo`, disk space).

## Required secrets

Set these repository secrets (**Settings → Secrets and variables → Actions**):

| Secret | Description |
| --- | --- |
| `R2_ACCESS_KEY_ID` | R2 access key ID. |
| `R2_SECRET_ACCESS_KEY` | R2 secret access key. |
| `R2_ACCOUNT_ID` | Cloudflare account ID; used to build the S3 endpoint `https://<account>.r2.cloudflarestorage.com`. |

The workflow does not write an rclone config file. The regen scripts assume the
`r2:` remote already exists, so the workflow defines it through
`RCLONE_CONFIG_R2_*` environment variables (rclone reads
`RCLONE_CONFIG_<NAME>_<KEY>` to construct a remote), keeping the secrets out of
any on-disk config.

Optional repository **variable**:

| Variable | Default | Description |
| --- | --- | --- |
| `R2_BUCKET` | `symbolcache` | R2 bucket name; the rclone remote passed to the script is `r2:<R2_BUCKET>`. |

## Schedule and manual runs

- **Scheduled:** daily at 03:00 UTC, `--mode incremental` with sweep args
  `--newest 3 --jobs 12` (12 parallel workers sized for the 32-vCPU / 64-GB
  runner; each worker container is capped at 2 vCPU / 4 GB).
- **Manual:** use **Run workflow** (`workflow_dispatch`) to override `mode`
  (`incremental` / `full`) and `sweep_args` — e.g. `--newest 3 --per-break` for
  a heavier sweep, or a wider `--include` pattern.

Runs are serialized by an Actions `concurrency` group (`regen-symbolcache`), so
a new run never overlaps one already in progress.
