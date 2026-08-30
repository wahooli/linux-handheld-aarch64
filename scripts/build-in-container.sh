#!/usr/bin/env bash
#
# Runs INSIDE the builder container, as root, and drops to the build user.
# Not meant to be run on a host -- use scripts/build.sh.
#
# The uid dance is the point of this file existing. The ALARM rootfs already has
# an `alarm` user at uid 1000, so the `build` user we add lands on 1001. Host
# uids vary (this dev machine is 1000, GitHub's runners are 1001), and makepkg
# writes into the bind-mounted repo, so a mismatch is "You do not have write
# permission for the directory $BUILDDIR" and nothing else. Aligning at runtime
# is the only thing that works everywhere.
set -euo pipefail

HOST_UID="${HOST_UID:?}"
HOST_GID="${HOST_GID:?}"

if [ "$(id -u build)" != "${HOST_UID}" ] || [ "$(id -g build)" != "${HOST_GID}" ]; then
    # Free the target ids first: alarm:1000 collides on a uid-1000 host.
    existing_u="$(getent passwd "${HOST_UID}" | cut -d: -f1 || true)"
    existing_g="$(getent group  "${HOST_GID}" | cut -d: -f1 || true)"
    [ -n "${existing_u}" ] && [ "${existing_u}" != build ] && userdel -r "${existing_u}" 2>/dev/null || true
    [ -n "${existing_g}" ] && [ "${existing_g}" != build ] && groupdel  "${existing_g}" 2>/dev/null || true

    groupmod -g "${HOST_GID}" build
    usermod  -u "${HOST_UID}" -g "${HOST_GID}" build
    chown -R build:build /home/build
fi
# /ccache and /work/out are created by the host and by earlier runs; makepkg
# aborts on either being unwritable, and the message names only one of them at a
# time. Fix both up front rather than discovering them one build at a time.
chown build:build /ccache 2>/dev/null || true
mkdir -p /work/out && chown build:build /work/out 2>/dev/null || true

exec setpriv --reuid=build --regid=build --init-groups \
    /usr/bin/env HOME=/home/build \
                 CCACHE_DIR="${CCACHE_DIR}" \
                 CCACHE_MAXSIZE="${CCACHE_MAXSIZE}" \
                 PACKAGER="${PACKAGER}" \
                 PKGDEST=/work/out \
                 SRCDEST=/work/.cache \
                 SRCNAME="${SRCNAME}" \
    bash -euo pipefail /work/scripts/makepkg-and-report.sh
