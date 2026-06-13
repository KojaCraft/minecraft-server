#!/usr/bin/env bash
#
# Apply the orchestrator's "server files" onto /data and make the server
# orchestrator-aware. Everything here is automatic and idempotent; sources, in
# order (later ones win):
#
#   1. Baked / mounted overlay dir   ($ORCHESTRATOR_OVERLAY_DIR, default
#      /opt/orchestrator/overlay) — copied verbatim into /data.
#   2. Overlay tarball URL           ($ORCHESTRATOR_OVERLAY_URL) — e.g. a
#      presigned S3 link to templates/<template>.tar.gz. Extracted into /data.
#   3. World URL                     ($WORLD_URL) — extracted into /data.
#   4. Connector plugin/mod URL      ($ORCHESTRATOR_CONNECTOR_URL) — dropped in
#      plugins/ or mods/ depending on the loader.
#
# It then patches server.properties the same way the orchestrator's
# resource_manager.patch_server does (placeholders + port/name) and writes
# data.yml / game.json so existing orchestrator plugins keep working.
set -euo pipefail
source /opt/koja/scripts/common.sh

apply_dir_overlay() {
  local dir="${ORCHESTRATOR_OVERLAY_DIR:-/opt/orchestrator/overlay}"
  if [[ -d "$dir" ]] && [[ -n "$(ls -A "$dir" 2>/dev/null || true)" ]]; then
    log "applying overlay directory ${dir} -> /data"
    cp -a "${dir}/." /data/
  fi
}

apply_tar_overlay() {
  [[ -n "${ORCHESTRATOR_OVERLAY_URL:-}" ]] || return 0
  log "applying overlay tarball from ORCHESTRATOR_OVERLAY_URL"
  http_dl "$ORCHESTRATOR_OVERLAY_URL" /tmp/overlay.tar.gz
  tar -xzf /tmp/overlay.tar.gz -C /data
  rm -f /tmp/overlay.tar.gz
}

apply_world() {
  [[ -n "${WORLD_URL:-}" ]] || return 0
  log "downloading world from WORLD_URL"
  http_dl "$WORLD_URL" /tmp/world.archive
  case "$WORLD_URL" in
    *.zip) unzip -oq /tmp/world.archive -d /data;;
    *)     tar -xf /tmp/world.archive -C /data;;
  esac
  rm -f /tmp/world.archive
}

# Place the PROPER orchestrator connector for the running platform: the Bukkit
# plugin for Paper/Spigot/Bukkit, the matching loader mod for
# Fabric/Quilt/Forge/NeoForge. Vanilla cannot load either, so it is skipped.
#
# The artifact URL is resolved (in order) from a platform-specific env, then a
# base URL + naming convention, then the single ORCHESTRATOR_CONNECTOR_URL.
apply_connector() {
  local type platform dest url
  type=$(upper "${TYPE:-VANILLA}")
  case "$type" in
    PAPER|SPIGOT|BUKKIT) platform=bukkit;   dest=/data/plugins;;
    FABRIC|QUILT)        platform=fabric;   dest=/data/mods;;
    FORGE)               platform=forge;    dest=/data/mods;;
    NEOFORGE)            platform=neoforge; dest=/data/mods;;
    *) log "TYPE=${type} cannot load a connector (vanilla); skipping"; return 0;;
  esac

  # Per-platform explicit override.
  case "$platform" in
    bukkit)   url="${ORCHESTRATOR_CONNECTOR_BUKKIT_URL:-}";;
    fabric)   url="${ORCHESTRATOR_CONNECTOR_FABRIC_URL:-}";;
    forge)    url="${ORCHESTRATOR_CONNECTOR_FORGE_URL:-}";;
    neoforge) url="${ORCHESTRATOR_CONNECTOR_NEOFORGE_URL:-}";;
  esac
  # Base URL + naming convention, then a single shared URL.
  if [[ -z "$url" && -n "${ORCHESTRATOR_CONNECTOR_BASE_URL:-}" ]]; then
    url="${ORCHESTRATOR_CONNECTOR_BASE_URL%/}/koja-orchestrator-connector-${platform}.jar"
  fi
  url="${url:-${ORCHESTRATOR_CONNECTOR_URL:-}}"

  # Default: pull the proper artifact straight from the connector repo's GitHub
  # Releases (the assets published by the connector build workflow). Asset names
  # are stable per platform, so the "latest release" download link resolves
  # without any API call.
  if [[ -z "$url" ]]; then
    local repo="${ORCHESTRATOR_CONNECTOR_REPO:-KojacoordNetwork/orchestrator-connector}"
    local tag="${ORCHESTRATOR_CONNECTOR_TAG:-latest}"
    local asset="koja-orchestrator-connector-${platform}.jar"
    if [[ "$tag" == "latest" ]]; then
      url="https://github.com/${repo}/releases/latest/download/${asset}"
    else
      url="https://github.com/${repo}/releases/download/${tag}/${asset}"
    fi
  fi

  mkdir -p "$dest"
  log "installing ${platform} orchestrator connector from ${url}"
  # Non-fatal: a missing connector must not stop the server from booting.
  if ! http_dl "$url" "${dest}/orchestrator-connector.jar"; then
    warn "could not download ${platform} connector from ${url}; continuing without it"
    rm -f "${dest}/orchestrator-connector.jar"
  fi
}

