#!/usr/bin/env bash
# Healthy once the server answers RCON. Falls back to a TCP probe of the game
# port when RCON is disabled. Matches the orchestrator's docker is_healthy check.
set -uo pipefail
source /opt/koja/scripts/common.sh 2>/dev/null || true

if [[ "$(printf '%s' "${ENABLE_RCON:-true}" | tr '[:upper:]' '[:lower:]')" == "true" ]]; then
  if rcon-cli --port "${RCON_PORT:-25575}" --password "${RCON_PASSWORD:-}" list >/dev/null 2>&1; then
    exit 0
  fi
  exit 1
fi

# No RCON: consider it up if the game port accepts a TCP connection.
PORT="${PORT:-${SERVER_PORT:-25565}}"
if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
  exec 3<&- 3>&-
  exit 0
fi
exit 1
