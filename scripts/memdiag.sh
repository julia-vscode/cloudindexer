#!/usr/bin/env bash
# Memory diagnostics monitor for the symbol-cache regen job.
#
# Started in the background by the regen step so its output interleaves with
# that step's live log — GitHub retains streamed lines even when the runner
# pod is killed mid-step, so the snapshots leading up to a termination
# survive. What to look for after a run dies (see docs/self-hosted-runner.md):
#
#   - "received SIGTERM" from the regen step's trap -> graceful external
#     termination (kubelet eviction, node drain, pod deletion, cancellation);
#     check whether node_avail was collapsing (eviction) or healthy (infra
#     churn) in the preceding snapshots.
#   - log stops mid-line, no trap message, node_avail near zero -> node-level
#     kernel OOM kill (SIGKILL, untrappable).
#   - cg_oom_kills incrementing -> pod-cgroup OOM kills (under DinD all
#     workers are charged to the pod's cgroup, so per-worker 4g caps can hold
#     while the sum blows the pod limit).
#
# The script is observe-only. (An oom_score_adj policy protecting the
# orchestrator was tried and removed: the runner pod is Burstable QoS without
# CAP_SYS_RESOURCE, so kubelet pins oom_score_adj and lowering always fails.)

set -u

INTERVAL="${MEMDIAG_INTERVAL:-60}"
DETAIL_EVERY="${MEMDIAG_DETAIL_EVERY:-10}"

log() { echo "[memdiag] $*"; }

# Read a memory-cgroup file, trying the v2 name then the v1 name.
cg_read() {
  cat "/sys/fs/cgroup/$1" 2>/dev/null \
    || { [[ -n "${2:-}" ]] && cat "/sys/fs/cgroup/memory/$2" 2>/dev/null; } \
    || echo "n/a"
}

# Bytes to GiB; "max" (cgroup v2) and ~2^63 (v1) both mean no limit.
gib() {
  awk -v b="${1:-}" 'BEGIN {
    if (b != b+0) printf "%s", b
    else if (b+0 >= 2^60) printf "unlimited"
    else printf "%.1fGi", b/1073741824
  }'
}

snapshot_line() {
  local avail_kb cur max ooms workers psi
  avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  cur="$(cg_read memory.current memory.usage_in_bytes)"
  max="$(cg_read memory.max memory.limit_in_bytes)"
  ooms="$(cg_read memory.events | awk '/^oom_kill / {print $2}')"
  workers="$(docker ps -q 2>/dev/null | wc -l)"
  psi="$(cg_read memory.pressure | awk '/^some/ {for (i=1;i<=NF;i++) if ($i ~ /^avg60=/) print substr($i,7)}')"
  log "$(date -u +%FT%TZ) node_avail=$(gib $((avail_kb * 1024))) cg_used=$(gib "$cur")/$(gib "$max") cg_oom_kills=${ooms:-n/a} workers=$workers mem_psi_some_avg60=${psi:-n/a}"
}

snapshot_detail() {
  log "--- detail $(date -u +%FT%TZ) ---"
  log "cgroup memory.events: $(cg_read memory.events | tr '\n' ' ')"
  log "top-rss (pid rss_kb oom_score_adj oom_score comm):"
  ps -eo pid=,rss=,comm= --sort=-rss | head -8 | while read -r pid rss comm; do
    log "  $pid $rss $(cat "/proc/$pid/oom_score_adj" 2>/dev/null || echo '?') $(cat "/proc/$pid/oom_score" 2>/dev/null || echo '?') $comm"
  done
  timeout 25 docker stats --no-stream --format 'worker {{.Name}} mem={{.MemUsage}} cpu={{.CPUPerc}}' 2>/dev/null \
    | while read -r line; do log "  $line"; done
  if [[ "$DMESG_OK" == yes ]]; then
    dmesg 2>/dev/null | grep -iE 'invoked oom-killer|oom-kill:|Out of memory' | tail -3 \
      | while read -r line; do log "  kernel: $line"; done
  fi
}

if dmesg >/dev/null 2>&1; then DMESG_OK=yes; else DMESG_OK=no; fi

log "started (pid $$, interval ${INTERVAL}s, detail every $DETAIL_EVERY ticks)"
log "cgroup membership: $(tr '\n' ' ' </proc/self/cgroup 2>/dev/null)"
log "container memory.max: $(gib "$(cg_read memory.max memory.limit_in_bytes)")"
log "dmesg readable from pod: $DMESG_OK"

tick=0
while :; do
  snapshot_line
  if ((tick % DETAIL_EVERY == 0)); then
    snapshot_detail
  fi
  tick=$((tick + 1))
  sleep "$INTERVAL"
done
