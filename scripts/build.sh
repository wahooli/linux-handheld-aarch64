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
# NOBUILD is the cheap validation after a base swap or patch bump: everything
# that can fail because an upstream moved, in a few minutes instead of fifty. No
# packages come out of it.
#
# PRODUCT may be omitted while sources.env names exactly one product. Building
# one product against another's resolved stack is refused -- that mismatch
# compiles the wrong config into a package named for the right one.
#
# Output lands in out/, unsigned; scripts/publish-r2.sh signs it outside the
# container, so no signing key is ever handed to the build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-product.sh
source "${HERE}/scripts/lib-product.sh"
lp_load "${HERE}"
lp_lock "${HERE}"

IMAGE="${IMAGE:-linux-handheld-builder:latest}"
# Per product, and not for tidiness. autoconf.h is force-included into every
# translation unit, so no direct-mode lookup ever matches across products; only a
# file whose PREPROCESSED text is config-independent can share, through ccache's
# cpp-mode fallback, and these two configs differ in thousands of symbols. A
# shared directory would mostly mean each build evicting the other's ~4.5 GiB.
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
# 16 hex subdirectories -- several GiB of warm objects. Say so rather than
# silently starting cold. (Detected by those directories, not ccache.conf, which
# lives in ~/.config/ccache/.)
if [ -d "${HERE}/.ccache/0" ] && [ ! -d "${CCACHE_DIR}/0" ]; then
    echo "==> note: a pre-split ccache sits at .ccache/ itself, unused now that each"
    echo "    product has its own. To hand it to THIS product (it belongs to whichever"
    echo "    one built it last):"
    echo "      mv ${HERE}/.ccache/[0-9a-f] ${CCACHE_DIR}/"
fi
# Glob both extensions: a package built before PKGEXT moved to zst would
# otherwise linger in out/ and get published alongside the new one. Skipped for
# NOBUILD, which would only destroy the last real build's output.
if [ -z "${NOBUILD}" ]; then
    rm -f out/*.pkg.tar.* out/*.sig 2>/dev/null || true
fi

echo "==> makepkg in ${IMAGE}"
# CCACHE_NOHASHDIR is what makes the cache survive a base bump. makepkg extracts
# to $srcdir/$_srcname, so the build directory carries the kernel version
# (/work/src/cachyos-7.2.3-1), and ccache hashes the working directory into every
# key whenever -g is in play -- which it always is here, since DEBUG_INFO_BTF
# needs real debug info. Without this, 7.2.2 -> 7.2.3 missed on all ~11k objects
# and turned a 13-minute incremental into a 58-minute cold build.
#
# The cost is that a cache-hit object's DW_AT_comp_dir names whichever directory
# first populated the entry. That affects source-path resolution in a debugger
# and nothing else -- not BTF generation, not resolve_btfids, not module linking.
#
# BASEDIR rewrites absolute paths under /work to relative ones, which is what
# the tools/ objects need: kbuild compiles those with absolute paths.
#
# Root only long enough to align the build user's uid with the host's (see
# scripts/build-in-container.sh), then drops privileges.
"${DOCKER}" run --rm \
    -v "${HERE}:/work" \
    -v "${CCACHE_DIR}:/ccache" \
    --user root \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -e CCACHE_DIR=/ccache -e CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-8G}" \
    -e CCACHE_NOHASHDIR=1 -e CCACHE_BASEDIR=/work \
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
    # NOBUILD is the expected reason; anything else means makepkg claimed success
    # and produced nothing.
    echo " no packages in out/${NOBUILD:+  (NOBUILD=1: prepare() only)}"
fi
echo "──────────────────────────────────────────────"
[ -f "${STAGED_REPORT}" ] && { echo; cat "${STAGED_REPORT}"; }
