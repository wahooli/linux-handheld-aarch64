#!/usr/bin/env bash
#
# Runs inside the builder as root: maps the build user onto the host uid/gid, then drops to it.
# ALARM's `alarm` holds uid 1000, and a mismatch only shows as a makepkg write-permission error.
set -euo pipefail

HOST_UID="${HOST_UID:?}"
HOST_GID="${HOST_GID:?}"

if [ "$(id -u build)" != "${HOST_UID}" ] || [ "$(id -g build)" != "${HOST_GID}" ]; then
    # Free the target ids first: alarm:1000 collides on a uid-1000 host.
    existing_u="$(getent passwd "${HOST_UID}" | cut -d: -f1 || true)"
    existing_g="$(getent group  "${HOST_GID}" | cut -d: -f1 || true)"
    # ifs, not `A && B || true`, which would also swallow a false condition.
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
# Race the mirrors: the geo-redirector can hand out a KB/s mirror pacman never abandons, and static
# pins swing too. The fastest core.db download goes first; the redirector stays as fallback.
mirrors=(
    de3.mirror.archlinuxarm.org
    dk.mirror.archlinuxarm.org
    uk.mirror.archlinuxarm.org
    fl.us.mirror.archlinuxarm.org
    ca.us.mirror.archlinuxarm.org
    tw.mirror.archlinuxarm.org
    sg.mirror.archlinuxarm.org
    au.mirror.archlinuxarm.org
)
probes="$(mktemp -d)"
for m in "${mirrors[@]}"; do
    curl -m 10 -sLo /dev/null -w '%{speed_download}' \
        "http://${m}/aarch64/core/core.db" > "${probes}/${m}" 2>/dev/null &
done
wait
best="$(for m in "${mirrors[@]}"; do
    # ${speed:-0}: a probe that failed before transferring leaves an empty file.
    speed="$(cat "${probes}/${m}" 2>/dev/null)"
    printf '%s %s\n' "${speed:-0}" "${m}"
done | sort -rn | awk 'NR == 1 && $1 > 0 { print $2 }')"
rm -rf "${probes}"
echo "==> mirror: ${best:-none reachable, geo-redirector only}"
{
    if [ -n "${best}" ]; then
        printf 'Server = http://%s/$arch/$repo\n' "${best}"
    fi
    printf 'Server = http://mirror.archlinuxarm.org/$arch/$repo\n'
} > /etc/pacman.d/mirrorlist
grep -q '^ParallelDownloads' /etc/pacman.conf \
    || sed -i '/^\[options\]/a ParallelDownloads = 5' /etc/pacman.conf

# The cached image's db goes stale within its week; -Syu, not -Sy (a partial upgrade).
pacman -Syu --noconfirm >/dev/null 2>&1 || pacman -Syu --noconfirm

chown build:build /ccache 2>/dev/null || true
# Separate, so only the chown may fail; an unwritable /work must fail here.
mkdir -p /work/out
chown build:build /work/out 2>/dev/null || true

# Only when set: ccache treats CCACHE_NOHASHDIR as true even when it is empty.
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
