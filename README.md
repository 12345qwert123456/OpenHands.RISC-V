# OpenHands Agent Canvas on RISC-V (riscv64)

![Platform](https://img.shields.io/badge/platform-linux%2Friscv64-blue)
![Base](https://img.shields.io/badge/base-debian%20trixie-a80030)
![License](https://img.shields.io/badge/license-MIT-green)

Community Docker image for running [OpenHands Agent Canvas](https://github.com/OpenHands/OpenHands)
— the self-hosted control center for OpenHands, Claude Code, Codex and Gemini coding agents —
on `linux/riscv64` hardware (OrangePi RV2, StarFive VisionFive 2, Milk-V, QEMU riscv64).

The official `ghcr.io/openhands/agent-canvas` image publishes only `linux/amd64` and
`linux/arm64`, and a straight rebuild for `riscv64` fails in several independent places at
once — the base image, the Python runtime, the release binary and the frontend bundler each
have their own blocker (see [Why not upstream](#why-not-upstream)). This image works around
all of them, with no patches to upstream source.

New OpenHands releases are detected daily and built automatically.

## Quick start

```bash
docker pull 12345qwert123456/openhands-riscv64:latest
```

```bash
mkdir -p ~/openhands-data ~/projects
docker run -d --name openhands \
  -p 8000:8000 \
  -e USER_UID=$(id -u) -e USER_GID=$(id -g) \
  -v ~/openhands-data:/home/openhands/.openhands \
  -v ~/projects:/projects \
  12345qwert123456/openhands-riscv64:latest
```

Open **http://localhost:8000/canvas/**. On first start the image generates an API key and a
settings-encryption key and persists both under `~/openhands-data/agent-canvas/`; the key is
injected into the served HTML automatically (it is also in
`~/openhands-data/agent-canvas/api-key.txt`). Mount the code you want the agent to work on at
`/projects`.

## How it works

The build has three stages.

### Stage 1 — Python builder (runs natively on riscv64)

All five OpenHands distributions — `openhands-agent-server`, `openhands-sdk`,
`openhands-tools`, `openhands-workspace`, `openhands-automation` — are published on PyPI as
pure `py3-none-any` wheels, so they need no porting. What gets compiled is their transitive
Rust/C dependencies, built here into a venv at **`/agent-server/.venv`** — the exact path
upstream's `entrypoint.sh` probes to recognise a *source build*, which is what lets the
original entrypoint be reused unmodified.

PyPI's riscv64 wheel coverage has grown a lot (`tokenizers`, `pydantic-core`, `jiter`,
`rpds-py`, `lxml`, `blake3`, `aiohttp`, `websockets` all resolve to `manylinux_*_riscv64`
wheels), but it is still partial. `grpcio`, `cryptography`, `orjson`, `tiktoken`, `uvloop`,
`asyncpg`, `pillow`, `httptools`, `fastuuid` and a few more are compiled from source.
Debian's rustc 1.85 is too old for some of them (`orjson` wants 1.95, `litellm`'s Rust
bridge 1.94, `tiktoken` 1.87), so the stage installs a current stable via rustup —
`riscv64gc-unknown-linux-gnu` is a Tier-2 target with host tools.

### Stage 2 — Frontend source (AMD64, zero RUN commands)

The official AMD64 image is used **only as a file source**. This stage has no `RUN`
instructions, so Docker never executes any AMD64 code — it just pulls the layers and copies
files out. **QEMU is not required for this stage.** The whole `/opt/agent-canvas` tree is
architecture-independent: the built React bundle, the `static-server.mjs` ingress proxy and
its helpers, upstream's `entrypoint.sh`, the `canvas_ui_tool.py` compat module, and the
handful of pure-JS runtime deps (`httpxy`, `sirv`, `@polka`, `mrmime`, `totalist`).

Building the frontend on riscv64 instead is not possible: Vite 8 bundles through `rolldown`,
whose `@rolldown/binding-*` packages cover x64/arm64/arm/ppc64/s390x but not riscv64, and
Tailwind v4 pulls in `lightningcss`, which has no riscv64 binary either.

### Stage 3 — Final runtime image (riscv64)

A `debian:trixie-slim` image with `python3`, `nodejs`, `tmux`, `git` and `tini`. The venv
from stage 1 is copied across as-is (same base image → the interpreter symlink and shebangs
stay valid). A small wrapper entrypoint aligns the in-container `openhands` user with
`USER_UID`/`USER_GID` and fixes ownership of the state dir before dropping privileges, so a
bind-mounted host directory just works on a native Linux host.

## Build

The **same Dockerfile builds both natively on a riscv64 board and under QEMU** — nothing in
it is conditional on how it runs. Stage 2 pulls the AMD64 image's layers and copies files out
without executing anything, either way.

### Native build on riscv64 hardware

```bash
docker build -t openhands-riscv64 .
```

> **Budget most of a day for the first build.** A measured run on an OrangePi RV2 spent
> **~6 hours** in stage 1, and `grpcio` alone — a large C++ build with no riscv64 wheel —
> accounted for about 4 of them; `cryptography`, `fastuuid`, `uvloop`, `asyncpg` and `pillow`
> are the next slowest. The board's cores are the limit. A BuildKit cache is mounted for
> pip's wheel cache, so an interrupted or failed build resumes near where it stopped — re-run
> the same command.

### Cross-building from x86-64 with QEMU

```bash
docker run --privileged --rm tonistiigi/binfmt --install riscv64
docker buildx create --name riscv --driver docker-container --use
docker buildx build --platform linux/riscv64 --load -t openhands-riscv64 .
```

Slower than the native build, not faster — emulated compilation of the C and Rust extensions
is the bottleneck. Add `--progress=plain` to watch it; `--target python_builder` builds only
the compile-heavy stage.

### Memory and disk

Stage 1 peak memory is set by how many `rustc`/`cc` run at once — the `BUILD_JOBS` build arg
(default `2`). On an 8 GB board that lands around 3–5 GB; **add 8 GB of swap or zram** so a
big `rustc` link does not get OOM-killed hours in. Budget **~20 GB of free disk** (apt
packages unpack to 1.4 GB, rustup ~1 GB, cargo build dirs several more, plus image layers) —
build on an SSD rather than an SD card if you can.

```bash
docker build --build-arg BUILD_JOBS=8 -t openhands-riscv64 .   # lots of RAM
docker build --build-arg BUILD_JOBS=1 -t openhands-riscv64 .   # if OOM-killed
```

### Pinning a different release

The three versions are build args; their defaults are the values upstream pins in
[`config/defaults.json`](https://github.com/OpenHands/OpenHands/blob/main/config/defaults.json).
Take all three from the **same** release:

```bash
docker build \
  --build-arg AGENT_CANVAS_TAG=1.16.0 \
  --build-arg AGENT_SERVER_VERSION=1.44.1 \
  --build-arg AUTOMATION_VERSION=1.10.0 \
  -t openhands-riscv64 .
```

## Run

```bash
docker run -it --rm \
  -p 8000:8000 \
  -e USER_UID=$(id -u) -e USER_GID=$(id -g) \
  -v ~/openhands-data:/home/openhands/.openhands \
  -v ~/projects:/projects \
  openhands-riscv64
```

Startup logs should show `Starting agent-server on port 18000`, `Starting automation server
on port 18001`, then `All services started. Unified entry point: http://0.0.0.0:8000/`.
`agent-server` takes noticeably longer to warm up on riscv64 than on amd64 — the healthcheck
allows 5 minutes.

### docker-compose

```yaml
services:
  openhands:
    image: 12345qwert123456/openhands-riscv64:latest
    restart: unless-stopped
    ports:
      - "8000:8000"
    environment:
      - USER_UID=1000        # match your host user
      - USER_GID=1000
      - VITE_DO_NOT_TRACK=1   # optional, disables PostHog telemetry
    volumes:
      - ./openhands-data:/home/openhands/.openhands
      - ./projects:/projects
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `USER_UID` / `USER_GID` | `10001` | uid/gid the services run as. Set to your host user so bind-mounted dirs stay writable. |
| `PORT` | `8000` | Unified entry point — frontend, agent-server and automation are proxied behind it. |
| `LOCAL_BACKEND_API_KEY` | auto-generated | API key for both backends; persisted to `agent-canvas/api-key.txt`. |
| `OH_SECRET_KEY` | auto-generated | Settings/secrets encryption key; persisted to `agent-canvas/secret-key.txt`. |
| `AGENT_CANVAS_BASE_PATH` | `/canvas` | Path the UI is mounted at. Must match the bundle's baked `VITE_BASE_PATH`. |
| `AUTOMATION_DB_URL` | SQLite under `~/.openhands` | Point at PostgreSQL for a production deployment. |
| `VITE_DO_NOT_TRACK` | unset | Set to `1` to disable the PostHog telemetry the entrypoint otherwise enables. |

Any other `OH_*` / `AUTOMATION_*` variable the agent-server or automation service understands
is passed straight through.

## Tested on

- **OrangePi RV2** (Ky X1, 8-core RISC-V, 8 GB) — image built natively on the board and runs:
  all three services come up and the web UI at `/canvas/` is functional. OpenHands `v1.16.0`
  (agent-canvas 1.16.0 / agent-server 1.44.1 / automation 1.10.0), Node.js 20, Python 3.13.

## Known limitations

- **VSCode Web is not available.** `openvscode-server` publishes releases only for
  x64/arm64/armhf. The `/vscode` route answers 502 and the editor button in the UI does
  nothing.
- **The browser tool is not available.** Debian trixie has no `chromium` for riscv64 and
  `browser-use-core` publishes wheels only for x86_64/aarch64. `browser_use` is imported
  lazily and the SDK probes for Chromium first, so the agent-server starts fine — the failure
  only surfaces if something actually asks for a browser.
- **ACP providers (Claude Code, Codex, Gemini CLI) are not pre-installed.** Upstream installs
  them onto an official Node.js tarball whose build stage aborts on any non-x86_64/arm64
  architecture. They can be added by hand with Debian's `npm` inside the container (untested).
- **Docker-in-Docker is not set up** — `download.docker.com` has no riscv64 packages; use
  Debian's `docker.io` if you need it.
- **The frontend comes from the AMD64 image**, pinned by `AGENT_CANVAS_TAG`, and must match
  `AGENT_SERVER_VERSION` / `AUTOMATION_VERSION` from the same upstream release.
- **The first build is long** — everything without a riscv64 wheel is compiled from source.

## Why not upstream?

The blockers for an official riscv64 image, in the order a rebuild hits them:

1. **No riscv64 base image.** `docker/Dockerfile` ends with
   `FROM ghcr.io/openhands/agent-server:<version>-python`, which has no riscv64 manifest — and
   that image is itself built from `nikolaik/python-nodejs:...-slim`, which has none either.
2. **`uv python install` has nothing to install.** The agent-server image builds its venv
   against a uv-managed `python-build-standalone` runtime, which publishes no riscv64 build.
3. **The release binary is x86_64/arm64 only** — production images ship a PyInstaller-built
   `openhands-agent-server`. This image uses the source-build path instead.
4. **The ACP provider stage refuses to run** — it fails closed with *"Unsupported
   architecture for ACP providers"* because Node.js publishes no riscv64 tarballs.
5. **`openvscode-server` and Chromium have no riscv64 builds**, so two of the three optional
   capabilities in upstream's `base-image` stage cannot be installed.
6. **The frontend does not bundle on riscv64** — neither `rolldown` (Vite 8's bundler) nor
   `lightningcss` (Tailwind v4) publishes a riscv64 native binary.

This image avoids 1–4 and 6 entirely and documents 5 as a known limitation.

## CI/CD

The workflow (`.github/workflows/build.yml`):

- runs daily at 04:00 UTC (and on manual trigger)
- reads the latest OpenHands release tag, then the three interdependent versions from
  `config/defaults.json` at that tag
- skips if a `<tag>-riscv64` GitHub Release already exists
- builds the `linux/riscv64` image under QEMU with GitHub Actions layer cache
- smoke-tests it (riscv64 arch, the full Python stack imports, frontend + Node present)
- pushes to Docker Hub and creates a GitHub Release

Trigger a specific version or a forced rebuild via **workflow_dispatch**.

> The emulated build is heavy — `grpcio` alone is a multi-hour compile — and a cold run can
> hit the 6-hour GitHub-hosted job limit. `cache-to: gha,mode=max` lets the next scheduled
> run resume; for a reliable one-shot build, register a riscv64 self-hosted runner (an
> OrangePi RV2 works) and point `runs-on` at it.

### Required repository settings

| Type | Name | Description |
|---|---|---|
| Variable | `DOCKERHUB_USERNAME` | Docker Hub username. If unset, the build and smoke-test still run; only the push is skipped. |
| Secret | `DOCKERHUB_TOKEN` | Docker Hub access token |

## Versions

| Component | Version | Source |
|---|---|---|
| OpenHands | `v1.16.0` (auto-detected) | GitHub Releases |
| agent-canvas / agent-server / automation | `1.16.0` / `1.44.1` / `1.10.0` | `config/defaults.json` |
| Base image | `debian:trixie-slim` | Debian riscv64 port |
| Python | 3.13 | Debian |
| Node.js | 20 | Debian |
| Rust | current stable | rustup |

## License

OpenHands Agent Canvas is [MIT-licensed](https://github.com/OpenHands/OpenHands/blob/main/LICENSE);
the build files in this repository are released under the same terms.
