#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkgver/pkgrel/_* all come from version.env
#
# Build one product's kernel packages inside the ALARM builder container.
#
#   scripts/build.sh                        build with whatever fetch-patches.sh left
#   FETCH=1 scripts/build.sh                re-resolve the patch stack first
#   PRODUCT=handheld FETCH=1 scripts/build.sh   ...for a specific product
#   NOBUILD=1 scripts/build.sh              run prepare() only, then stop
#
# NOBUILD is the cheap validation: it extracts the tarball, applies the series,
# copies the device trees in and merges the config -- i.e. everything that can
# fail because an upstream moved -- in a few minutes instead of fifty. It is what
# to reach for after a base swap or a patch bump. No packages come out of it.
#
# PRODUCT may be omitted while sources.env names exactly one product. version.env
# records which product it was resolved for, and this refuses to build a product
# against another one's resolved stack -- that mismatch would compile the wrong
# config into a package named for the right one.
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
# shellcheck source=scripts/lib-product.sh
source "${HERE}/scripts/lib-product.sh"
lp_load "${HERE}"
lp_lock "${HERE}"

IMAGE="${IMAGE:-linux-handheld-builder:latest}"
# PER PRODUCT, and not for tidiness. The kernel force-includes kconfig.h (and
# through it include/generated/autoconf.h) into every translation unit
# (Makefile: -include $(srctree)/include/linux/kconfig.h), so any config
# difference changes the preprocessed text of EVERY file. Two products therefore
# share essentially no cache entries, and pointing them at one directory only
# means each build evicts the other's objects. One full arm64 kernel is ~4.5 GiB
# of cache, so a shared 8 GiB cap thrashes with two products and neither gets
# warm.
CCACHE_DIR="${CCACHE_DIR:-${HERE}/.ccache/${PRODUCT}}"
DOCKER="${DOCKER:-docker}"
FETCH="${FETCH:-}"
NOBUILD="${NOBUILD:-}"

[ "$(uname -m)" = "aarch64" ] || {
    echo "!! host is $(uname -m), not aarch64. This builds natively by design;" >&2
    echo "!! cross-building is not wired up. Use an aarch64 runner." >&2
    exit 1
}

if [ -n "${FETCH}" ]; then
    PRODUCT="${PRODUCT}" ./scripts/fetch-patches.sh
fi
if [ ! -f version.env ] || [ ! -f patches/series.generated ]; then
    echo "!! no version.env / patches/series.generated -- run scripts/fetch-patches.sh" >&2
    exit 1
fi

# shellcheck source=/dev/null
source ./version.env

[ "${_product}" = "${PRODUCT}" ] || {
    echo "!! version.env was resolved for product '${_product}', but this run is" >&2
    echo "!! building '${PRODUCT}'. Run FETCH=1 (or scripts/fetch-patches.sh) first." >&2
    exit 1
}
echo "==> product ${_product} -> ${_pkgbase} ${pkgver}-${pkgrel}  (${_kernelsource} ${_kernelref})"

if ! "${DOCKER}" image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "==> building ${IMAGE}"
    "${DOCKER}" build -t "${IMAGE}" .
fi

STAGED_REPORT="${HERE}/.staged-report.md"
mkdir -p out "${CCACHE_DIR}"

# A cache from before the per-product split sits at .ccache/ itself, as ccache's
# own 16 hex subdirectories. Say so once rather than silently starting cold: it
# is several GiB of warm objects belonging to whichever product built it.
#
# Detected by those directories, not by ccache.conf -- ccache keeps its config in
# ~/.config/ccache/, so the cache directory holds only 0..f, lock and tmp.
if [ -d "${HERE}/.ccache/0" ] && [ ! -d "${CCACHE_DIR}/0" ]; then
    echo "==> note: a pre-split ccache sits at .ccache/ itself, unused now that each"
    echo "    product has its own. To hand it to THIS product (it belongs to whichever"
    echo "    one built it last):"
    echo "      mv ${HERE}/.ccache/[0-9a-f] ${CCACHE_DIR}/"
fi
# Glob both extensions: a package built before PKGEXT moved to zst would
# otherwise linger in out/ and get published alongside the new one.
#
# Skipped for NOBUILD, which produces no packages -- clearing out/ there only
# destroys the last real build's output for nothing.
if [ -z "${NOBUILD}" ]; then
    rm -f out/*.pkg.tar.* out/*.sig 2>/dev/null || true
fi

echo "==> makepkg in ${IMAGE}"
# Runs as root only long enough to align the build user's uid with the host's
# (see scripts/build-in-container.sh), then drops privileges immediately.
"${DOCKER}" run --rm \
    -v "${HERE}:/work" \
    -v "${CCACHE_DIR}:/ccache" \
    --user root \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -e CCACHE_DIR=/ccache -e CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-8G}" \
    -e NOBUILD="${NOBUILD}" \
    -e PACKAGER="${PACKAGER:-Waltteri Hooli <1420194+wahooli@users.noreply.github.com>}" \
    -e SRCNAME="${_srcname}" \
    -w /work \
    "${IMAGE}" \
    /work/scripts/build-in-container.sh

echo
echo "──────────────────────────────────────────────"
if compgen -G 'out/*.pkg.tar.zst' > /dev/null; then
    for f in out/*.pkg.tar.zst; do
        printf ' %-56s %6s\n' "$(basename "${f}")" "$(du -h "${f}" | cut -f1)"
    done
else
    # NOBUILD is the expected reason. Anything else means makepkg said it
    # succeeded and produced nothing, which is worth seeing rather than an
    # unquoted glob in an error message.
    echo " no packages in out/${NOBUILD:+  (NOBUILD=1: prepare() only)}"
fi
echo "──────────────────────────────────────────────"
[ -f "${STAGED_REPORT}" ] && { echo; cat "${STAGED_REPORT}"; }
