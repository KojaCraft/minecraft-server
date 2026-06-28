#!/usr/bin/env bash
# Shared helpers sourced by every script in this image.
set -euo pipefail

log()  { printf '\033[36m[koja]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[koja:warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[koja:error]\033[0m %s\n' "$*" >&2; exit 1; }

# Fetch a URL to stdout, retrying on transient failures.
http_get() {
  curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused "$1"
}

# Download a URL to a file, retrying.
http_dl() {
  local url="$1" out="$2"
  log "downloading ${url} -> ${out}"
  curl -fSL --retry 5 --retry-delay 2 --retry-connrefused -o "$out" "$url"
}

# Uppercase helper (portable).
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Resolve which JDK to use for a given Minecraft version and export JAVA_HOME /
# JAVACMD. Mojang's requirements: <=1.16 → Java 8, 1.17–1.20.4 → Java 17,
# 1.20.5+ and all 1.21+ → Java 21. Snapshots / unknown default to the newest.
select_java_for_mc() {
  local mc="$1" major minor patch want
  # Strip anything that isn't a release number (snapshots, pre-releases…).
  if [[ "$mc" =~ ^1\.([0-9]+)(\.([0-9]+))?$ ]]; then
    minor="${BASH_REMATCH[1]}"
    patch="${BASH_REMATCH[3]:-0}"
    if   (( minor <= 16 )); then want=8
    elif (( minor < 20 ));  then want=17
    elif (( minor == 20 )); then
      if (( patch >= 5 )); then want=21; else want=17; fi
    else want=21
    fi
  else
    want=21   # snapshot / non-standard → newest runtime
  fi

  # Arch is baked into the Temurin paths (…-amd64 / …-arm64). Rather than trust a
  # hard-coded arch, probe the conventional path AND confirm the binary actually
  # runs on this host — an `-x` bit says nothing about ELF arch, so a wrong-arch
  # jvm slips through as "executable" and then dies with exit 126 ("cannot
  # execute binary file"). _find_jvm verifies by running `java -version`, so we
  # always fall through to it when the convenient guess can't execute.
  local arch home=""
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  case "$want" in
    8)  home="/usr/lib/jvm/temurin-8-jre-${arch}";;
    17) home="/usr/lib/jvm/temurin-17-jre-${arch}";;
    21) home="/opt/java/openjdk";;
  esac
  # Accept the guess only if its java both exists and actually executes here.
  if [[ ! -x "${home}/bin/java" ]] || ! "${home}/bin/java" -version >/dev/null 2>&1; then
    home=$(_find_jvm "$want")
  fi
  [[ -x "${home}/bin/java" ]] && "${home}/bin/java" -version >/dev/null 2>&1 \
    || die "Could not locate a working Java ${want} runtime for Minecraft ${mc}"
  export JAVA_HOME="$home"
  export JAVACMD="${home}/bin/java"
  log "selected Java ${want} (${JAVACMD}) for Minecraft ${mc}"
}

# Best-effort search for a JVM of a given major version across arch-specific
# install paths.
_find_jvm() {
  local want="$1" d
  for d in \
      "/usr/lib/jvm/temurin-${want}-jre-"* \
      "/usr/lib/jvm/temurin-${want}-jdk-"* \
      "/usr/lib/jvm/java-${want}-"* \
      /opt/java/openjdk; do
    if [[ -x "${d}/bin/java" ]]; then
      # Confirm the major version matches what we asked for.
      if "${d}/bin/java" -version 2>&1 | grep -qE "\"(1\.${want}\.|${want}\.)"; then
        printf '%s' "$d"; return 0
      fi
    fi
  done
  # Last resort: only the base image's own runtime (Java 21) — and only if that
  # is what was asked for. Returning a different major would just fail later
  # (e.g. Java 21 can't launch a 1.12.2 server), so return nothing and let the
  # caller die with a clear "no working Java N" message instead.
  if [[ "$want" == 21 ]] && /opt/java/openjdk/bin/java -version >/dev/null 2>&1; then
    printf '%s' "/opt/java/openjdk"
  fi
}
