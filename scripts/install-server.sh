#!/usr/bin/env bash
#
# Resolve + install the server for ${TYPE} at Minecraft ${VERSION} using the
# official upstream APIs. Writes /data/.koja/launch.env describing how to start
# it (a plain jar, or modern Forge/NeoForge @args files) plus the resolved MC
# version (so Java selection and overlay patching are exact).
#
# APIs used:
#   Vanilla  — piston-meta.mojang.com version_manifest_v2
#   Fabric   — meta.fabricmc.net  v2
#   Quilt    — meta.quiltmc.org   v3 + maven.quiltmc.org (installer)
#   Forge    — maven.minecraftforge.net (promotions_slim + installer)
#   NeoForge — maven.neoforged.net (versions API + installer)
set -euo pipefail
source /opt/koja/scripts/common.sh

KOJA_DIR=/data/.koja
mkdir -p "$KOJA_DIR"
LAUNCH_ENV="${KOJA_DIR}/launch.env"

PISTON="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"

# Resolve "latest"/"latest-snapshot" to a concrete MC version using Mojang's
# manifest. Sets the global RESOLVED_MC.
resolve_mc_version() {
  local req="${VERSION:-latest}" manifest
  manifest=$(http_get "$PISTON")
  case "$(lower "$req")" in
    latest|release|"") RESOLVED_MC=$(jq -r '.latest.release'  <<<"$manifest");;
    latest-snapshot|snapshot) RESOLVED_MC=$(jq -r '.latest.snapshot' <<<"$manifest");;
    *) RESOLVED_MC="$req";;
  esac
  [[ -n "$RESOLVED_MC" && "$RESOLVED_MC" != "null" ]] || die "Could not resolve Minecraft version from '${req}'"
  MC_MANIFEST="$manifest"
  log "resolved Minecraft version: ${RESOLVED_MC}"
}

# Vanilla server jar straight from Mojang.
install_vanilla() {
  local url vjson server_url
  url=$(jq -r --arg v "$RESOLVED_MC" '.versions[] | select(.id==$v) | .url' <<<"$MC_MANIFEST")
  [[ -n "$url" && "$url" != "null" ]] || die "Minecraft ${RESOLVED_MC} not found in Mojang manifest"
  vjson=$(http_get "$url")
  server_url=$(jq -r '.downloads.server.url' <<<"$vjson")
  [[ -n "$server_url" && "$server_url" != "null" ]] || die "No server download for Minecraft ${RESOLVED_MC} (too old?)"
  http_dl "$server_url" /data/server.jar
  write_launch JAR /data/server.jar
}

# Paper (and Spigot/Bukkit, which alias to Paper as the drop-in compatible
# server — Spigot has no official download API). Uses the PaperMC v2 API.
install_paper() {
  local builds build jar
  builds=$(http_get "https://api.papermc.io/v2/projects/paper/versions/${RESOLVED_MC}/builds") \
    || die "Paper has no builds for Minecraft ${RESOLVED_MC}"
  # Prefer the latest stable ("default" channel) build, else the latest of any.
  build=$(jq -r '[.builds[] | select(.channel=="default")] | last | .build // empty' <<<"$builds")
  [[ -z "$build" ]] && build=$(jq -r '.builds | last | .build // empty' <<<"$builds")
  [[ -n "$build" ]] || die "No Paper build for Minecraft ${RESOLVED_MC}"
  jar=$(jq -r --argjson b "$build" '.builds[] | select(.build==$b) | .downloads.application.name' <<<"$builds")
  log "Paper ${RESOLVED_MC} build ${build}"
  http_dl "https://api.papermc.io/v2/projects/paper/versions/${RESOLVED_MC}/builds/${build}/downloads/${jar}" \
          /data/paper.jar
  write_launch JAR /data/paper.jar
}

# Spigot/Bukkit: use an explicit jar if provided, otherwise Paper (a drop-in
# replacement that loads Bukkit/Spigot plugins).
install_spigot() {
  if [[ -n "${SERVER_JAR_URL:-}" ]]; then
    http_dl "$SERVER_JAR_URL" /data/server.jar
    write_launch JAR /data/server.jar
  else
    warn "Spigot has no official download API; using Paper (Bukkit/Spigot plugin compatible). Set SERVER_JAR_URL to override."
    install_paper
  fi
}

