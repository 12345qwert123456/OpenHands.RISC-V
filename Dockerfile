# syntax=docker/dockerfile:1.7

# =============================================================================
# RISC-V (riscv64) Dockerfile for OpenHands Agent Canvas
#
# Build strategy:
#   - Backend : the openhands-* distributions are pure py3-none-any wheels, so
#               they are installed natively into a venv on riscv64. Only their
#               transitive Rust/C dependencies are actually compiled here.
#   - Frontend: taken from the official AMD64 image with no RUN commands in
#               that stage, so QEMU is never needed for it and Vite / Rollup /
#               lightningcss never have to run on riscv64 at all.
#   - Entrypoint: upstream's own docker/entrypoint.sh is reused unchanged. It
#               already has a "source build" branch that starts the server from
#               /agent-server/.venv, which is exactly what stage 1 produces, so
#               there is nothing to patch.
#
# Upstream's own Dockerfile cannot be used here: its final stage is
# FROM ghcr.io/openhands/agent-server:<v>-python, which has no riscv64
# manifest, and that image is itself built from a uv-managed
# python-build-standalone runtime plus a PyInstaller binary — neither of which
# exists for riscv64.
# =============================================================================

# Versions are the ones upstream pins in config/defaults.json for a given
# release. Keep all three in sync: the frontend bundle from AGENT_CANVAS_TAG
# talks to the agent-server REST API built from AGENT_SERVER_VERSION.
ARG AGENT_SERVER_VERSION=1.44.1
ARG AUTOMATION_VERSION=1.10.0
ARG AGENT_CANVAS_TAG=1.16.0

# =============================================================================
# Stage 1 — Python builder (runs natively on the target platform: riscv64)
# =============================================================================
FROM debian:trixie-slim AS python_builder
ARG AGENT_SERVER_VERSION
ARG AUTOMATION_VERSION

# Parallel compile jobs. Deliberately low by default: the peak RSS of this
# stage is set by how many rustc/cc processes run at once, and both plausible
# targets are memory-tight — an 8 GB SBC natively, or a QEMU VM sharing a
# workstation's RAM. Raise it on a big machine (--build-arg BUILD_JOBS=8);
# lower it to 1 if the build gets OOM-killed.
ARG BUILD_JOBS=2

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore \
    CARGO_NET_GIT_FETCH_WITH_CLI=true \
    CARGO_BUILD_JOBS=${BUILD_JOBS} \
    MAKEFLAGS=-j${BUILD_JOBS} \
    MAX_JOBS=${BUILD_JOBS} \
    GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS=${BUILD_JOBS} \
    CARGO_PROFILE_RELEASE_DEBUG=false

# Debian trixie is an officially released riscv64 port, which is what makes
# this stage possible at all: python3 3.13 and a full C toolchain are available
# as normal packages.
#
# Rust is the exception. Trixie ships rustc 1.85, and a first full build run
# proved that is too old for the current dependency graph: orjson 3.12 needs
# 1.95, litellm's Rust bridge and lmnr-claude-code-proxy pull aws-sdk crates
# needing 1.91-1.94, and tiktoken 0.14 uses let-chains (stable since 1.87). So
# the toolchain comes from rustup instead — riscv64gc-unknown-linux-gnu is a
# Tier-2 target with host tools, so a current stable is published for it.
#
# PyPI gained riscv64 wheel support in 2025 and coverage is growing (tokenizers,
# pydantic-core, jiter, rpds-py, lxml, blake3, aiohttp all resolve to
# manylinux_*_riscv64 wheels already), but it is still partial. What is
# missing — grpcio, tiktoken, orjson, uvloop, httptools, asyncpg, cryptography,
# Pillow, fastuuid, tree-sitter-bash, … — comes from the RISE riscv64 wheel
# index instead (see the PIP_EXTRA_INDEX_URL note below); cryptography and
# Pillow are compiled from source regardless, and anything neither PyPI nor
# RISE has a wheel for falls back to source too. Either way the C toolchain
# and the -dev headers those builds need are installed up front.
#
# The apt hardening below is not incidental. This stage pulls a full toolchain
# over a link that, behind a proxy or a distant mirror, drops connections under
# load — and a single failed .deb otherwise fails the stage and discards every
# package already fetched. So: retries (upstream's own Dockerfile passes
# -o Acquire::Retries=5 for the same reason), no HTTP pipelining, and BuildKit
# caches for /var/cache/apt and /var/lib/apt/lists so a re-run resumes instead
# of re-downloading. docker-clean has to go, or apt deletes the cached .debs.
#
# Queue-Mode "access" is what keeps that from degenerating: apt's default of one
# queue per host still opens parallel connections, and when the far end starts
# refusing them, each retry re-queues every pending item and logs a warning.
# Observed on a proxied link: ~17k "Tried to start delayed item ... but failed"
# lines and throughput collapsing from 280 kB/s to 53 kB/s. One connection at a
# time is both quieter and, on such a link, faster.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    printf 'Acquire::Retries "10";\nAcquire::http::Pipeline-Depth "0";\nAcquire::Queue-Mode "access";\nAcquire::ForceIPv4 "true";\n' \
        > /etc/apt/apt.conf.d/99-build-robust && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        python3 python3-dev python3-venv \
        build-essential pkg-config cmake ninja-build patchelf \
        libssl-dev libffi-dev zlib1g-dev libpq-dev \
        libjpeg-dev libtiff-dev libwebp-dev libfreetype-dev \
        liblcms2-dev libopenjp2-7-dev

