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
    # Written as ifs rather than `A && B && C || true`: in that form the `|| true`
    # also swallows a false CONDITION, so it reads as if a missing user were an
    # error being ignored. Only the delete is allowed to fail.
    if [ -n "${existing_u}" ] && [ "${existing_u}" != build ]; then
        userdel -r "${existing_u}" 2>/dev/null || true
    fi
    if [ -n "${existing_g}" ] && [ "${existing_g}" != build ]; then
        groupdel "${existing_g}" 2>/dev/null || true
    fi

    groupmod -g "${HOST_GID}" build
    usermod  -u "${HOST_UID}" -g "${HOST_GID}" build
    chown -R build:build /home/build
fi
# /ccache and /work/out are created by the host and by earlier runs; makepkg
# aborts on either being unwritable, and the message names only one of them at a
# time. Fix both up front rather than discovering them one build at a time.
# Sync the package database before makepkg --syncdeps goes looking for
# makedepends. The builder image is cached and rebuilt weekly, so by the end of
# that week its database names versions the mirror has already replaced:
#     error: failed retrieving file 'simdjson-1:4.6.8-1-aarch64.pkg.tar.xz' ...
#     The requested URL returned error: 404
# -Syu rather than -Sy: a partial sync installs new packages against old
# dependencies, which is the classic way to break an Arch system quietly.
pacman -Syu --noconfirm >/dev/null 2>&1 || pacman -Syu --noconfirm

chown build:build /ccache 2>/dev/null || true
# Split, and that is a fix rather than tidying: as `mkdir && chown || true` the
# `|| true` swallowed a FAILED MKDIR too, so an unwritable /work would sail past
# here and surface later as an opaque makepkg error. Now only the chown may fail
# -- it legitimately does when the directory is already owned correctly.
mkdir -p /work/out
chown build:build /work/out 2>/dev/null || true

exec setpriv --reuid=build --regid=build --init-groups \
    /usr/bin/env HOME=/home/build \
                 CCACHE_DIR="${CCACHE_DIR}" \
                 CCACHE_MAXSIZE="${CCACHE_MAXSIZE}" \
                 PACKAGER="${PACKAGER}" \
                 PKGDEST=/work/out \
                 SRCDEST=/work/.cache \
                 SRCNAME="${SRCNAME}" \
                 NOBUILD="${NOBUILD:-}" \
    bash -euo pipefail /work/scripts/makepkg-and-report.sh