# Fabric — meta API hands back a ready-to-run server launcher jar.
install_fabric() {
  local loader installer
  loader="${LOADER_VERSION:-$(http_get "https://meta.fabricmc.net/v2/versions/loader/${RESOLVED_MC}" | jq -r '.[0].loader.version')}"
  installer="${INSTALLER_VERSION:-$(http_get "https://meta.fabricmc.net/v2/versions/installer" | jq -r '.[0].version')}"
  [[ -n "$loader" && "$loader" != "null" ]] || die "No Fabric loader for Minecraft ${RESOLVED_MC}"
  log "Fabric loader ${loader} / installer ${installer}"
  http_dl "https://meta.fabricmc.net/v2/versions/loader/${RESOLVED_MC}/${loader}/${installer}/server/jar" \
          /data/fabric-server-launch.jar
  write_launch JAR /data/fabric-server-launch.jar
}

# Quilt — resolve loader from meta, run the official installer to lay down the
# server (it also pulls the vanilla server jar).
install_quilt() {
  local loader meta_xml installer_ver
  loader="${LOADER_VERSION:-$(http_get "https://meta.quiltmc.org/v3/versions/loader/${RESOLVED_MC}" | jq -r '.[0].loader.version')}"
  [[ -n "$loader" && "$loader" != "null" ]] || die "No Quilt loader for Minecraft ${RESOLVED_MC}"
  meta_xml=$(http_get "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/maven-metadata.xml")
  installer_ver="${QUILT_INSTALLER_VERSION:-$(grep -oP '(?<=<release>)[^<]+' <<<"$meta_xml" | head -n1)}"
  [[ -n "$installer_ver" ]] || die "Could not resolve Quilt installer version"
  log "Quilt loader ${loader} / installer ${installer_ver}"
  http_dl "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/${installer_ver}/quilt-installer-${installer_ver}.jar" \
          "${KOJA_DIR}/quilt-installer.jar"
  ( cd /data && "$JAVACMD" -jar "${KOJA_DIR}/quilt-installer.jar" install server \
      "${RESOLVED_MC}" "${loader}" --install-dir=/data --download-server )
  # The installer writes quilt-server-launch.jar into the install dir.
  [[ -f /data/quilt-server-launch.jar ]] || die "Quilt install did not produce quilt-server-launch.jar"
  write_launch JAR /data/quilt-server-launch.jar
}

# Forge — promotions_slim picks the recommended (else latest) build, run the
# installer in --installServer mode, then detect the launcher layout.
install_forge() {
  local fv full promos installer
  if [[ -n "${LOADER_VERSION:-}" ]]; then
    fv="$LOADER_VERSION"
  else
    promos=$(http_get "https://maven.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")
    fv=$(jq -r --arg k "${RESOLVED_MC}-recommended" '.promos[$k] // empty' <<<"$promos")
    [[ -z "$fv" ]] && fv=$(jq -r --arg k "${RESOLVED_MC}-latest" '.promos[$k] // empty' <<<"$promos")
  fi
  [[ -n "$fv" ]] || die "No Forge build found for Minecraft ${RESOLVED_MC}"
  full="${RESOLVED_MC}-${fv}"
  log "Forge ${full}"
  installer="${KOJA_DIR}/forge-installer.jar"
  # Most builds: forge-<full>-installer.jar. Some old ones carry a -mcX suffix
  # in the artifact path; try the canonical URL first.
  if ! http_dl "https://maven.minecraftforge.net/net/minecraftforge/forge/${full}/forge-${full}-installer.jar" "$installer"; then
    die "Could not download Forge installer for ${full}"
  fi
  ( cd /data && "$JAVACMD" -jar "$installer" --installServer /data )
  detect_modern_or_jar "net/minecraftforge/forge/${full}" "forge-${full}"
}

