#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkgver/pkgrel/_* all come from version.env
#
# Build one product's packages in the ALARM builder container, unsigned, into out/.
#   FETCH=1          re-resolve the patch stack first
#   NOBUILD=1        prepare() only: patches + config, no compile
#   PRODUCT=<name>   required while sources.env names more than one product
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-product.sh
source "${HERE}/scripts/lib-product.sh"
lp_load "${HERE}"
lp_lock "${HERE}"

IMAGE="${IMAGE:-linux-handheld-builder:latest}"
# Per product: autoconf.h is force-included everywhere, so objects never share across configs.
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

# A pre-split cache at .ccache/ itself (16 hex dirs) would otherwise sit unused without a word.
if [ -d "${HERE}/.ccache/0" ] && [ ! -d "${CCACHE_DIR}/0" ]; then
    echo "==> note: a pre-split ccache sits at .ccache/ itself, unused now that each"
    echo "    product has its own. To hand it to THIS product (it belongs to whichever"
    echo "    one built it last):"
    echo "      mv ${HERE}/.ccache/[0-9a-f] ${CCACHE_DIR}/"
fi
# Both extensions, so a stale .xz is not published with the new build; NOBUILD keeps out/.
if [ -z "${NOBUILD}" ]; then
    rm -f out/*.pkg.tar.* out/*.sig 2>/dev/null || true
fi

echo "==> makepkg in ${IMAGE}"
# NOHASHDIR: the build dir names the kernel version and -g hashes it into every key, so without it
# a base bump misses on every object. BASEDIR: kbuild compiles tools/ objects with absolute paths.
# Root only to map the build user onto the host uid (scripts/build-in-container.sh).
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
    # NOBUILD is the expected reason; otherwise makepkg succeeded and produced nothing.
    echo " no packages in out/${NOBUILD:+  (NOBUILD=1: prepare() only)}"
fi
echo "──────────────────────────────────────────────"
[ -f "${STAGED_REPORT}" ] && { echo; cat "${STAGED_REPORT}"; }
