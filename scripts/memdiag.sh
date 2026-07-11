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
# Each tick also (re)applies an oom_score_adj policy so that when the kernel
# does have to kill something, it prefers sweep workers over the orchestrator:
#
#   runner agent / dockerd / containerd -> -900
#   regen driver (script + host julia)  -> -400
#   worker containers (DinD julia)      -> +500
#
# Lowering oom_score_adj needs CAP_SYS_RESOURCE (usually present since DinD
# pods run privileged); if unavailable that's logged once and only the
# worker-raising half applies. None of this helps against kubelet eviction,
# which selects whole pods and ignores OOM scores.
#
# The policy mutates system state, so it only runs when the caller sets
# MEMDIAG_APPLY_OOM_POLICY=1 (the workflow does); anywhere else the script is
# observe-only and safe to run.

set -u

INTERVAL="${MEMDIAG_INTERVAL:-60}"
DETAIL_EVERY="${MEMDIAG_DETAIL_EVERY:-10}"
APPLY_POLICY="${MEMDIAG_APPLY_OOM_POLICY:-0}"

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

# set_adj PID VALUE LABEL — idempotent, logs only changes and failures.
set_adj() {
  local pid="$1" val="$2" label="$3" cur
  cur="$(cat "/proc/$pid/oom_score_adj" 2>/dev/null)" || return 0
  [[ "$cur" == "$val" ]] && return 0
  if echo "$val" | sudo -n tee "/proc/$pid/oom_score_adj" >/dev/null 2>&1; then
    log "oom_score_adj: $label pid=$pid $cur -> $val"
  else
    log "oom_score_adj: FAILED $label pid=$pid $cur -> $val"
  fi
}

apply_oom_policy() {
  local pid
  # Orchestrator infrastructure: killing any of these takes down the whole
  # run (dockerd death kills every worker; runner death loses the job).
  for pat in 'Runner.Listener' 'Runner.Worker' 'Runner.PluginHost' dockerd containerd; do
    for pid in $(pgrep -f "$pat" 2>/dev/null); do
      set_adj "$pid" -900 "$pat"
    done
  done
  for pid in $(pgrep -f 'regen_symbolcache.sh' 2>/dev/null); do
    set_adj "$pid" -400 "regen-driver"
  done
  # julia outside a docker cgroup is the sweep driver; inside one it's a
  # worker and the preferred OOM victim.
  for pid in $(pgrep -x julia 2>/dev/null); do
    if grep -q docker "/proc/$pid/cgroup" 2>/dev/null; then
      set_adj "$pid" 500 "worker-julia"
    else
      set_adj "$pid" -400 "driver-julia"
    fi
  done
  # Worker containers' init processes, in case the entrypoint isn't `julia`.
  for pid in $(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.State.Pid}}' 2>/dev/null); do
    set_adj "$pid" 500 "worker-container"
  done
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
if [[ "$APPLY_POLICY" == 1 ]]; then
  cur="$(cat /proc/self/oom_score_adj 2>/dev/null || echo 0)"
  if echo $((cur - 1)) | sudo -n tee /proc/self/oom_score_adj >/dev/null 2>&1; then
    echo "$cur" | sudo -n tee /proc/self/oom_score_adj >/dev/null 2>&1
    log "can lower oom_score_adj: yes"
  else
    log "can lower oom_score_adj: NO (missing CAP_SYS_RESOURCE?) — orchestrator protection unavailable, only raising worker scores"
  fi
else
  log "observe-only: MEMDIAG_APPLY_OOM_POLICY != 1, not touching oom_score_adj"
fi

tick=0
while :; do
  if [[ "$APPLY_POLICY" == 1 ]]; then
    apply_oom_policy
  fi
  snapshot_line
  if ((tick % DETAIL_EVERY == 0)); then
    snapshot_detail
  fi
  tick=$((tick + 1))
  sleep "$INTERVAL"
done