# Current stable Rust via rustup (see the note above for why Debian's 1.85 will
# not do). --profile minimal skips rustfmt/clippy/docs. This is its own layer
# and is baked into the image, so Docker's layer cache reuses it across re-runs
# as long as the apt layer above is unchanged.
ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:${PATH}
RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-connrefused \
      https://sh.rustup.rs -o /tmp/rustup-init.sh && \
    sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
      --default-toolchain stable && \
    rm /tmp/rustup-init.sh && \
    rustc --version && cargo --version

# /agent-server/.venv is not a free choice: upstream's entrypoint.sh probes
# exactly this path to decide that it is looking at a source build.
ENV VIRTUAL_ENV=/agent-server/.venv
ENV PATH=${VIRTUAL_ENV}/bin:${PATH}
RUN python3 -m venv ${VIRTUAL_ENV} && \
    pip install --upgrade pip setuptools wheel

# Where the compiled half of the dependency tree comes from.
#
# PyPI has no riscv64 wheel for grpcio, litellm, cryptography, orjson,
# tiktoken, lmnr-claude-code-proxy, uvloop, asyncpg, Pillow and several more,
# and compiling all of them under QEMU does not fit in GitHub's 6-hour job
# limit (grpcio alone took 4 h 22 min). The RISE project (RISC-V Software
# Ecosystem, Linux Foundation Europe) builds, tests and publishes riscv64
# wheels for them: https://riseproject.gitlab.io/python/wheel_builder/
#
# PIP_PREFER_BINARY makes pip take the newest pre-built wheel that satisfies
# the requirements even when PyPI already has a newer sdist, so a package RISE
# has not caught up on yet arrives a release or so behind PyPI instead of
# costing hours of compilation. pip still only picks versions upstream's
# requirements allow, and the security floor below keeps the lag from ever
# including a known, already fixed vulnerability.
#
# PIP_NO_BINARY is the exception: cryptography and Pillow are always compiled
# here, against Debian's OpenSSL and image libraries. Their manylinux wheels
# carry private copies of those C libraries (checked September 2026: RISE's
# cryptography 50.0.0 bundles OpenSSL 3.5.5 while trixie ships 3.5.7), which
# Debian's security updates never reach and pip-audit cannot see. Both are
# quick to build.
#
# These are pip's own environment variable names: an ARG is visible to RUN as
# an environment variable, so pip reads them directly. For a build entirely
# from PyPI sources, as before:
#   --build-arg PIP_EXTRA_INDEX_URL= --build-arg PIP_PREFER_BINARY=0
ARG PIP_EXTRA_INDEX_URL=https://gitlab.com/api/v4/projects/56254198/packages/pypi/simple
ARG PIP_PREFER_BINARY=1
ARG PIP_NO_BINARY=cryptography,pillow

