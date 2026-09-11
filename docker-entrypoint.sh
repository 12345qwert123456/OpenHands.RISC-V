#!/bin/sh
# =============================================================================
# Wrapper entrypoint for the RISC-V agent-canvas image.
#
# Upstream's own entrypoint (/opt/agent-canvas/entrypoint.sh) expects to run as
# the unprivileged `openhands` user and does not adjust ownership of the two
# bind-mountable paths. On Docker Desktop that is invisible (it maps host uids
# automatically); on a native Linux host — which is every RISC-V board — a
# directory bind-mounted from the host arrives owned by the host uid, and the
# in-container user (10001) cannot write to it. The automation SQLite database
# and the agent-server persistence dir then both fail to open.
#
# This wrapper closes that gap the same way the other RISC-V images do:
#   1. start as root
#   2. repoint the openhands user/group at USER_UID / USER_GID (default
#      10001:10001 — the image build values)
#   3. take ownership of the app's own home, and of /projects only when it is
#      still root-owned (a fresh hostPath / named volume — not a directory
#      bind-mounted from a real user account, whose ownership must be left be)
#   4. drop privileges and exec upstream's entrypoint
#
# Run with `docker run --user ...` and the wrapper does none of this — it just
# execs upstream's entrypoint as whatever user Docker gave it.
# =============================================================================
set -eu

PUID="${USER_UID:-10001}"
PGID="${USER_GID:-10001}"

if [ "$(id -u)" = "0" ]; then
    if [ "$PGID" != "$(id -g openhands)" ]; then
        groupmod -o -g "$PGID" openhands
    fi
    if [ "$PUID" != "$(id -u openhands)" ]; then
        usermod -o -u "$PUID" openhands
    fi

    # The app writes its state, generated keys, SQLite DB, conversations and
    # caches under /home/openhands.
    chown -R openhands:openhands /home/openhands 2>/dev/null || true

    # /projects: adopt it only when it is still root-owned (fresh hostPath or
    # named volume). A dir bind-mounted from a user account keeps its owner —
    # point USER_UID at that account instead.
    if [ "$(stat -c %u /projects 2>/dev/null || echo 1)" = "0" ]; then
        chown -R openhands:openhands /projects 2>/dev/null || true
    fi

    # setpriv (util-linux) drops to the user without a login shell or a PAM
    # dependency — the same reason the reference images reach for su-exec.
    # Numeric ids so this does not depend on the passwd resolver after usermod.
    exec setpriv --reuid="$PUID" --regid="$PGID" --init-groups \
        /opt/agent-canvas/entrypoint.sh "$@"
fi

exec /opt/agent-canvas/entrypoint.sh "$@"
