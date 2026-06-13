#!/usr/bin/env bash
#
# Compute the JVM flags. Memory is derived from the container's cgroup limit
# (which the orchestrator sets via HostConfig.memory) unless overridden, and
# Aikar's GC flags are applied by default — the well-established tuning for
# low-pause Minecraft servers.
set -euo pipefail
source /opt/koja/scripts/common.sh

# Detect the container memory limit (MiB) from cgroup v2 then v1.
detect_mem_mb() {
  local bytes=""
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    bytes=$(cat /sys/fs/cgroup/memory.max)
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
  fi
  [[ "$bytes" == "max" || -z "$bytes" || "$bytes" -gt 1099511627776 ]] && { echo ""; return; }
  echo $(( bytes / 1024 / 1024 ))
}

compute_jvm_flags() {
  local mem_mb max_mb init_mb
  mem_mb=$(detect_mem_mb)

  if [[ -n "${MAX_MEMORY:-}" ]]; then
    max_mb="${MAX_MEMORY%M}"
  elif [[ -n "$mem_mb" ]]; then
    # Leave ~256 MiB (capped at 1 GiB) headroom for the JVM/native overhead.
    local headroom=$(( mem_mb / 8 )); (( headroom > 1024 )) && headroom=1024
    max_mb=$(( mem_mb - headroom )); (( max_mb < 512 )) && max_mb=512
  else
    max_mb=2048
  fi
  init_mb="${INIT_MEMORY:-$max_mb}"; init_mb="${init_mb%M}"

  local flags=(-Xms"${init_mb}M" -Xmx"${max_mb}M")

  if [[ "$(lower "${USE_AIKAR_FLAGS:-true}")" == "true" ]]; then
    # Aikar's flags (https://docs.papermc.io/paper/aikars-flags). G1 region size
    # bumped to 16M for heaps >= 12G.
    local g1region=8M
    (( max_mb >= 12288 )) && g1region=16M
    flags+=(
      -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200
      -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch
      -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize="${g1region}"
      -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4
      -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90
      -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32
      -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1
      -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true
    )
  fi
  # Headless + sane container behaviour.
  flags+=(-Dfile.encoding=UTF-8 -Djava.awt.headless=true -Dlog4j2.formatMsgNoLookups=true)

  # Caller-supplied extras (split on whitespace).
  if [[ -n "${JVM_OPTS:-}" ]]; then
    # shellcheck disable=SC2206
    flags+=(${JVM_OPTS})
  fi

  printf '%s\n' "${flags[*]}"
}

compute_jvm_flags