# NeoForge — resolve a build matching the MC version from the versions API,
# install, then detect the launcher layout.
install_neoforge() {
  local nf prefix versions
  if [[ -n "${LOADER_VERSION:-}" ]]; then
    nf="$LOADER_VERSION"
  else
    # MC 1.21.1 -> "21.1", 1.20.4 -> "20.4", 1.21 -> "21.0".
    if [[ "$RESOLVED_MC" =~ ^1\.([0-9]+)(\.([0-9]+))?$ ]]; then
      prefix="${BASH_REMATCH[1]}.${BASH_REMATCH[3]:-0}"
    else
      die "Cannot derive a NeoForge version for '${RESOLVED_MC}'; set LOADER_VERSION"
    fi
    versions=$(http_get "https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge")
    nf=$(jq -r --arg p "${prefix}." '.versions[] | select(startswith($p))' <<<"$versions" | sort -V | tail -n1)
    [[ -n "$nf" ]] || die "No NeoForge build for Minecraft ${RESOLVED_MC} (prefix ${prefix}); set LOADER_VERSION"
  fi
  log "NeoForge ${nf}"
  local installer="${KOJA_DIR}/neoforge-installer.jar"
  http_dl "https://maven.neoforged.net/releases/net/neoforged/neoforge/${nf}/neoforge-${nf}-installer.jar" "$installer"
  ( cd /data && "$JAVACMD" -jar "$installer" --installServer /data )
  detect_modern_or_jar "net/neoforged/neoforge/${nf}" "neoforge-${nf}"
}

# Forge/NeoForge 1.17+ produce libraries/<path>/unix_args.txt (a @argfile we
# pass to java). Older builds drop a runnable *-universal/server jar. Detect
# whichever is present.
detect_modern_or_jar() {
  local lib_path="$1" jar_base="$2" args
  args="/data/libraries/${lib_path}/unix_args.txt"
  if [[ -f "$args" ]]; then
    write_launch ARGS "$args"
    return
  fi
  local j
  for j in "/data/${jar_base}.jar" "/data/${jar_base}-universal.jar" "/data/${jar_base}-server.jar"; do
    [[ -f "$j" ]] && { write_launch JAR "$j"; return; }
  done
  # Fall back to any non-installer forge/neoforge jar at the data root.
  j=$(find /data -maxdepth 1 -name '*forge*.jar' ! -name '*installer*' | head -n1 || true)
  [[ -n "$j" ]] && { write_launch JAR "$j"; return; }
  die "Could not locate the installed server launcher (no unix_args.txt or server jar)"
}

# Persist the launch descriptor + resolved version for the entrypoint.
write_launch() {
  {
    echo "KOJA_LAUNCH_MODE=$1"
    echo "KOJA_LAUNCH_TARGET=$2"
    echo "KOJA_MC_VERSION=${RESOLVED_MC}"
  } > "$LAUNCH_ENV"
  log "launch descriptor: mode=$1 target=$2 mc=${RESOLVED_MC}"
}

main() {
  local type; type=$(upper "${TYPE:-VANILLA}")
  resolve_mc_version
  # Java must be chosen before running any loader installer (they're jars).
  select_java_for_mc "$RESOLVED_MC"

  # Skip reinstall if a previous boot already provisioned this exact combo
  # (the orchestrator may restart a container against a persistent /data).
  if [[ -f "$LAUNCH_ENV" ]] && grep -q "KOJA_MC_VERSION=${RESOLVED_MC}$" "$LAUNCH_ENV" \
     && [[ "${FORCE_REINSTALL:-false}" != "true" ]]; then
    local tgt; tgt=$(grep '^KOJA_LAUNCH_TARGET=' "$LAUNCH_ENV" | cut -d= -f2-)
    if [[ -e "$tgt" ]]; then
      log "server already installed for ${type} ${RESOLVED_MC}; skipping (set FORCE_REINSTALL=true to override)"
      return
    fi
  fi

  case "$type" in
    VANILLA)        install_vanilla;;
    PAPER)          install_paper;;
    SPIGOT|BUKKIT)  install_spigot;;
    FABRIC)         install_fabric;;
    QUILT)          install_quilt;;
    FORGE)          install_forge;;
    NEOFORGE)       install_neoforge;;
    *) die "Unknown TYPE='${TYPE}' (expected VANILLA|PAPER|SPIGOT|BUKKIT|FORGE|FABRIC|NEOFORGE|QUILT)";;
  esac
}

main "$@"
