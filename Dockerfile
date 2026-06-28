# syntax=docker/dockerfile:1
#
# KojaCoord custom Minecraft server image.
#
# One image that boots ANY Minecraft version on Vanilla, Forge, Fabric,
# NeoForge or Quilt, resolving everything from the official upstream APIs at
# container start. It is built to be driven by the orchestrator: the per-server
# "server files" overlay (the template tarball the orchestrator stores in S3)
# is applied automatically, server.properties placeholders are patched the same
# way the orchestrator's resource_manager does, and `rcon-cli` is on PATH so the
# orchestrator's graceful `save-all flush` on shutdown works.
#
# Multiple JDKs are installed (8 / 17 / 21) and the correct one is selected per
# Minecraft version at runtime — old versions need Java 8, 1.20.5+ needs 21.

FROM eclipse-temurin:21-jre-jammy

LABEL org.opencontainers.image.title="KojaCoord Minecraft server" \
      org.opencontainers.image.description="Vanilla/Paper/Spigot/Forge/Fabric/NeoForge/Quilt server for any Minecraft version, resolved from official APIs at boot." \
      org.opencontainers.image.licenses="MIT"

# curl/jq/tar/unzip for API resolution and archive handling. JDKs are NOT
# installed via distro packages — they're self-managed under /opt/koja/jvms by
# common.sh (resolved from the Adoptium API), so the image owns its runtimes
# instead of depending on whatever the base image happens to ship.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash curl ca-certificates jq tar gzip unzip xz-utils procps tini gosu; \
    rm -rf /var/lib/apt/lists/*

# mc-server-runner turns SIGTERM into a clean `stop` on the server's stdin so
# worlds are saved on shutdown; rcon-cli is what docker.rs invokes for
# `save-all flush`. Both are tiny static Go binaries (Apache-2.0).
ARG TARGETARCH=amd64
ARG MC_SERVER_RUNNER_VERSION=1.13.0
ARG RCON_CLI_VERSION=1.6.8
RUN set -eux; \
    case "${TARGETARCH}" in amd64) GOARCH=amd64;; arm64) GOARCH=arm64;; *) GOARCH=amd64;; esac; \
    curl -fsSL -o /tmp/mcsr.tar.gz \
      "https://github.com/itzg/mc-server-runner/releases/download/${MC_SERVER_RUNNER_VERSION}/mc-server-runner_${MC_SERVER_RUNNER_VERSION}_linux_${GOARCH}.tar.gz"; \
    tar -xzf /tmp/mcsr.tar.gz -C /usr/local/bin mc-server-runner; \
    curl -fsSL -o /tmp/rcon.tar.gz \
      "https://github.com/itzg/rcon-cli/releases/download/${RCON_CLI_VERSION}/rcon-cli_${RCON_CLI_VERSION}_linux_${GOARCH}.tar.gz"; \
    tar -xzf /tmp/rcon.tar.gz -C /usr/local/bin rcon-cli; \
    chmod +x /usr/local/bin/mc-server-runner /usr/local/bin/rcon-cli; \
    rm -f /tmp/mcsr.tar.gz /tmp/rcon.tar.gz

COPY scripts/ /opt/koja/scripts/
COPY assets/  /opt/koja/assets/
RUN chmod +x /opt/koja/scripts/*.sh

# Pre-bake every Java major the runtime can need into the canonical self-managed
# dir, using the exact same Adoptium resolution the entrypoint falls back to.
# Normal boots are therefore offline-fast, while JVM management stays decoupled
# from the base image's packaged JDKs (whose drift previously shipped images
# that couldn't launch older Minecraft versions). A missing/broken JDK at
# runtime self-heals by re-fetching. Fails the build loudly if any can't run.
RUN set -eux; \
    bash -c 'source /opt/koja/scripts/common.sh; for v in 8 17 21; do ensure_java "$v" >/dev/null; done'; \
    ls -d /opt/koja/jvms/* /opt/java/openjdk 2>/dev/null

# Baked-in orchestrator overlay drop point. Anything COPY'd or mounted here is
# applied onto /data automatically (see orchestrator-overlay.sh).
RUN mkdir -p /opt/orchestrator/overlay /data
VOLUME ["/data"]
WORKDIR /data

# Defaults — every one is overridable by the orchestrator via env.
ENV TYPE=VANILLA \
    VERSION=latest \
    EULA=false \
    ONLINE_MODE=false \
    USE_AIKAR_FLAGS=true \
    ENABLE_RCON=true \
    RCON_PORT=25575 \
    SERVER_PORT=25565 \
    ORCHESTRATOR_OVERLAY_DIR=/opt/orchestrator/overlay \
    ORCHESTRATOR_PATCH=true \
    TZ=UTC
# rcon-cli reads these so the orchestrator's bare `rcon-cli save-all flush` works.
ENV RCON_CLI_HOST=localhost RCON_CLI_PORT=25575

EXPOSE 25565/tcp 25565/udp 25575/tcp

# Healthcheck: server is up once it answers a trivial RCON command.
HEALTHCHECK --interval=15s --timeout=5s --start-period=180s --retries=5 \
    CMD /opt/koja/scripts/healthcheck.sh

ENTRYPOINT ["tini", "--", "/opt/koja/scripts/entrypoint.sh"]
