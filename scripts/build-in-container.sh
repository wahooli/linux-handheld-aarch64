#!/usr/bin/env bash
#
# Runs inside the builder container, as root, and drops to the build user. Not
# meant to be run on a host -- use scripts/build.sh.
#
# The uid dance is why this file exists. The ALARM rootfs already has `alarm` at
# uid 1000, so `build` lands on 1001; host uids vary, and makepkg writes into the
# bind-mounted repo, so a mismatch is "You do not have write permission for the
# directory $BUILDDIR" and nothing else.
set -euo pipefail

HOST_UID="${HOST_UID:?}"
HOST_GID="${HOST_GID:?}"

if [ "$(id -u build)" != "${HOST_UID}" ] || [ "$(id -g build)" != "${HOST_GID}" ]; then
    # Free the target ids first: alarm:1000 collides on a uid-1000 host.
    existing_u="$(getent passwd "${HOST_UID}" | cut -d: -f1 || true)"
    existing_g="$(getent group  "${HOST_GID}" | cut -d: -f1 || true)"
    # ifs rather than `A && B || true`, where the `|| true` would also swallow a
    # false condition. Only the delete is allowed to fail.
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
# Sync before makepkg --syncdeps goes looking for makedepends: the builder image
# is cached and rebuilt weekly, so by the end of that week its database names
# versions the mirror has already replaced and every fetch 404s. -Syu rather than
# -Sy -- a partial sync installs new packages against old dependencies.
pacman -Syu --noconfirm >/dev/null 2>&1 || pacman -Syu --noconfirm

chown build:build /ccache 2>/dev/null || true
# Split so only the chown may fail (it legitimately does when the directory is
# already owned correctly); as one `mkdir && chown || true` an unwritable /work
# sailed past here and surfaced as an opaque makepkg error.
mkdir -p /work/out
chown build:build /work/out 2>/dev/null || true

# Passed through only when actually set, because CCACHE_NOHASHDIR is
# presence-is-truth: ccache reads it as "disable hash_dir" even when its value is
# the empty string, so a `${VAR:-}` default would silently turn it on for a
# caller that never asked. (There is no positive CCACHE_HASHDIR=false to use
# instead -- ccache rejects that value outright.)
ccache_env=(CCACHE_DIR="${CCACHE_DIR}" CCACHE_MAXSIZE="${CCACHE_MAXSIZE}")
if [ -n "${CCACHE_NOHASHDIR:-}" ]; then
    ccache_env+=(CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR}")
fi
if [ -n "${CCACHE_BASEDIR:-}" ]; then
    ccache_env+=(CCACHE_BASEDIR="${CCACHE_BASEDIR}")
fi

exec setpriv --reuid=build --regid=build --init-groups \
    /usr/bin/env HOME=/home/build \
                 "${ccache_env[@]}" \
                 PACKAGER="${PACKAGER}" \
                 PKGDEST=/work/out \
                 SRCDEST=/work/.cache \
                 SRCNAME="${SRCNAME}" \
                 NOBUILD="${NOBUILD:-}" \
    bash -euo pipefail /work/scripts/makepkg-and-report.sh
