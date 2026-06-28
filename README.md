# KojaCraft Minecraft server image

One image that boots **any** Minecraft version on **Vanilla, Paper, Spigot,
Forge, Fabric, NeoForge or Quilt**, resolving everything from the official
upstream APIs at container start. It works standalone and integrates cleanly
with the KojaCraft orchestrator when present.

## Build

```bash
docker build -t KojaCraft/minecraft-server:latest .
```

Multi-arch:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t KojaCraft/minecraft-server:latest --push .
```

## What it does at boot

1. **Resolve + install** the server for `TYPE` at `VERSION` using official APIs
   (`install-server.sh`): Mojang piston-meta (vanilla), meta.fabricmc.net,
   meta.quiltmc.org + installer, Forge `promotions_slim` + installer, NeoForge
   versions API + installer. Modern Forge/NeoForge `@unix_args.txt` layouts and
   classic runnable jars are both detected.
2. **Pick the right JDK** for the version (8 / 17 / 21 are all installed).
3. **Apply the orchestrator overlay** (`orchestrator-overlay.sh`) — see below.
4. **Compute optimized JVM flags** (Aikar's flags, heap sized from the cgroup
   memory limit) — `jvm.sh`.
5. **Launch under `mc-server-runner`** so `SIGTERM` becomes a clean `stop`
   (worlds saved). `rcon-cli` is on `PATH`, so the orchestrator's
   `save-all flush` on shutdown works unchanged.

## Adding the orchestrator server files (easy / automatic)

The orchestrator already builds a per-server directory (template tarball +
plugins + patched `server.properties` + `data.yml`/`game.json`). The client
bind-mounts that directory to **`/data`**, so those files are present
automatically and the world persists across restarts.

Other supported sources (applied in order, later wins):

| Source | Env | Notes |
|---|---|---|
| Bind-mounted `/data` | (mount) | What the orchestrator client does. |
| Overlay directory | `ORCHESTRATOR_OVERLAY_DIR` (default `/opt/orchestrator/overlay`) | `COPY` files here at build time, or mount them — copied onto `/data`. |
| Overlay tarball | `ORCHESTRATOR_OVERLAY_URL` | e.g. a presigned S3 link to `templates/<t>.tar.gz`, extracted onto `/data`. |
| World | `WORLD_URL` | `.zip`/`.tar.*` extracted onto `/data`. |
| Connector | (auto, from Releases) | The **proper** connector for the platform — Bukkit plugin for Paper/Spigot/Bukkit, the matching loader mod otherwise — is downloaded automatically from the connector repo's GitHub Releases (`kojacraft-orchestrator-connector-<platform>.jar`). Vanilla is skipped (can't load plugins/mods). |

The connector source is resolved in order: a per-platform URL
(`ORCHESTRATOR_CONNECTOR_{BUKKIT,FABRIC,FORGE,NEOFORGE}_URL`), then
`ORCHESTRATOR_CONNECTOR_BASE_URL` + naming convention, then
`ORCHESTRATOR_CONNECTOR_URL`, then — by default — the connector repo's Releases
(`ORCHESTRATOR_CONNECTOR_REPO`, default `KojaCraft/orchestrator-connector`;
`ORCHESTRATOR_CONNECTOR_TAG`, default `latest`). A missing connector is
non-fatal — the server still boots.

`server.properties` placeholders `%serverPort%` / `%serverIp%` / `%serverName%`
are substituted exactly like the orchestrator's `resource_manager.patch_server`,
and `data.yml` / `game.json` are (re)written so existing orchestrator plugins
keep working.

## Environment

| Var | Default | Meaning |
|---|---|---|
| `TYPE` | `VANILLA` | `VANILLA` \| `PAPER` \| `SPIGOT` \| `BUKKIT` \| `FORGE` \| `FABRIC` \| `NEOFORGE` \| `QUILT` |
| `VERSION` | `latest` | MC version, or `latest` / `latest-snapshot` |
| `LOADER_VERSION` | auto | loader build; auto-resolved if unset |
| `INSTALLER_VERSION` / `QUILT_INSTALLER_VERSION` | latest | Fabric/Quilt installer |
| `EULA` | `false` | must be `true` |
| `PORT` / `SERVER_PORT` | `25565` | game port (orchestrator sets `PORT`) |
| `SERVER_NAME`, `TEMPLATE`, `MAP` | — | orchestrator identity |
| `ONLINE_MODE` | `false` | behind the proxy |
| `ENABLE_RCON`, `RCON_PORT`, `RCON_PASSWORD` | `true` / `25575` / — | RCON; password required when enabled |
| `MAX_MEMORY` / `INIT_MEMORY` | auto (cgroup) | heap sizing |
| `USE_AIKAR_FLAGS` | `true` | Aikar's GC flags |
| `JVM_OPTS` | — | extra JVM args |
| `STOP_DURATION` | `60s` | graceful shutdown window |
| `FORCE_REINSTALL` | `false` | re-provision even if `/data` already has a server |

## Orchestrator integration

The client launches this image with the prepared dir mounted at `/data` and sets
`TYPE`/`VERSION`/`LOADER_VERSION` from the sync packet's `options`
(`{"type":"FABRIC","version":"1.20.1"}`), plus `SERVER_NAME`, `PORT`,
`TEMPLATE`, `EULA`, `ENABLE_RCON`, `RCON_PASSWORD`. The image to use is
`docker.default_image` in the orchestrator config (defaults to
`KojaCraft/minecraft-server:latest`).

The orchestrator integration is entirely optional — without any `ORCHESTRATOR_*`
env or `/data` overlay, the image is a standalone, general-purpose multi-loader
Minecraft server.

## License

MIT — see [LICENSE](LICENSE).

