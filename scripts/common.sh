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
# Which Java major a Minecraft version needs. Mojang's requirements:
# <=1.16 → 8, 1.17–1.20.4 → 17, 1.20.5+ and all 1.21+ → 21. Snapshots / unknown
# default to the newest.
java_major_for_mc() {
  local mc="$1" minor patch
  if [[ "$mc" =~ ^1\.([0-9]+)(\.([0-9]+))?$ ]]; then
    minor="${BASH_REMATCH[1]}"; patch="${BASH_REMATCH[3]:-0}"
    if   (( minor <= 16 )); then echo 8
    elif (( minor < 20 ));  then echo 17
    elif (( minor == 20 )); then (( patch >= 5 )) && echo 21 || echo 17
    else echo 21
    fi
  else
    echo 21
  fi
}

# Select + export the JVM for a Minecraft version. The image no longer relies on
# distro JDK packages living at guessed paths (those drift with the base image
# and break with "cannot execute binary file"); instead each Java major is
# self-managed under a canonical cache dir, fetched from Adoptium on demand if
# it isn't already baked in. ensure_java guarantees a runtime that actually runs
# on THIS arch, or fails loudly.
select_java_for_mc() {
  local mc="$1" want home
  want=$(java_major_for_mc "$mc")
  home=$(ensure_java "$want") \
    || die "No working Java ${want} runtime available for Minecraft ${mc}"
  export JAVA_HOME="$home"
  export JAVACMD="${home}/bin/java"
  log "selected Java ${want} (${JAVACMD}) for Minecraft ${mc}"
}

# Canonical, arch-agnostic home for a self-managed Temurin major.
KOJA_JVM_DIR="${KOJA_JVM_DIR:-/opt/koja/jvms}"
_jvm_home() { printf '%s/%s' "$KOJA_JVM_DIR" "$1"; }

# Map `uname -m` to the Adoptium download arch token.
_adoptium_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo x64;;
    aarch64|arm64) echo aarch64;;
    armv7l|armhf)  echo arm;;
    ppc64le)       echo ppc64le;;
    s390x)         echo s390x;;
    *)             echo x64;;
  esac
}

# True if `<home>/bin/java` exists and actually executes on this host. An `-x`
# bit says nothing about ELF arch, so always confirm by running it.
_java_runs() { [[ -x "$1/bin/java" ]] && "$1/bin/java" -version >/dev/null 2>&1; }

# Ensure a *working* Java <major> is available and print its home dir.
#   1. Reuse the self-managed copy if it already runs.
#   2. Reuse any baked-in JDK of the exact major that runs (no download).
#   3. Otherwise fetch a Temurin JRE for this arch from the Adoptium API, cache
#      it under the canonical dir, and reuse it on every later boot.
# Only the home dir is written to stdout; all chatter goes to stderr.
ensure_java() {
  local want="$1" home cached arch url tmp
  cached=$(_jvm_home "$want")
  if _java_runs "$cached"; then printf '%s' "$cached"; return 0; fi

  home=$(_find_jvm "$want") || true
  if [[ -n "$home" ]]; then printf '%s' "$home"; return 0; fi

  arch=$(_adoptium_arch)
  url="https://api.adoptium.net/v3/binary/latest/${want}/ga/linux/${arch}/jre/hotspot/normal/eclipse"
  log "no working Java ${want} in image; fetching Temurin ${want} (${arch}) from Adoptium"
  tmp=$(mktemp -d)
  if ! curl -fSL --retry 5 --retry-delay 2 --retry-connrefused -o "${tmp}/jre.tar.gz" "$url"; then
    rm -rf "$tmp"; warn "Adoptium download failed for Java ${want}"; return 1
  fi
  mkdir -p "$cached"
  # The archive's single top-level dir is the JRE root; strip it onto the cache.
  tar -xzf "${tmp}/jre.tar.gz" -C "$cached" --strip-components=1
  rm -rf "$tmp"
  _java_runs "$cached" || { warn "fetched Java ${want} but it does not run"; return 1; }
  printf '%s' "$cached"
}

# Best-effort search for an already-installed JVM of an exact major that runs.
# Prints its home and returns 0 on success, else returns non-zero with no output
# (so the caller can fall through to fetching one).
_find_jvm() {
  local want="$1" d
  for d in \
      "$(_jvm_home "$want")" \
      "/usr/lib/jvm/temurin-${want}-jre-"* \
      "/usr/lib/jvm/temurin-${want}-jdk-"* \
      "/usr/lib/jvm/java-${want}-"* \
      "/opt/java/openjdk"; do
    if _java_runs "$d" \
       && "${d}/bin/java" -version 2>&1 | grep -qE "\"(1\.${want}\.|${want}[\".])"; then
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}
