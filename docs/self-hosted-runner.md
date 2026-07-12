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

## Concurrency and container resource limits

The sweep runs each package/version in its own Docker worker, capped at
`--cpus=2 --memory=4g`. On the 32-vCPU / 64-GB runner that fits ~16 workers, so
the default worker count (`JOBS`) is 12, leaving headroom for the host + driver.

Those `docker run` limits are only enforced under specific conditions. In
particular, **rootless Docker and Docker-in-Docker** apply cgroup limits only
with cgroup v2, the systemd cgroup driver, and the relevant controllers
delegated to the daemon's cgroup; otherwise `--memory` is silently ignored. If
the memory cap doesn't bind, 12 unbounded workers can exhaust the host's 64 GB
and trigger OOM kills (surfacing as failed/tombstoned versions).

To guard against that, the **Preflight** step launches a canary container with
`--memory=64m` and reads back the effective limit. If it isn't enforced, the
step emits a warning and **caps `JOBS` at 8** for that run. Check the
`docker info` output in that step if you want to fix the underlying delegation
so full concurrency is available.

The fallback cap used to be 2, when an unenforced `--memory` meant truly
unbounded workers. Workers now always get `JULIA_HEAP_SIZE_HINT=3G` (forwarded
by the launcher), which keeps each worker's GC targeting ~3 GiB regardless of
whether docker's cap binds — so even the fallback case stays within roughly
`JOBS × 4 GiB` of real usage, and a moderate cap suffices. The hint is a GC
target, not a hard limit (native allocations from binary deps aren't covered),
which is why the fallback still stays below the full default.

## Termination diagnostics

Runs have died with GitHub's "runner lost communication" annotation — the
runner pod (on Kubernetes) was terminated from outside. There are three
distinct mechanisms, each with a different fingerprint in the regen step's
live log (GitHub retains streamed lines even when the pod dies mid-step):

| Mechanism | Signal | Fingerprint in the log |
| --- | --- | --- |
| kubelet node-pressure eviction | SIGTERM, then SIGKILL | "received SIGTERM" from the regen step's trap, with `node_avail` collapsing in the preceding `[memdiag]` snapshots |
| node drain / scale-down / pod deletion | SIGTERM, then SIGKILL | "received SIGTERM" but `node_avail` healthy — memory wasn't the trigger |
| kernel OOM kill (node- or pod-cgroup-level) | SIGKILL only | log stops abruptly, no trap message; `cg_oom_kills` incrementing means pod-cgroup kills, `node_avail` near zero means node-level; dmesg lines (if readable) show `CONSTRAINT_MEMCG` vs `CONSTRAINT_NONE` |

`scripts/memdiag.sh` runs in the background *inside* the regen step, sharing
its stdout, and prints a compact snapshot every 60 s (node `MemAvailable`,
pod-cgroup usage/limit, cgroup `oom_kill` counter, worker count, memory PSI)
plus a detail block every 10 min (top-RSS processes with OOM scores, per-worker
`docker stats`). A `Collect memory diagnostics` step dumps `memory.events` and
kernel OOM lines whenever the runner survives to the end.

The monitor is observe-only. An OOM-score policy that protected the
orchestrator (runner agent, `dockerd`, driver) by lowering their
`oom_score_adj` was tried and removed: the runner pod is Burstable QoS, so
kubelet pins `oom_score_adj` (873 observed) and lowering it requires
`CAP_SYS_RESOURCE`, which the pod doesn't have — every write failed.

Under DinD the workers' memory is charged to the *pod's* cgroup, so per-worker
`--memory=4g` caps can each pass the preflight canary while the sum blows the
pod limit. The regen step checks `JOBS × 4 GiB + 4 GiB` overhead against the
visible cgroup limit and emits a workflow warning when the budget doesn't fit.

## Sharded segments

The regen script only uploads (artifacts, index, tombstones) after a fully
completed sweep, and runner pods have been reaped from outside mid-run
(recycling / node drain, observed 5–11 h in) — which used to throw away an
entire night's progress. The workflow therefore splits each run into
sequential segments: a `plan` job expands the `shards` input (default 10) into
a matrix, and each matrix job sweeps one slice (`jwcloudindex --shard k/n`, a
deterministic hash partition of the version set) and uploads its results
before the next segment starts. A reaped pod now costs at most one segment,
and `fail-fast: false` lets the remaining segments proceed — the failed slice
is picked up again by the next incremental run.

Segments run strictly sequentially (`max-parallel: 1`): the regen script
assumes single-flight bucket access, and each segment downloads an index that
already contains the previous segments' uploads. This is safe in `full` mode
too — the script always merges new results into the downloaded index (`full`
only additionally retries tombstoned versions), so a segment never clobbers
other segments' entries. Each segment pays the fixed setup overhead (JW clone,
`Pkg.instantiate`, index download/upload, ~10 min), so don't raise the shard
count far beyond what keeps segments around an hour or two.

## Schedule and manual runs

- **Scheduled:** daily at 03:00 UTC, `--mode incremental`, `JOBS=12`, sweep args
  `--newest 3` (subject to the preflight cap above), 10 shards.
- **Manual:** use **Run workflow** (`workflow_dispatch`) to override `mode`
  (`incremental` / `full`), `jobs` (worker count), `shards` (segment count),
  and `sweep_args` — e.g. `--newest 3 --per-break` for a heavier sweep, or a
  wider `--include` pattern.

Runs are serialized by an Actions `concurrency` group (`regen-symbolcache`), so
a new run never overlaps one already in progress; segments within a run are
serialized by the matrix's `max-parallel: 1`.
