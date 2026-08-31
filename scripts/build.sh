#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkgver/pkgrel/_* all come from version.env
#
# Build the kernel packages inside the ALARM builder container.
#
#   scripts/build.sh                 build with whatever fetch-patches.sh left
#   FETCH=1 scripts/build.sh         re-resolve the patch stack first
#
# Output lands in out/, unsigned. The container runs as an unprivileged user
# with the repo bind-mounted, so nothing here needs root on the host.
#
# Signing deliberately does NOT happen here -- scripts/publish-r2.sh does it,
# outside the container. Handing a signing key to a container that is also
# running an upstream build system is a larger trust boundary than it needs to
# be, and the key is only ever needed at publish time anyway.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

IMAGE="${IMAGE:-linux-handheld-builder:latest}"
CCACHE_DIR="${CCACHE_DIR:-${HERE}/.ccache}"
DOCKER="${DOCKER:-docker}"
FETCH="${FETCH:-}"

[ "$(uname -m)" = "aarch64" ] || {
    echo "!! host is $(uname -m), not aarch64. This builds natively by design;" >&2
    echo "!! cross-building is not wired up. Use an aarch64 runner." >&2
    exit 1
}

if [ -n "${FETCH}" ]; then
    ./scripts/fetch-patches.sh
fi
if [ ! -f version.env ] || [ ! -f patches/series.generated ]; then
    echo "!! no version.env / patches/series.generated -- run scripts/fetch-patches.sh" >&2
    exit 1
fi

# shellcheck source=/dev/null
source ./version.env

if ! "${DOCKER}" image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "==> building ${IMAGE}"
    "${DOCKER}" build -t "${IMAGE}" .
fi

STAGED_REPORT="${HERE}/.staged-report.md"
mkdir -p out "${CCACHE_DIR}"
# Glob both extensions: a package built before PKGEXT moved to zst would
# otherwise linger in out/ and get published alongside the new one.
rm -f out/*.pkg.tar.* out/*.sig 2>/dev/null || true

echo "==> makepkg in ${IMAGE}"
# Runs as root only long enough to align the build user's uid with the host's
# (see scripts/build-in-container.sh), then drops privileges immediately.
"${DOCKER}" run --rm \
    -v "${HERE}:/work" \
    -v "${CCACHE_DIR}:/ccache" \
    --user root \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -e CCACHE_DIR=/ccache -e CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-8G}" \
    -e PACKAGER="${PACKAGER:-Waltteri Hooli <1420194+wahooli@users.noreply.github.com>}" \
    -e SRCNAME="${_srcname}" \
    -w /work \
    "${IMAGE}" \
    /work/scripts/build-in-container.sh

echo
echo "──────────────────────────────────────────────"
for f in out/*.pkg.tar.zst; do
    printf ' %-56s %6s\n' "$(basename "${f}")" "$(du -h "${f}" | cut -f1)"
done
echo "──────────────────────────────────────────────"
[ -f "${STAGED_REPORT}" ] && { echo; cat "${STAGED_REPORT}"; }