# Compiler settings for whatever is still built from source. -g0: Debian's
# Python compiles extensions with -g, which made a from-source grpcio wheel
# 160 MB of mostly debug info and slowed every compile and link under QEMU; -O2
# is spelled out because autotools builds take CFLAGS verbatim. The Cargo
# overrides switch off the fat-LTO, single-codegen-unit release profiles of
# orjson, fastuuid and lmnr-claude-code-proxy, whose last step is one long
# single-threaded compile. The GRPC_* switches build grpcio against Debian's
# OpenSSL and zlib instead of its bundled BoringSSL, should it ever need
# compiling here. Declared here rather than with the ENV at the top so that
# changing them does not invalidate the apt and rustup layers.
ENV CFLAGS="-O2 -g0" \
    CXXFLAGS="-O2 -g0" \
    CARGO_PROFILE_RELEASE_LTO=off \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
    GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=1 \
    GRPC_PYTHON_BUILD_SYSTEM_ZLIB=1

# One resolver pass for the whole stack so the shared pins settle once
# (openhands-automation pins openhands-sdk and openhands-workspace exactly).
# The list goes through a file so the security floor below can re-resolve
# exactly the same set.
#
# agent-client-protocol is intentionally NOT pinned here: openhands-sdk
# declares its own compatible range (config/defaults.json used to carry a
# separate constraints.agentClientProtocol — acp 0.11.0 reordered the
# arguments of prompt() and broke older SDK versions' ACP client with a
# PromptRequest validation error — but upstream dropped that key once the SDK
# itself moved to a fixed range; pinning it here ourselves just fights
# whatever range the resolved openhands-sdk version actually declares).
#
# The cache mounts matter far more here than they would on amd64: a build that
# fails halfway under QEMU is otherwise a multi-hour do-over, and the pip wheel
# cache plus the cargo registry cache save a large part of a retry. CARGO_HOME
# is /opt/cargo (set above), so that is where the registry cache mounts.
RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=cache,target=/opt/cargo/registry \
    mkdir -p /opt/build && \
    printf '%s\n' \
        "openhands-agent-server==${AGENT_SERVER_VERSION}" \
        "openhands-sdk[boto3]==${AGENT_SERVER_VERSION}" \
        "openhands-tools==${AGENT_SERVER_VERSION}" \
        "openhands-workspace==${AGENT_SERVER_VERSION}" \
        "openhands-automation==${AUTOMATION_VERSION}" \
        > /opt/build/requirements.txt && \
    pip install -r /opt/build/requirements.txt

# Security floor for PIP_PREFER_BINARY: pip-audit checks every installed
# distribution against PyPI's advisory data, and anything with a released fix
# is lifted to it — from RISE if it has the wheel, compiled from the sdist
# otherwise. The build fails if the audit cannot run or an installable fix does
# not install; a fix the stack's own version caps rule out (a plain PyPI build
# could not install it either) is reported loudly instead. pip-audit lives in a
# throwaway venv, so none of it reaches the image. Details in security-floor.py.
COPY security-floor.py /opt/build/security-floor.py
RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=cache,target=/opt/cargo/registry \
    /usr/bin/python3 -m venv /tmp/audit && \
    /tmp/audit/bin/pip install --quiet pip-audit && \
    /tmp/audit/bin/python /opt/build/security-floor.py && \
    rm -rf /tmp/audit

# Import the four entry points the runtime actually starts, so a broken native
# build fails the image build instead of the first `docker run`.
RUN python -c "import openhands.agent_server, openhands.tools, openhands.workspace, openhands.automation.app"

# =============================================================================
# Stage 2 — Frontend source (AMD64, no RUN commands)
#
# The official image is used only as a file source. Because this stage contains
# no RUN instructions, Docker never executes any AMD64 code — it only pulls the
# layers and copies files out of them. QEMU is NOT required for this stage.
#
# Everything taken from here is architecture-independent:
#   frontend/                 the built React bundle (HTML/JS/CSS)
#   static-server.mjs         ingress proxy + static file server
#   proxy-utils.mjs
#   runtime-services-info.mjs
#   defaults.env              generated from upstream config/defaults.json
#   tools/                    canvas_ui_tool.py compatibility module
#   entrypoint.sh
#   node_modules/             httpxy, sirv, @polka, mrmime, totalist — pure JS
#
# Building the frontend on riscv64 instead is not an option, and the reason is
# missing native binaries rather than anything fixable in the build: Vite 8
# bundles through rolldown, whose @rolldown/binding-* packages cover x64,
# arm64, arm, ppc64 and s390x but not riscv64, and Tailwind v4 pulls in
# lightningcss, which has no riscv64 binary either.
# =============================================================================
FROM --platform=linux/amd64 ghcr.io/openhands/agent-canvas:${AGENT_CANVAS_TAG} AS canvas_source