# server.properties: generate from the template if absent, then patch.
configure_properties() {
  local props=/data/server.properties
  [[ -f "$props" ]] || cp /opt/koja/assets/server.properties "$props"

  local port="${PORT:-${SERVER_PORT:-25565}}"
  local ip="${SERVER_IP:-0.0.0.0}"
  local name="${SERVER_NAME:-koja}"

  # Orchestrator placeholders (resource_manager.patch_server).
  sed -i \
    -e "s/%serverPort%/${port}/g" \
    -e "s/%serverIp%/${ip}/g" \
    -e "s/%serverName%/${name}/g" \
    "$props"

  # Enforce the values the orchestrator relies on regardless of what the
  # template shipped.
  set_prop() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$props"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$props"
    else
      echo "${key}=${val}" >> "$props"
    fi
  }
  set_prop server-port "$port"
  set_prop query.port "$port"
  set_prop enable-query "true"
  set_prop online-mode "$(lower "${ONLINE_MODE:-false}")"
  set_prop motd "${MOTD:-${name}}"
  if [[ "$(lower "${ENABLE_RCON:-true}")" == "true" ]]; then
    set_prop enable-rcon "true"
    set_prop rcon.port "${RCON_PORT:-25575}"
    set_prop rcon.password "${RCON_PASSWORD:?RCON_PASSWORD must be set when ENABLE_RCON=true}"
  fi
}

# data.yml + game.json, mirroring resource_manager.patch_server so existing
# orchestrator plugins find what they expect.
write_orchestrator_metadata() {
  local template="${TEMPLATE:-${SERVER_NAME:-unknown}}"
  cat > /data/data.yml <<EOF
redis-bungee-ip: ${REDIS_HOST:-127.0.0.1}
redis-bungee-port: ${REDIS_PORT:-6379}
redis-bungee-password: "${REDIS_PASSWORD:-}"
sql-url: "${SQL_URL:-}"
sql-user: "${SQL_USER:-}"
sql-pass: "${SQL_PASS:-}"
data-url: "${template}"
EOF
  cat > /data/game.json <<EOF
{
  "template-id": "${template}",
  "map-name": "${MAP:-default}",
  "min-slots": ${MIN_SLOTS:-0},
  "max-slots": ${MAX_SLOTS:-20},
  "options": ${OPTIONS_JSON:-null}
}
EOF
}

main() {
  apply_dir_overlay
  apply_tar_overlay
  apply_world
  apply_connector
  configure_properties
  if [[ "$(lower "${ORCHESTRATOR_PATCH:-true}")" == "true" ]]; then
    write_orchestrator_metadata
  fi
}

main "$@"
