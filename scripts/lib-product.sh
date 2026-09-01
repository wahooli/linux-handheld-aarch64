#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
#
# SC2034 is disabled for the whole file on purpose: setting variables for other
# scripts to read IS the job here. Every "unused" assignment below (PRODUCT_DESC,
# USE_ARMADA, USE_ROCKNIX, SRC_TOPDIR, ...) is consumed by fetch-patches.sh, the
# PKGBUILD or publish-r2.sh, and shellcheck cannot see across that boundary.
#
# Product resolution, shared by every script that needs to know WHAT is being
# built. Sourced, never executed.
#
#   . scripts/lib-product.sh          # resolves $PRODUCT and loads its conf
#
# Resolution order, loudest last:
#
#   sources.env                       refs and defaults shared by all products
#   products/$PRODUCT.conf            everything this product decides itself
#   *_OVERRIDE environment variables  CI inputs and one-off experiments
#
# Applied here once rather than per script, so fetch-patches.sh, next-pkgrel.sh
# and publish-r2.sh cannot disagree about which product they are looking at.

# ---------------------------------------------------------------------------
# Which product
# ---------------------------------------------------------------------------
# $PRODUCT wins; otherwise PRODUCTS must name exactly one. Two products and no
# choice is an error, not a default: the wrong guess builds one kernel and
# publishes it under the other's name.
lp_load() {
    local here="$1"
    cd "${here}" || { echo "!! cannot cd to ${here}" >&2; return 1; }

    [ -f sources.env ] || { echo "!! no sources.env in ${here}" >&2; return 1; }
    # shellcheck source=/dev/null
    source ./sources.env

    if [ -z "${PRODUCT:-}" ]; then
        # shellcheck disable=SC2206
        local -a all=(${PRODUCTS:-})
        if [ ${#all[@]} -eq 1 ]; then
            PRODUCT="${all[0]}"
        elif [ ${#all[@]} -eq 0 ]; then
            echo "!! sources.env sets no PRODUCTS" >&2; return 1
        else
            echo "!! PRODUCTS names ${#all[@]} products (${PRODUCTS}); set PRODUCT=<name>" >&2
            return 1
        fi
    fi

    local conf="products/${PRODUCT}.conf"
    [ -f "${conf}" ] || { echo "!! no ${conf} for PRODUCT='${PRODUCT}'" >&2; return 1; }

    # Cleared before sourcing, so a stale environment cannot pass for a setting
    # the conf makes. All of these are documented in products/handheld.conf.
    PRODUCT_DESC=; PRODUCT_BOARDS=; PKGBASE=; KERNEL_SOURCE=; KERNEL_REF=
    CONFIG_DIRS=(); CONFIG_BASE=; SERIES=; SERIES_DENY=(); SERIES_EXTRA=()
    REPLACE_STOCK_KERNEL=; CACHY_SCHED=
    USE_OGC=; USE_ARMADA=; USE_ROCKNIX=; TAG_PREFIX=
    KERNEL_IMAGE=; KERNEL_IMAGE_DEST=; INITRAMFS_IMAGE=; INITRAMFS_FALLBACK=
    DTB_DEST=
    # Board device trees and the staged set. Arrays, so they are reset rather
    # than blanked -- a leftover DTS from an earlier lp_load in the same shell
    # would be copied into the tree and registered in the qcom Makefile.
    DTS=(); DTS_DELTA=(); DTB=(); ROCKNIX_STAGED=(); ROCKNIX_DIRS=()
    # BASE_VERSION is the one name that exists in BOTH files: the global in
    # sources.env is an escape hatch across all products, the per-product one
    # pins just this product. Save the global, let the conf set its own, then
    # decide.
    local base_global="${BASE_VERSION:-}"
    BASE_VERSION=
    # shellcheck source=/dev/null
    source "./${conf}"
    BASE_VERSION="${BASE_VERSION:-${base_global}}"

    # ---- environment overrides --------------------------------------------
    # KERNEL_SOURCE_OVERRIDE builds the same series against a different base
    # without editing the conf. Pair it with KERNEL_REF_OVERRIDE: the two sources
    # name their bases differently (cachyos-7.2.2-1 vs 7.2.2).
    KERNEL_SOURCE="${KERNEL_SOURCE_OVERRIDE:-${KERNEL_SOURCE}}"
    KERNEL_REF="${KERNEL_REF_OVERRIDE:-${KERNEL_REF}}"
    BASE_VERSION="${BASE_VERSION_OVERRIDE:-${BASE_VERSION}}"
    OGC_REF="${OGC_REF_OVERRIDE:-${OGC_REF:-}}"
    ARMADA_REF="${ARMADA_REF_OVERRIDE:-${ARMADA_REF:-}}"
    ROCKNIX_REF="${ROCKNIX_REF_OVERRIDE:-${ROCKNIX_REF:-}}"
    USE_OGC="${USE_OGC_OVERRIDE:-${USE_OGC}}"
    CACHY_SCHED="${CACHY_SCHED_OVERRIDE-${CACHY_SCHED}}"

    # ---- validation -------------------------------------------------------
    [ -n "${PKGBASE}" ] || { echo "!! ${conf}: PKGBASE is empty" >&2; return 1; }
    case "${KERNEL_SOURCE}" in
        cachyos|kernel.org) ;;
        '') echo "!! ${conf}: KERNEL_SOURCE is empty" >&2; return 1 ;;
        *)  echo "!! ${conf}: KERNEL_SOURCE='${KERNEL_SOURCE}' is not 'cachyos' or 'kernel.org'" >&2; return 1 ;;
    esac
    [ ${#CONFIG_DIRS[@]} -gt 0 ] || { echo "!! ${conf}: CONFIG_DIRS is empty" >&2; return 1; }
    local d
    for d in "${CONFIG_DIRS[@]}"; do
        [ -d "config/${d}" ] || { echo "!! ${conf}: CONFIG_DIRS names config/${d}, which does not exist" >&2; return 1; }
        compgen -G "config/${d}/*.config" >/dev/null \
            || { echo "!! ${conf}: config/${d}/ holds no *.config fragments" >&2; return 1; }
    done
    # SERIES is either the literal `armada` or a path to a local file. Checked
    # here so a typo ("armda") is a one-second failure rather than a fetch that
    # 404s halfway through a build.
    case "${SERIES}" in
        '')     echo "!! ${conf}: SERIES is empty" >&2; return 1 ;;
        armada) [ "${USE_ARMADA}" = yes ] || {
                    echo "!! ${conf}: SERIES=armada but USE_ARMADA=${USE_ARMADA:-no}" >&2; return 1; } ;;
        *)      [ -f "${SERIES}" ] || {
                    echo "!! ${conf}: SERIES names ${SERIES}, which does not exist" >&2; return 1; } ;;
    esac
    [ ${#SERIES_DENY[@]} -eq 0 ] || [ "${SERIES}" = armada ] \
        || { echo "!! ${conf}: SERIES_DENY only applies to SERIES=armada" >&2; return 1; }
    # A DTS with no delta is fine; a delta with no DTS is a copy-paste leftover
    # that would apply a patch to a file nothing fetched.
    [ ${#DTS_DELTA[@]} -eq 0 ] || [ ${#DTS[@]} -gt 0 ] \
        || { echo "!! ${conf}: DTS_DELTA is set but DTS is empty" >&2; return 1; }
    [ -n "${TAG_PREFIX}" ] || TAG_PREFIX="${PRODUCT}/v"

    # `defconfig` means `make ARCH=arm64 defconfig`; anything else is a path to a
    # full .config to start from, which is what a product replacing a distro
    # kernel wants -- arm64 defconfig is nowhere near a distro config, and the
    # difference is thousands of symbols.
    CONFIG_BASE="${CONFIG_BASE:-defconfig}"
    if [ "${CONFIG_BASE}" != defconfig ]; then
        [ -f "${CONFIG_BASE}" ] \
            || { echo "!! ${conf}: CONFIG_BASE names ${CONFIG_BASE}, which does not exist" >&2; return 1; }
        # A base config inside a CONFIG_DIRS directory would ALSO be merged as a
        # fragment -- and 'base.config' sorts after every numeric prefix, so it
        # would merge last and override every fragment. That is silent for a
        # string symbol: an identity fragment asking for LOCALVERSION="-el2" gets
        # the base's value back with no warning.
        for d in "${CONFIG_DIRS[@]}"; do
            case "${CONFIG_BASE}" in
                "config/${d}/"*) echo "!! ${conf}: CONFIG_BASE is inside config/${d}/, which is a fragment directory -- put it in config/base/" >&2; return 1 ;;
            esac
        done
    fi

    # Whether this kernel REPLACES ALARM's stock linux-aarch64 (provides +
    # conflicts) or installs alongside it. Alongside needs every installed path
    # to be distinct -- image, dtb directory, initramfs -- or pacman refuses the
    # install on a file conflict.
    REPLACE_STOCK_KERNEL="${REPLACE_STOCK_KERNEL:-yes}"
    case "${REPLACE_STOCK_KERNEL}" in
        yes|no) ;;
        *) echo "!! ${conf}: REPLACE_STOCK_KERNEL must be yes or no" >&2; return 1 ;;
    esac

    # An extra CachyOS scheduler patch on top of their tarball. Empty means the
    # tree's own scheduler (EEVDF plus their gaming-sched work), which is what
    # plain linux-cachyos ships.
    case "${CACHY_SCHED:-}" in
        ''|bore) ;;
        *) echo "!! ${conf}: CACHY_SCHED='${CACHY_SCHED}' is not '' or 'bore'" >&2; return 1 ;;
    esac
    if [ -n "${CACHY_SCHED:-}" ]; then
        # 0001-bore-cachy.patch is rebased onto CachyOS's tree, not onto
        # mainline: their fair.c already carries gaming-sched and poc_selector.
        # On kernel.org it does not apply.
        [ "${KERNEL_SOURCE}" = cachyos ] || {
            echo "!! ${conf}: CACHY_SCHED=${CACHY_SCHED} needs KERNEL_SOURCE=cachyos" >&2
            echo "!! (the -cachy patches are rebased onto their tree, not mainline)" >&2
            echo "!! For the kernel.org A/B, drop the scheduler patch too:" >&2
            echo "!!   CACHY_SCHED_OVERRIDE= KERNEL_SOURCE_OVERRIDE=kernel.org ..." >&2
            return 1; }
        # BORE and the OGC block are both large kernel/sched/fair.c reworks.
        [ "${USE_OGC}" != yes ] || {
            echo "!! ${conf}: CACHY_SCHED=${CACHY_SCHED} and USE_OGC=yes both rework kernel/sched/fair.c" >&2
            return 1; }
    fi

    # ---- installed layout, with defaults ----------------------------------
    # Blank in a conf means "the default", so a product only names what differs.
    KERNEL_IMAGE="${KERNEL_IMAGE:-Image}"
    KERNEL_IMAGE_DEST="${KERNEL_IMAGE_DEST:-/boot/${KERNEL_IMAGE}}"
    INITRAMFS_IMAGE="${INITRAMFS_IMAGE:-/boot/initramfs-${PKGBASE}.img}"
    INITRAMFS_FALLBACK="${INITRAMFS_FALLBACK:-/boot/initramfs-${PKGBASE}-fallback.img}"
    DTB_DEST="${DTB_DEST:-/boot/dtb/qcom}"

    # KERNEL_IMAGE is both a make target and a file under arch/arm64/boot/, so a
    # path in it would break the build rather than move the output.
    case "${KERNEL_IMAGE}" in
        */*) echo "!! ${conf}: KERNEL_IMAGE='${KERNEL_IMAGE}' must be a bare name (Image, Image.gz)" >&2; return 1 ;;
    esac
    # Destinations are pasted after ${pkgdir}, so a relative one silently writes
    # into the build directory instead of the package.
    local v
    for v in KERNEL_IMAGE_DEST INITRAMFS_IMAGE INITRAMFS_FALLBACK DTB_DEST; do
        case "${!v}" in
            /*) ;;
            *)  echo "!! ${conf}: ${v}='${!v}' must be an absolute path" >&2; return 1 ;;
        esac
    done
    [ "${INITRAMFS_IMAGE}" != "${INITRAMFS_FALLBACK}" ] \
        || { echo "!! ${conf}: INITRAMFS_IMAGE and INITRAMFS_FALLBACK are the same path" >&2; return 1; }

    export PRODUCT
    return 0
}

# ---------------------------------------------------------------------------
# One destructive operation per working tree
# ---------------------------------------------------------------------------
# Both halves of this pipeline are destructive to the tree they run in:
# fetch-patches.sh prunes patches/ and rewrites version.env, and
# `makepkg --cleanbuild` deletes src/ and re-extracts it. Run either while a
# build is in progress in the same checkout and the compile fails with dozens of
# "include/linux/kconfig.h: No such file or directory" -- headers that exist,
# from a tree that was replaced underneath it.
#
# So: one at a time, per directory. To work on two products at once, use two
# checkouts (they can share .ccache).
#
# LP_LOCK_HELD is exported, so build.sh calling fetch-patches.sh with FETCH=1
# does not deadlock against itself.
lp_lock() {
    local here="$1"
    [ -z "${LP_LOCK_HELD:-}" ] || return 0
    command -v flock >/dev/null || { echo "==> note: no flock; concurrent-run guard is off" >&2; return 0; }
    exec 9>"${here}/.build.lock"
    if ! flock -n 9; then
        echo "!! another build or fetch is already running in ${here}." >&2
        echo "!! Wait for it to finish, or use a second checkout for the other product." >&2
        return 1
    fi
    export LP_LOCK_HELD=1
    return 0
}

# ---------------------------------------------------------------------------
# The fragment list, in merge order
# ---------------------------------------------------------------------------
# Sorted by BASENAME across the union of CONFIG_DIRS, so the numeric prefix
# decides order regardless of which directory a fragment lives in. The same
# basename in two directories is an error: merging would drop one silently.
lp_config_fragments() {
    local d f b prev=
    local -a lines=()
    for d in "${CONFIG_DIRS[@]}"; do
        for f in "config/${d}"/*.config; do
            lines+=("$(basename "${f}")|${f}")
        done
    done
    while IFS='|' read -r b f; do
        [ "${b}" != "${prev}" ] || { echo "!! two config fragments are both named ${b}" >&2; return 1; }
        prev="${b}"
        printf '%s\n' "${f}"
    done < <(printf '%s\n' "${lines[@]}" | LC_ALL=C sort -t'|' -k1,1)
}

# ---------------------------------------------------------------------------
# Kernel source resolution
# ---------------------------------------------------------------------------
# Sets, for the caller: KERNEL_REF (resolved), BASE, IS_RC, SRC_URL, SRC_TAR,
# SRC_TOPDIR, SRC_SIG_URL, PKGVER_TAIL. Appends advisory lines to LP_NOTES.
#
# SRC_TOPDIR is the directory the tarball extracts to, and is not derivable from
# the base version: mainline gives linux-7.2.2/, a CachyOS release gives
# cachyos-7.2.2-1/. The PKGBUILD cds into it.
LP_NOTES=()

# Pinned, so a swapped key is an error rather than trust-on-first-use.
CACHYOS_SIGNERS=(
    E18447AC260021D31F3FF6C4C8A2A4774B8B63C4   # Eric Naim <dnaim@cachyos.org>
    E8B9AA39F054E30E8290D492C3C4820857F654FE   # Peter Jung <admin@ptr1337.dev>
)
KERNELORG_SIGNERS=(
    647F28654894E3BD457199BE38DBBDC86092693E   # Greg Kroah-Hartman <gregkh@kernel.org>
    ABAF11C65A2970B130ABE3C479BE3E4300411886   # Linus Torvalds <torvalds@kernel.org>
    E27E5D8A3403A2EF66873BBCDEA66FF797772CDC   # Sasha Levin <sashal@kernel.org>
)

lp_resolve_kernel_source() {
    local ogc_rev="${1:-}"      # only meaningful for kernel.org + USE_OGC=yes

    case "${KERNEL_SOURCE}" in
    cachyos)
        KERNEL_REF="${KERNEL_REF:-${CACHYOS_REF:-}}"
        [ -n "${KERNEL_REF}" ] || { echo "!! KERNEL_SOURCE=cachyos but neither KERNEL_REF nor CACHYOS_REF is set" >&2; return 1; }
        # cachyos-<base>-<tagrel>; the base may itself contain a dash (7.3-rc1),
        # so the greedy group takes everything up to the LAST dash-number.
        [[ "${KERNEL_REF}" =~ ^cachyos-(.+)-([0-9]+)$ ]] || {
            echo "!! KERNEL_REF='${KERNEL_REF}' is not a cachyos-<version>-<N> tag" >&2; return 1; }
        local cachy_base="${BASH_REMATCH[1]}" cachy_rel="${BASH_REMATCH[2]}"
        BASE="${cachy_base}"
        if [ -n "${BASE_VERSION}" ] && [ "${BASE_VERSION}" != "${cachy_base}" ]; then
            # Refused, not noted: the tarball would be the tag's while the pkgver
            # was the pin's, and nothing downstream could tell.
            echo "!! BASE_VERSION=${BASE_VERSION} contradicts ${KERNEL_REF}, which is base ${cachy_base}." >&2
            echo "!! A cachyos tag carries its own base; clear BASE_VERSION or pin KERNEL_REF instead." >&2
            return 1
        fi
        SRC_TAR="${KERNEL_REF}.tar.gz"
        SRC_URL="https://github.com/CachyOS/linux/releases/download/${KERNEL_REF}/${SRC_TAR}"
        SRC_SIG_URL="${SRC_URL}.asc"
        SRC_TOPDIR="${KERNEL_REF}"
        PKGVER_TAIL="cachy${cachy_rel}"
        ;;
    kernel.org)
        # Precedence: explicit ref, then the shared KERNELORG_REF, then -- only
        # for a product that actually uses OGC -- the base the OGC tag implies.
        #
        # A plain mainline build gets NO pkgver tail (7.2.2, not 7.2.2.mainline).
        # pacman sorts a bare version below any suffixed one, so 7.2.2 <
        # 7.2.2.cachy1 and a comparison build never offers itself as an upgrade.
        # A '.mainline' tail would sort ABOVE '.cachy1' ('m' > 'c').
        KERNEL_REF="${KERNEL_REF:-${KERNELORG_REF:-}}"
        if [ -z "${KERNEL_REF}" ] && [ "${USE_OGC}" = yes ] && [ -n "${OGC_REF:-}" ]; then
            [[ "${OGC_REF}" =~ ^v?(.+)-ogc([0-9]+)$ ]] || {
                echo "!! OGC_REF='${OGC_REF}' is not a <version>-ogc<N> tag" >&2; return 1; }
            KERNEL_REF="${BASH_REMATCH[1]}"
        fi
        [ -n "${KERNEL_REF}" ] || {
            echo "!! KERNEL_SOURCE=kernel.org but no base: set KERNEL_REF, KERNELORG_REF, or USE_OGC=yes" >&2; return 1; }
        BASE="${BASE_VERSION:-${KERNEL_REF}}"
        [ "${BASE}" = "${KERNEL_REF}" ] || LP_NOTES+=(
            "base PINNED to ${BASE}; KERNEL_REF says ${KERNEL_REF}. Any patch written against ${KERNEL_REF} was not written against this tree.")
        local kmajor="${BASE%%.*}"
        if [[ "${BASE}" == *-rc* ]]; then
            SRC_TAR="linux-${BASE}.tar.gz"
            SRC_URL="https://git.kernel.org/torvalds/t/${SRC_TAR}"
            SRC_SIG_URL=
        else
            SRC_TAR="linux-${BASE}.tar.xz"
            SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v${kmajor}.x/${SRC_TAR}"
            SRC_SIG_URL="https://cdn.kernel.org/pub/linux/kernel/v${kmajor}.x/linux-${BASE}.tar.sign"
        fi
        SRC_TOPDIR="linux-${BASE}"
        PKGVER_TAIL=""
        [ "${USE_OGC}" = yes ] && [ -n "${ogc_rev}" ] && PKGVER_TAIL="ogc${ogc_rev}"
        ;;
    esac

    if [[ "${BASE}" == *-rc* ]]; then IS_RC=1; else IS_RC=; fi

    # pkgver must not contain '-'; release bases never do, rc bases always do.
    PKGVER="${BASE//-/}"
    [ -n "${PKGVER_TAIL}" ] && PKGVER="${PKGVER}.${PKGVER_TAIL}"

    [ -n "${IS_RC}" ] && LP_NOTES+=(
        "base is an -rc. pkgver is ${PKGVER}; pacman sorts '7.2rc7.x' AFTER '7.2.x', so an rc-to-release move needs an epoch bump in the PKGBUILD.")
    return 0
}

# ---------------------------------------------------------------------------
# Tarball verification
# ---------------------------------------------------------------------------
# Returns 0 verified, 1 not verified (the caller decides how loud that is), 2 if
# there is nothing to verify against (an rc snapshot). One-line verdict on stdout.
#
# The two sources sign different things: kernel.org signs the UNCOMPRESSED tar,
# CachyOS signs the .tar.gz as shipped. Getting it backwards reports "no signed
# data", which looks like a missing signature rather than a wrong input.
lp_verify_tarball() {
    local file="$1" tmp="$2"
    local -a signers=()
    local sig="${tmp}/tarball.sig" target

    [ -n "${SRC_SIG_URL}" ] || { echo "unverified: ${SRC_TAR} has no detached signature upstream"; return 2; }
    curl -fsSL --retry 3 -o "${sig}" "${SRC_SIG_URL}" \
        || { echo "could not fetch ${SRC_SIG_URL}"; return 1; }

    case "${KERNEL_SOURCE}" in
        cachyos)    signers=("${CACHYOS_SIGNERS[@]}");    target="${file}" ;;
        kernel.org) signers=("${KERNELORG_SIGNERS[@]}")
                    target="${tmp}/linux.tar"
                    xz -dc "${file}" > "${target}" ;;
    esac

    export GNUPGHOME="${tmp}/gnupg"; mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
    local fpr got=0
    for fpr in "${signers[@]}"; do
        # WKD first (kernel.org publishes it), then a keyserver. Only pinned
        # fingerprints are requested, so neither source decides who may sign.
        gpg --batch --quiet --auto-key-locate wkd,keyserver \
            --keyserver hkps://keyserver.ubuntu.com --recv-keys "${fpr}" >/dev/null 2>&1 \
            && got=$((got + 1))
        gpg --batch --quiet --import-ownertrust <<< "${fpr}:6:" 2>/dev/null || true
    done
    [ "${got}" -gt 0 ] || { unset GNUPGHOME; echo "could not fetch any pinned signing key for ${KERNEL_SOURCE}"; return 1; }

    local ok=1
    if gpg --batch --status-fd 3 --verify "${sig}" "${target}" 3>"${tmp}/gpgstatus" 2>/dev/null \
       && grep -qE "^\[GNUPG:\] VALIDSIG ($(IFS='|'; echo "${signers[*]}"))" "${tmp}/gpgstatus"
    then
        ok=0
    fi
    local signer; signer="$(awk '/VALIDSIG/{print $3}' "${tmp}/gpgstatus" 2>/dev/null || true)"
    rm -f "${tmp}/linux.tar"
    unset GNUPGHOME

    if [ "${ok}" = 0 ]; then
        echo "verified ${SRC_TAR}  signed by ${signer:0:16}..."
        return 0
    fi
    echo "${SRC_TAR} did not verify against a pinned ${KERNEL_SOURCE} signer"
    return 1
}