# =============================================================================
# Stage 3 — Final runtime image (riscv64)
# =============================================================================
FROM debian:trixie-slim
ARG AGENT_SERVER_VERSION
ARG AUTOMATION_VERSION
ARG AGENT_CANVAS_TAG

LABEL org.opencontainers.image.title="openhands-agent-canvas-riscv64"
LABEL org.opencontainers.image.description="Unofficial OpenHands Agent Canvas build for linux/riscv64"
LABEL org.opencontainers.image.source="https://github.com/OpenHands/OpenHands"
LABEL org.opencontainers.image.version="${AGENT_CANVAS_TAG}"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime only. nodejs runs static-server.mjs (which needs nothing newer than
# Node 16 — node:http, node:fs/promises, node:path, node:process, node:url and
# sirv), tmux backs the SDK's bash tool through libtmux, and tini is PID 1.
# The lib* packages are the shared objects the compiled wheels from stage 1
# link against.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    printf 'Acquire::Retries "10";\nAcquire::http::Pipeline-Depth "0";\nAcquire::Queue-Mode "access";\nAcquire::ForceIPv4 "true";\n' \
        > /etc/apt/apt.conf.d/99-build-robust && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl wget git jq sudo tini tmux \
        coreutils util-linux procps findutils grep sed tar xz-utils \
        python3 nodejs \
        openssl libpq5 libffi8 zlib1g \
        libjpeg62-turbo libtiff6 libwebp7 libfreetype6 \
        liblcms2-2 libopenjp2-7

# Same user, uid and gid as the official image, so bind-mounted host data
# written by one image stays usable by the other.
ARG USERNAME=openhands
ARG UID=10001
ARG GID=10001
RUN groupadd -g ${GID} ${USERNAME} && \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME} && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /workspace/project && \
    chown -R ${USERNAME}:${USERNAME} /workspace

# The venv moves as-is: stage 1 and stage 3 share the same base image, so the
# interpreter symlink in pyvenv.cfg and the shebangs in .venv/bin stay valid.
COPY --from=python_builder --chown=${USERNAME}:${USERNAME} /agent-server /agent-server

# The whole Node/frontend side of the image, straight from the AMD64 stage.
COPY --from=canvas_source /opt/agent-canvas /opt/agent-canvas

# LC_ALL/LANG must be a UTF-8 locale or tmux rewrites the UTF-8 separator
# characters libtmux parses its formats with, and the bash tool breaks.
ENV PATH=/agent-server/.venv/bin:${PATH} \
    HOME=/home/${USERNAME} \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    LOG_JSON=true \
    OH_EXTRA_PYTHON_PATH=/opt/agent-canvas/tools \
    AGENT_CANVAS_BASE_PATH=/canvas

# The frontend bundle copied above was built with VITE_BASE_PATH=/canvas, and
# AGENT_CANVAS_BASE_PATH has to name the same prefix or the SPA asks for assets
# on a path the static server does not mount. That pairing normally comes from
# the ENV line in upstream's own final stage, which this image does not inherit
# because it is not built FROM the canvas image — hence setting it explicitly.

# Pre-create the persistence tree with the right ownership, so it stays
# writable when Docker fills the VOLUMEs below with root-owned anonymous
# volumes.
RUN mkdir -p /home/${USERNAME}/.openhands/agent-canvas/conversations \
             /home/${USERNAME}/.openhands/agent-canvas/bash_events \
             /home/${USERNAME}/.openhands/automation \
             /projects && \
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.openhands /projects

# The wrapper entrypoint runs as root, aligns the openhands uid/gid with
# USER_UID / USER_GID (so a bind-mounted host directory stays writable without
# a manual chown), fixes ownership of the app's own state dir and then drops to
# the unprivileged user before handing off to upstream's entrypoint. Same
# pattern as the reference RISC-V images. Started with `--user` it skips all of
# that and execs upstream's entrypoint directly.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /

VOLUME ["/home/openhands/.openhands", "/projects"]
EXPOSE 8000

# Generous start period: on riscv64 the Python import graph of agent-server +
# automation takes far longer to warm up than on amd64.
HEALTHCHECK --start-period=300s --interval=30s --timeout=10s \
    CMD curl -fsS "http://127.0.0.1:${PORT:-8000}/alive" || exit 1

ENTRYPOINT ["tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
