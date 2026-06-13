#!/usr/bin/env bash
#
# Boot sequence:
#   1. EULA gate.
#   2. Resolve + install the server (install-server.sh) — picks Java too.
#   3. Apply the orchestrator overlay + patch config (orchestrator-overlay.sh).
#   4. Compute JVM flags (jvm.sh).
#   5. Launch under mc-server-runner so SIGTERM => clean `stop` (worlds saved).
set -euo pipefail
source /opt/koja/scripts/common.sh

# ── EULA ────────────────────────────────────────────────────────────────────
if [[ "$(lower "${EULA:-false}")" != "true" ]]; then
  die "You must accept the Minecraft EULA by setting EULA=true (https://aka.ms/MinecraftEULA)"
fi
echo "eula=true" > /data/eula.txt

# ── Install + provision ─────────────────────────────────────────────────────
/opt/koja/scripts/install-server.sh
# shellcheck disable=SC1091
source /data/.koja/launch.env   # KOJA_LAUNCH_MODE / KOJA_LAUNCH_TARGET / KOJA_MC_VERSION

# Re-select Java against the *resolved* version (install may have resolved
# "latest" to a concrete number) so the runtime matches exactly.
select_java_for_mc "${KOJA_MC_VERSION}"

# Export so the overlay can fetch a version-specific connector if one exists.
export KOJA_MC_VERSION
/opt/koja/scripts/orchestrator-overlay.sh

# ── JVM flags ───────────────────────────────────────────────────────────────
JVM_FLAGS="$(/opt/koja/scripts/jvm.sh)"
log "JVM flags: ${JVM_FLAGS}"

# ── Assemble the server command ─────────────────────────────────────────────
# Modern Forge/NeoForge use an @argfile that already encodes the classpath and
# main class; vanilla/fabric/quilt/old-forge run a single jar.
declare -a SERVER_CMD
case "${KOJA_LAUNCH_MODE}" in
  ARGS) SERVER_CMD=("$JAVACMD" ${JVM_FLAGS} "@${KOJA_LAUNCH_TARGET}" nogui);;
  JAR)  SERVER_CMD=("$JAVACMD" ${JVM_FLAGS} -jar "${KOJA_LAUNCH_TARGET}" nogui);;
  *)    die "Unknown launch mode '${KOJA_LAUNCH_MODE}'";;
esac

log "starting ${SERVER_NAME:-server} (${TYPE} ${KOJA_MC_VERSION}) on port ${PORT:-${SERVER_PORT:-25565}}"

# mc-server-runner owns stdin (so RCON-less `stop` works), forwards SIGTERM to a
# graceful shutdown, and waits the configured time before SIGKILL.
exec mc-server-runner \
  --stop-duration "${STOP_DURATION:-60s}" \
  --shell bash \
  -- "${SERVER_CMD[@]}"
