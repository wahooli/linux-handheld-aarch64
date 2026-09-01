#!/usr/bin/env bash
# shellcheck disable=SC2034  # DTB/DTS arrays are consumed by the PKGBUILD
#
# Resolve one product's kernel base, patch stack and board device trees from the
# refs pinned in sources.env and products/<product>.conf. Nothing this script
# downloads is committed -- that is the point. What IS committed is the manifests
# it reads:
#
#   products/<product>.conf           base, config, series, boards, dtbs
#   patches/series.d/<product>.series a LOCAL series, for a product whose patches
#                                     have no upstream manifest (SERIES=<path>)
#   patches/<product>/*.patch         committed patches, for a series entry that
#                                     cannot be fetched from anywhere. This is
#                                     the only place .patch files are committed.
#   patches/ogc.select                which OGC patches, by name regex
#   patches/local/series              patches authored here, applied last
#
#   PRODUCT=handheld ./scripts/fetch-patches.sh
#
# PRODUCT may be omitted while sources.env names exactly one product.
#
# ---------------------------------------------------------------------------
# Where the kernel comes from
#
# KERNEL_SOURCE in the product conf picks one of two bases, and they are not
# interchangeable in what they already contain:
#
#   cachyos      CachyOS/linux release tarball -- mainline stable with CachyOS's
#                own branches merged (bbr3, cachy, gaming-sched, ksm,
#                preempt-ipi, amd-pstate...). One signed asset; there is no
#                patch series to resolve for the base itself. Note that
#                7.2/gaming-sched already carries the EEVDF mailing-list series
#                that patches/ogc.select selects, which is why USE_OGC is off
#                for a cachyos product.
#   kernel.org   pristine mainline, PGP-verified against the release signers.
#
# ---------------------------------------------------------------------------
# Where the patches come from
#
#   CachyOS/kernel-patches     The one scheduler patch a product may ask for on
#                              top of the CachyOS tarball (CACHY_SCHED). Pinned
#                              to a commit; that repo has no tags or signatures.
#   armada-os/armada-packages  Device support, already rebased onto our base.
#                              PRIMARY. ROCKNIX authors most of it, but armada
#                              does the rebase, and the rebase is the expensive
#                              part.
#   ROCKNIX/distribution       The true upstream, but it builds SM8750 against
#                              7.1.3. Fallback source for patches armada lacks,
#                              and the source for the staged-not-applied set.
#   OpenGamingCollective/linux An x86 handheld tree with nothing to say about
#                              Qualcomm. Optional (USE_OGC); we take only the
#                              arch-independent parts -- the scheduler block.
#
# OGC ships two release assets. We use series.zip (individual git format-patch
# files, each with authorship, commit message and a GPG .sig) rather than
# monolithic.patch, which is one flat diff with no per-patch provenance.
#
# ---------------------------------------------------------------------------
# Outputs
#
#   patches/*.patch              fetched, gitignored
#   patches/rocknix-staged/      fetched, gitignored, never applied
#   dts/                         fetched, gitignored
#   patches/series.generated     the single ordered list the PKGBUILD applies
#   version.env                  product, base, tarball URL + sha256, pkgver
#   .fetch-report.md             job summary fragment for CI
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-product.sh
source "${HERE}/scripts/lib-product.sh"
lp_load "${HERE}"
lp_lock "${HERE}"

# version.env existing means "the LAST resolve succeeded, and the tree matches
# it". Drop the previous one now (under the lock), so a run that dies partway
# -- set -e, not just the failure gate at the bottom -- cannot leave a stale
# file describing a stack this tree no longer holds. It is rewritten at the
# end, on success only.
rm -f version.env

ARMADA_RAW="https://raw.githubusercontent.com/armada-os/armada-packages/${ARMADA_REF}/kernel"
ROCKNIX_RAW="https://raw.githubusercontent.com/ROCKNIX/distribution/${ROCKNIX_REF}"

# The staged-for-review set follows a BRANCH, not the release tag, and that is
# deliberate. ROCKNIX lands device work on `next` continuously and tags monthly:
# at 20260801 its SM8750 directory holds 53 patches, on `next` it holds 63. For
# the fallback role above, the tag is the right call -- a patch we actually
# apply should come from something stable. But staged patches are never applied.
# Pinning them to the tag only means the dry-run report is reviewing a snapshot
# that is weeks old, which is the one thing that report exists to avoid.
ROCKNIX_STAGED_REF="${ROCKNIX_STAGED_REF:-next}"
ROCKNIX_STAGED_RAW="https://raw.githubusercontent.com/ROCKNIX/distribution/${ROCKNIX_STAGED_REF}"
OGC_REL="https://github.com/OpenGamingCollective/linux/releases/download/${OGC_REF}"
CACHY_RAW="https://raw.githubusercontent.com/CachyOS/kernel-patches/${CACHY_PATCHES_REF:-master}"

# Verify OGC's per-patch signatures. On by default: it is cheap, and the pinned
# ref alone is not integrity when the patches are no longer committed.
OGC_VERIFY="${OGC_VERIFY:-1}"
# Verify the kernel tarball's PGP signature against the pinned release keys.
KERNEL_VERIFY="${KERNEL_VERIFY:-1}"
# Re-download things already present.
FORCE="${FORCE:-}"

# How many unselected patches may sit between two selected ones before the
# contiguity guard treats them as separate blocks rather than a gap. See
# ogc_guard() for what this is protecting against.
OGC_CLUSTER_GAP="${OGC_CLUSTER_GAP:-5}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

RED=$'\033[31m'; YLW=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=; YLW=; GRN=; DIM=; OFF=; }

FAILURES=()          # hard errors, each tagged upstream: or local:
NOTES=()             # advisory lines for the report
fail()  { FAILURES+=("$1"); echo "${RED}  !! $1${OFF}" >&2; }
note()  { NOTES+=("$1"); }

# ===========================================================================
# 1. Kernel base, from whichever source this product selected
# ===========================================================================
# The OGC revision is parsed FIRST because it feeds the pkgver tail of a
# kernel.org+OGC product -- and only then. With USE_OGC=no it is not read at all,
# so a stale OGC_REF in sources.env cannot influence what gets built.
OGC_REV=
if [ "${USE_OGC}" = yes ]; then
    [[ "${OGC_REF}" =~ ^v?(.+)-ogc([0-9]+)$ ]] || {
        echo "${RED}OGC_REF='${OGC_REF}' is not a <version>-ogc<N> tag${OFF}" >&2
        exit 1
    }
    OGC_REV="${BASH_REMATCH[2]}"
fi

lp_resolve_kernel_source "${OGC_REV}"
[ ${#LP_NOTES[@]} -eq 0 ] || NOTES+=("${LP_NOTES[@]}")

if [ "${KERNEL_SOURCE}" = cachyos ] && [ "${USE_OGC}" = yes ]; then
    note "USE_OGC=yes on a cachyos base. Its 7.2/gaming-sched branch already carries the EEVDF series patches/ogc.select selects; expect the PKGBUILD to report most of them as ALREADY APPLIED. Read that table rather than trusting this note."
fi

echo "==> product    ${PRODUCT}  (${PKGBASE})"
echo "==> base       ${SRC_TOPDIR}   ${DIM}(${KERNEL_SOURCE} ${KERNEL_REF})${OFF}"
echo "==> armada     ${ARMADA_REF:0:12}"
echo "==> ROCKNIX    ${ROCKNIX_REF}   ${DIM}(staged set: ${ROCKNIX_STAGED_REF})${OFF}"
echo "==> boards     ${PRODUCT_BOARDS:-(none named)}"
echo

# ===========================================================================
# 2. Kernel tarball: fetch, verify, record the checksum
# ===========================================================================
# This is what closes the sha256sums=('SKIP') TODO the old package carried. The
# PKGBUILD gets a real checksum written into version.env, and in the normal case
# that checksum is anchored to an upstream PGP signature rather than to whatever
# the CDN happened to serve us. What is signed differs per source, which
# lp_verify_tarball knows about -- kernel.org signs the uncompressed tar,
# CachyOS signs the .tar.gz as shipped.
mkdir -p .cache
CACHED=".cache/${SRC_TAR}"
if [ ! -f "${CACHED}" ] || [ -n "${FORCE}" ]; then
    echo "==> downloading ${SRC_TAR}"
    curl -fSL --no-progress-meter --retry 3 --retry-delay 2 -o "${CACHED}.part" "${SRC_URL}"
    mv "${CACHED}.part" "${CACHED}"
else
    echo "==> have ${SRC_TAR} ${DIM}(cached)${OFF}"
fi
SRC_SHA="$(sha256sum "${CACHED}" | cut -d' ' -f1)"

if [ -n "${KERNEL_VERIFY}" ]; then
    verdict="$(lp_verify_tarball "${CACHED}" "${TMP}")" && rc=0 || rc=$?
    case "${rc}" in
        0) echo "  ${GRN}${verdict}${OFF}" ;;
        2) note "${verdict} -- trust-on-first-use at sha256 ${SRC_SHA:0:16}..." ;;
        *) fail "upstream: ${verdict}" ;;
    esac
else
    note "KERNEL_VERIFY is off: ${SRC_TAR} is trusted at sha256 ${SRC_SHA:0:16}... and nothing else."
fi
echo "  sha256  ${SRC_SHA}"
echo

# ===========================================================================
# 3. OGC: select by name, guard contiguity, fetch
# ===========================================================================
mkdir -p patches dts

# Initialised unconditionally. These are read in sections 6 and 7 whatever
# happens above, and under `set -u` an unbound array there turns a clean
# "upstream is down" failure into an unbound-variable error twenty lines later.
OGC_SERIES=()
ogc_selected=()       # "0028 0028-FROM-ML-....patch"
ogc_unselected=()
ogc_names=()
OGC_SRC=

# Whether OGC patches are wanted at all is the product's decision. When it says
# no, any previously fetched ogc-*.patch is pruned rather than left on disk --
# an orphan in patches/ is how a series file starts referring to something
# nothing fetches.
if [ "${USE_OGC}" != yes ]; then
    echo "==> OGC        ${DIM}off for this product (USE_OGC=${USE_OGC:-no})${OFF}"
    for f in patches/ogc-*.patch; do
        [ -e "${f}" ] || continue
        echo "  ${DIM}prune   $(basename "${f}")${OFF}"; rm -f "${f}"
    done
else

echo "==> OGC series.zip @ ${OGC_REF}"
if ! curl -fsSL --retry 3 -o "${TMP}/series.zip" "${OGC_REL}/series.zip"; then
    fail "upstream: no series.zip at ${OGC_REF} -- is that a real release tag?"
else
    mkdir -p "${TMP}/ogc"
    if command -v bsdtar >/dev/null; then bsdtar -xf "${TMP}/series.zip" -C "${TMP}/ogc"
    else unzip -qo "${TMP}/series.zip" -d "${TMP}/ogc"; fi
    OGC_SRC="$(dirname "$(find "${TMP}/ogc" -name '0001-*.patch' -print -quit)")"
    [ -d "${OGC_SRC}" ] || fail "upstream: series.zip at ${OGC_REF} has no 0001-*.patch"
fi

if [ -d "${OGC_SRC:-}" ]; then
    # ---- key pinning -------------------------------------------------------
    # public.key ships in the same release it signs, so verifying against it is
    # trust-on-first-use. Pin the fingerprint so a swapped key is an error.
    if [ -n "${OGC_VERIFY}" ]; then
        export GNUPGHOME="${TMP}/ogcgnupg"; mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
        if curl -fsSL --retry 3 -o "${TMP}/public.key" "${OGC_REL}/public.key"; then
            gpg --batch --quiet --import "${TMP}/public.key"
            got_fpr="$(gpg --batch --with-colons --fingerprint | awk -F: '/^fpr:/{print $10; exit}')"
            want_fpr="$(grep -vE '^\s*(#|$)' patches/ogc.keyfpr | head -1 | tr -d '[:space:]')"
            if [ "${got_fpr}" != "${want_fpr}" ]; then
                fail "upstream: OGC signing key changed: release ships ${got_fpr}, patches/ogc.keyfpr pins ${want_fpr}"
                OGC_VERIFY=
            fi
        else
            fail "upstream: no public.key at ${OGC_REF} (set OGC_VERIFY= to skip)"
            OGC_VERIFY=
        fi
    fi

    mapfile -t OGC_SELECT_RE < <(grep -vE '^\s*(#|$)' patches/ogc.select)
    mapfile -t OGC_DENY_RE   < <(grep -vE '^\s*(#|$)' patches/ogc.select.deny 2>/dev/null || true)

    matches_any() {   # $1 = name, rest = regexes
        local n="$1"; shift
        local re
        for re in "$@"; do [[ "${n}" =~ ${re} ]] && return 0; done
        return 1
    }

    while IFS= read -r f; do
        base="$(basename "${f}")"
        num="${base%%-*}"
        name="${base#*-}"; name="${name%.patch}"
        ogc_names+=("${num} ${name}")
        if matches_any "${name}" "${OGC_SELECT_RE[@]}"; then
            ogc_selected+=("${num} ${base}")
        else
            ogc_unselected+=("${num} ${name}")
        fi
    done < <(find "${OGC_SRC}" -maxdepth 1 -name '[0-9]*.patch' ! -name '*.sig' | sort)

    # ---- contiguity guard --------------------------------------------------
    # The scheduler block must be taken whole: "sched/fair: Fix flat hierarchy"
    # fixes "sched/eevdf: Move to a single runqueue", so a subset ships the
    # rework without its fix. A name regex cannot know that OGC inserted a new
    # non-sched patch in the middle as a dependency -- it would silently skip it.
    #
    # So: group the selected numbers into clusters (a gap of more than
    # OGC_CLUSTER_GAP unselected patches starts a new cluster, which is what
    # keeps the lone usbhid patch from dragging everything up to the scheduler
    # block into one span), then fail on any unselected patch inside a cluster.
    ogc_guard() {
        local nums=() n prev=-99 cstart=-1 cend=-1
        mapfile -t nums < <(printf '%s\n' "${ogc_selected[@]}" | cut -d' ' -f1 | sort -n)
        local clusters=()
        for n in "${nums[@]}"; do
            n=$((10#${n}))
            if [ ${prev} -lt 0 ] || [ $((n - prev)) -gt $((OGC_CLUSTER_GAP + 1)) ]; then
                [ ${cstart} -ge 0 ] && clusters+=("${cstart} ${cend}")
                cstart=${n}
            fi
            cend=${n}; prev=${n}
        done
        [ ${cstart} -ge 0 ] && clusters+=("${cstart} ${cend}")

        local c a b entry num name
        for c in "${clusters[@]}"; do
            read -r a b <<< "${c}"
            for entry in "${ogc_unselected[@]}"; do
                num="$(cut -d' ' -f1 <<< "${entry}")"; num=$((10#${num}))
                name="${entry#* }"
                if [ "${num}" -le "${a}" ] || [ "${num}" -ge "${b}" ]; then continue; fi
                if [ ${#OGC_DENY_RE[@]} -gt 0 ] && matches_any "${name}" "${OGC_DENY_RE[@]}"; then
                    note "OGC $(printf '%04d' ${num}) sits inside a selected block but is listed in ogc.select.deny: ${name}"
                    continue
                fi
                fail "upstream: OGC $(printf '%04d' ${num}) '${name}' is INSIDE the selected block ${a}-${b} but matches no rule. Add it to patches/ogc.select or patches/ogc.select.deny -- do not ignore it."
            done
        done
    }
    ogc_guard

    # ---- prune, then fetch -------------------------------------------------
    keep=" $(printf '%s\n' "${ogc_selected[@]}" | cut -d' ' -f2 | tr '\n' ' ') "
    for f in patches/ogc-*.patch; do
        [ -e "${f}" ] || continue
        [[ "${keep}" == *" $(basename "${f}" | sed 's/^ogc-//') "* ]] && continue
        echo "  ${DIM}prune   $(basename "${f}")${OFF}"; rm -f "${f}"
    done

    n_new=0; n_bad=0
    for entry in "${ogc_selected[@]}"; do
        src_base="${entry#* }"
        src="${OGC_SRC}/${src_base}"
        if [ -n "${OGC_VERIFY}" ]; then
            if [ ! -f "${src}.sig" ]; then
                fail "upstream: OGC ${src_base} has no .sig in series.zip"; n_bad=$((n_bad+1)); continue
            elif ! gpg --batch --quiet --verify "${src}.sig" "${src}" 2>/dev/null; then
                fail "upstream: OGC ${src_base} signature does not verify"; n_bad=$((n_bad+1)); continue
            fi
        fi
        dst="patches/ogc-${src_base}"
        OGC_SERIES+=("ogc-${src_base}")
        [ -f "${dst}" ] && [ -z "${FORCE}" ] && continue
        cp "${src}" "${dst}"; n_new=$((n_new+1))
    done
    unset GNUPGHOME
    echo "  selected ${#OGC_SERIES[@]} of ${#ogc_names[@]} patches (${n_new} newly fetched$([ -n "${OGC_VERIFY}" ] && echo ", signatures verified"))"
fi

fi   # USE_OGC
echo

# ===========================================================================
# 4. Device patches and board device trees
# ===========================================================================
# ONE series for the product, covering every board it supports. A patch for a
# board this kernel never boots is unreachable code, so there is nothing to gain
# from splitting it per device.
try_armada() {
    [ "${USE_ARMADA}" = yes ] || return 1
    curl -fsSL --retry 3 -o "$2" "${ARMADA_RAW}/$1"
}
# ROCKNIX spreads patches over several directories, so most probes are expected
# to 404. No --retry (a 404 is not transient) and stderr is dropped, or every
# lookup narrates four failures before the one that works.
try_rocknix() {
    local name="$1" out="$2" d root="${3:-${ROCKNIX_RAW}}"
    [ "${USE_ROCKNIX}" = yes ] || return 1
    for d in "${ROCKNIX_DIRS[@]}"; do
        curl -fsSL -o "${out}" "${root}/${d}/${name}" 2>/dev/null && return 0
    done
    return 1
}

# ---- resolve the ordered list ------------------------------------------------
# SERIES=armada takes armada's own manifest whole; same format as a local one.
# Fetched into TMP rather than the tree, so no copy on disk can disagree with
# ARMADA_REF.
SERIES_SRC=
SERIES_TOTAL=0
denied=()
if [ "${SERIES}" = armada ]; then
    SERIES_SRC="${TMP}/armada.series"
    echo "==> series armada@${ARMADA_REF:0:12}  ${DIM}(kernel/patches/series)${OFF}"
    try_armada "patches/series" "${SERIES_SRC}" \
        || { fail "upstream: armada@${ARMADA_REF:0:12} has no kernel/patches/series"; SERIES_SRC=; }
else
    SERIES_SRC="${SERIES}"
    echo "==> series ${SERIES}   ${DIM}(local)${OFF}"
fi

SERIES_PATCHES=(); seen_patch=" "
n_armada=0; n_rocknix=0

if [ -n "${SERIES_SRC}" ]; then
    # Read the whole list first, then fetch. Two reasons: the deny rules have to
    # be checked against the FULL upstream list (a rule for a patch that is no
    # longer there is stale and must fail rather than rot), and SERIES_EXTRA has
    # to be appended after it.
    upstream_entries=()
    # Line numbers are tracked so a duplicate can be reported as a location
    # rather than a riddle: a hand-edited series plus a regenerated one is an
    # easy way to list the same patch twice, and "lists X twice" alone does not
    # say where either copy is.
    declare -A first_line=()
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [ -n "${line}" ] || continue
        if [ -n "${first_line[${line}]:-}" ]; then
            fail "local: ${SERIES_SRC} lists ${line} twice -- lines ${first_line[${line}]} and ${lineno}"
            continue
        fi
        first_line["${line}"]="${lineno}"
        upstream_entries+=("${line}")
    done < "${SERIES_SRC}"
    SERIES_TOTAL=${#upstream_entries[@]}

    deny_list=" ${SERIES_DENY[*]-} "
    for entry in "${upstream_entries[@]}"; do
        if [[ "${deny_list}" == *" ${entry} "* ]]; then
            denied+=("${entry}")
            echo "  ${YLW}deny    ${entry}${OFF}"
            continue
        fi
        SERIES_PATCHES+=("${entry}")
    done

    # A deny rule that matched nothing is a rule for a patch upstream has already
    # dropped. Left alone it looks like protection and is not -- exactly the
    # failure mode patches/ogc.select.deny's guard exists to prevent.
    for entry in ${SERIES_DENY[@]+"${SERIES_DENY[@]}"}; do
        [[ " ${denied[*]-} " == *" ${entry} "* ]] \
            || fail "local: SERIES_DENY names ${entry}, which is not in the series any more -- remove the rule"
    done

    # Appended, not inserted. Anything order-sensitive belongs in a local series.
    for entry in ${SERIES_EXTRA[@]+"${SERIES_EXTRA[@]}"}; do
        if [[ " ${SERIES_PATCHES[*]} " == *" ${entry} "* ]]; then
            fail "local: SERIES_EXTRA names ${entry}, which is already in the series"
            continue
        fi
        SERIES_PATCHES+=("${entry}")
    done
fi

# ---- fetch --------------------------------------------------------------------
# Resolution order per entry:
#
#   patches/<product>/<name>   committed in this repo. For a patch with nothing
#                              to fetch it from -- a WIP branch, a dead
#                              codelinaro tree, something written here.
#   armada                     kernel/patches/<name> at ARMADA_REF
#   ROCKNIX                    ROCKNIX_DIRS at ROCKNIX_REF, 7.1.3-based
#
# A committed entry keeps its <product>/ prefix in series.generated, so the
# PKGBUILD finds it and the source of every patch is visible in the list.
SERIES_ENTRIES=(); n_committed=0
for line in ${SERIES_PATCHES[@]+"${SERIES_PATCHES[@]}"}; do
    # A repeated entry is a mistake in whichever list it came from -- and `patch`
    # would refuse the second application anyway, fifty minutes later.
    if [[ "${seen_patch}" == *" ${line} "* ]]; then
        fail "upstream: the series lists ${line} twice"
        continue
    fi
    seen_patch+="${line} "

    if [ -f "patches/${PRODUCT}/${line}" ]; then
        SERIES_ENTRIES+=("${PRODUCT}/${line}")
        n_committed=$((n_committed+1))
        continue
    fi

    SERIES_ENTRIES+=("${line}")
    out="patches/${line}"
    if [ -f "${out}" ] && [ -z "${FORCE}" ]; then continue; fi
    if try_armada "patches/${line}" "${out}"; then
        n_armada=$((n_armada+1))
    elif try_rocknix "${line}" "${out}"; then
        n_rocknix=$((n_rocknix+1))
        note "${line} came from ROCKNIX (7.1.3-based), not armada -- verify it applies"
    else
        rm -f "${out}"
        fail "upstream: ${line} not found in patches/${PRODUCT}/, armada@${ARMADA_REF:0:12} or ROCKNIX@${ROCKNIX_REF}"
    fi
done

for f in "${DTS[@]}" "${DTS_DELTA[@]}"; do
    [ -f "dts/${f}" ] && [ -z "${FORCE}" ] && continue
    try_armada "dts/${f}" "dts/${f}" || { rm -f "dts/${f}"; fail "upstream: dts/${f} not in armada@${ARMADA_REF:0:12}"; }
done

# Staged, never applied. The dry-run report lives in scripts/makepkg-and-report.sh.
if [ ${#ROCKNIX_STAGED[@]} -gt 0 ] && [ "${USE_ROCKNIX}" = yes ]; then
    mkdir -p patches/rocknix-staged
    for f in "${ROCKNIX_STAGED[@]}"; do
        [ -f "patches/rocknix-staged/${f}" ] && [ -z "${FORCE}" ] && continue
        try_rocknix "${f}" "patches/rocknix-staged/${f}" "${ROCKNIX_STAGED_RAW}" \
            || { rm -f "patches/rocknix-staged/${f}"; note "ROCKNIX-staged ${f} not found at ${ROCKNIX_STAGED_REF} (upstream may have renamed or dropped it)"; }
    done
fi
printf '  %d patches' "${#SERIES_PATCHES[@]}"
[ "${SERIES}" = armada ] && printf ' (%d upstream - %d denied + %d extra)' \
    "${SERIES_TOTAL}" "${#denied[@]}" "${#SERIES_EXTRA[@]}"
[ "${n_committed}" -gt 0 ] && printf ', %d committed here' "${n_committed}"
printf ', %d vendored device tree(s), %d dtb(s)\n' "${#DTS[@]}" "${#DTB[@]}"
echo

# ===========================================================================
# 5. CachyOS scheduler patch
# ===========================================================================
# One patch, on top of their tarball, for a product that asked for a scheduler
# their default package does not ship. Their kernel-patches layout is
# <major.minor>/sched/<name>, so the directory follows the base -- a base bump to
# a version they have not published patches for fails here rather than mid-build.
CACHY_SERIES=(); FUZZ_ALLOW=()
if [ -n "${CACHY_SCHED:-}" ]; then
    [[ "${BASE}" =~ ^([0-9]+\.[0-9]+) ]] && cachy_major="${BASH_REMATCH[1]}"
    case "${CACHY_SCHED}" in
        bore) cachy_patch="0001-bore-cachy.patch" ;;
    esac
    dst="patches/cachy-${cachy_patch}"
    echo "==> cachy sched  ${CACHY_SCHED}  ${DIM}(${cachy_major}/sched/${cachy_patch} @ ${CACHY_PATCHES_REF:0:12})${OFF}"
    if [ ! -f "${dst}" ] || [ -n "${FORCE}" ]; then
        if curl -fsSL --retry 3 -o "${dst}.part" "${CACHY_RAW}/${cachy_major}/sched/${cachy_patch}"; then
            mv "${dst}.part" "${dst}"
        else
            rm -f "${dst}.part"
            fail "upstream: no ${cachy_major}/sched/${cachy_patch} at CachyOS/kernel-patches@${CACHY_PATCHES_REF:0:12}"
        fi
    fi
    if [ -f "${dst}" ]; then
        CACHY_SERIES+=("cachy-${cachy_patch}")
        echo "  $(wc -c < "${dst}") bytes, sha256 $(sha256sum "${dst}" | cut -c1-16)..."
        # This one entry may apply with fuzz. CachyOS rebases their scheduler
        # patch against whichever tree they were last on, which is not
        # necessarily the release tarball we pin -- at cachyos-7.2.2-1 the BORE
        # patch predates their own preempt-ipi merge, so its first sched.h hunk
        # anchors 11 lines above where that block now sits:
        #
        #   Hunk #1 FAILED at 824.                    -F0
        #   Hunk #1 succeeded at 835 with fuzz 2      GNU patch's default
        #
        # Their own builds succeed because makepkg applies with fuzz 2. We match
        # that HERE ONLY, and never silently: the PKGBUILD prints every placement
        # patch chose, and config/bore/ asserts CONFIG_SCHED_BORE, so a patch
        # that landed somewhere useless fails the build rather than shipping.
        FUZZ_ALLOW+=("cachy-${cachy_patch}")
    fi
else
    for f in patches/cachy-*.patch; do
        [ -e "${f}" ] || continue
        echo "  ${DIM}prune   $(basename "${f}")${OFF}"; rm -f "${f}"
    done
fi
echo

# ===========================================================================
# 6. Generated outputs
# ===========================================================================
# A patch authored here is not a separate stage: it is a series entry resolved
# from patches/<product>/, placed wherever the series puts it. For a product on
# armada's series that means naming it in SERIES_EXTRA, which appends it last.
{
    echo "# GENERATED by scripts/fetch-patches.sh -- do not edit, do not commit."
    echo "# product ${PRODUCT} | base ${SRC_TOPDIR} (${KERNEL_SOURCE} ${KERNEL_REF})"
    echo "# armada ${ARMADA_REF:0:12} | rocknix ${ROCKNIX_REF} | ogc ${USE_OGC:-no}${OGC_REV:+ ${OGC_REF}}"
    echo "# series ${SERIES}: ${#SERIES_PATCHES[@]} patches${SERIES_TOTAL:+ (${SERIES_TOTAL} upstream, ${#denied[@]} denied, ${#SERIES_EXTRA[@]} extra)} | boards: ${PRODUCT_BOARDS:-unnamed}"
    echo
    echo "# --- device stack -------------------------------------------------"
    printf '%s\n' "${SERIES_ENTRIES[@]}"
    if [ ${#CACHY_SERIES[@]} -gt 0 ]; then
        echo
        echo "# --- CachyOS scheduler (${CACHY_SCHED}) ----------------------------"
        echo "# Applies after the device stack: it touches kernel/sched only."
        printf '%s\n' "${CACHY_SERIES[@]}"
    fi
    if [ ${#OGC_SERIES[@]} -gt 0 ]; then
        echo
        echo "# --- OGC, arch-independent ----------------------------------------"
        echo "# Applies after the device stack: nothing here touches Qualcomm code,"
        echo "# so the relative ordering is irrelevant."
        printf '%s\n' "${OGC_SERIES[@]}"
    fi
} > patches/series.generated

# Drop any fetched patch no product's series references, so patches/ cannot
# accumulate orphans across a series edit.
#
# patches/ is flat and shared between products, so the union of every product's
# manifest is what protects it: pruning against this product's series alone would
# delete the other product's fetched patches every time you switch, and (worse)
# do it to a tree someone is building in.
printf '%s\n' ${SERIES_ENTRIES[@]+"${SERIES_ENTRIES[@]}"} \
    ${CACHY_SERIES[@]+"${CACHY_SERIES[@]}"} \
    ${OGC_SERIES[@]+"${OGC_SERIES[@]}"} > "patches/.fetched.${PRODUCT}"
refs=" $(cat patches/.fetched.* 2>/dev/null | tr '\n' ' ') "
for f in patches/*.patch; do
    [ -e "${f}" ] || continue
    b="$(basename "${f}")"
    [[ "${refs}" == *" ${b} "* ]] || { echo "  ${DIM}prune   ${b}${OFF}"; rm -f "${f}"; }
done

# version.env is the ONE place that decides what gets built. Everything
# downstream -- the PKGBUILD, next-pkgrel.sh, publish-r2.sh, tag-release.sh --
# reads it rather than re-deriving anything from sources.env, so a product can
# never be half-switched.
#
# Staged in TMP and moved into place only after the failure gate at the bottom:
# downstream gates on the file's EXISTENCE, so a resolve that recorded hard
# failures must not leave behind a version.env that looks fully resolved -- in
# CI it would ride the failure artifact into the publish job and describe
# packages that were never built.
cat > "${TMP}/version.env" <<EOF
# GENERATED by scripts/fetch-patches.sh from sources.env + products/${PRODUCT}.conf
# -- do not edit. The PKGBUILD sources this, so there is exactly one place that
# decides which kernel gets built.
_product=${PRODUCT}
_pkgbase=${PKGBASE}
_pkgdesc="${PRODUCT_DESC}"
_kernelsource=${KERNEL_SOURCE}
_kernelref=${KERNEL_REF}
_base=${BASE}
# _srcname is the directory the tarball EXTRACTS TO, not a name we choose:
# mainline gives linux-7.2.2, a CachyOS release gives cachyos-7.2.2-1.
_srcname=${SRC_TOPDIR}
_srcurl=${SRC_URL}
_srcsha256=${SRC_SHA}
pkgver=${PKGVER}
pkgrel=${PKGREL:-1}
_configbase=${CONFIG_BASE}
_configdirs="${CONFIG_DIRS[*]}"
_replacestock=${REPLACE_STOCK_KERNEL}
# The dtbs this package ships. Recorded here purely so the tag message and the
# failure report can name them without sourcing the product conf -- the PKGBUILD
# reads the real list from products/${PRODUCT}.conf, which is where it is edited.
_cachysched=${CACHY_SCHED:-}
# Series entries allowed to apply with fuzz. Only ever the CachyOS scheduler
# patch; everything else is -F0.
_fuzzallow="${FUZZ_ALLOW[*]-}"
_series=${SERIES}
_npatches=${#SERIES_PATCHES[@]}
_dtbs="${DTB[*]}"
# Installed layout. The make target and the paths the package writes to.
_kernelimage=${KERNEL_IMAGE}
_kernelimagedest=${KERNEL_IMAGE_DEST}
_initramfs=${INITRAMFS_IMAGE}
_initramfsfallback=${INITRAMFS_FALLBACK}
_dtbdest=${DTB_DEST}
_installvmlinuz=${INSTALL_VMLINUZ}
_useogc=${USE_OGC}
_ogcref=${OGC_REF}
_armadaref=${ARMADA_REF}
_rocknixref=${ROCKNIX_REF}
EOF

# ===========================================================================
# 7. Report
# ===========================================================================
{
    echo "### Patch stack"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| product | \`${PRODUCT}\` -> \`${PKGBASE}\` |"
    echo "| kernel source | \`${KERNEL_SOURCE}\` \`${KERNEL_REF}\` |"
    echo "| base | \`${SRC_TOPDIR}\` |"
    echo "| pkgver | \`${PKGVER}-${PKGREL:-1}\` |"
    if [ "${SERIES}" = armada ]; then
        echo "| series | armada \`${ARMADA_REF:0:12}\`, taken whole: ${SERIES_TOTAL} upstream − ${#denied[@]} denied + ${#SERIES_EXTRA[@]} extra = **${#SERIES_PATCHES[@]} applied** |"
        [ ${#denied[@]} -eq 0 ] || printf '| denied | `%s` |\n' "${denied[@]}"
    else
        echo "| series | \`${SERIES}\` (local) -- ${#SERIES_PATCHES[@]} patches |"
    fi
    echo "| boards | ${PRODUCT_BOARDS:-unnamed} -- ${#DTB[@]} dtb(s) |"
    if [ -n "${CACHY_SCHED:-}" ]; then
        echo "| cachy scheduler | \`${CACHY_SCHED}\` -- ${cachy_major}/sched/${cachy_patch} @ \`${CACHY_PATCHES_REF:0:12}\`, fuzz allowed |"
    else
        echo "| cachy scheduler | the tree's own (EEVDF + gaming-sched) |"
    fi
    if [ "${USE_OGC}" = yes ]; then
        echo "| OGC patches | ${#OGC_SERIES[@]} of ${#ogc_names[@]} |"
    else
        echo "| OGC patches | off for this product |"
    fi
    echo "| tarball sha256 | \`${SRC_SHA}\` |"
    if [ ${#NOTES[@]} -gt 0 ]; then
        echo; echo "#### Notes"; echo
        printf -- '- %s\n' "${NOTES[@]}"
    fi
    if [ ${#ogc_unselected[@]} -gt 0 ]; then
        echo; echo "<details><summary>OGC patches not selected (${#ogc_unselected[@]})</summary>"; echo
        printf -- '- `%s`\n' "${ogc_unselected[@]}"
        echo; echo "</details>"
    fi
} > .fetch-report.md

echo "──────────────────────────────────────────────"
printf ' device patches : %d  (armada %d new, ROCKNIX %d)\n' "${#SERIES_PATCHES[@]}" "${n_armada}" "${n_rocknix}"
printf ' OGC patches    : %d of %d%s\n' "${#OGC_SERIES[@]}" "${#ogc_names[@]}" "$([ "${USE_OGC}" = yes ] || echo "  (off)")"
printf ' staged (unused): %d\n' "$(ls -1 patches/rocknix-staged 2>/dev/null | wc -l)"
echo "──────────────────────────────────────────────"
[ ${#NOTES[@]} -gt 0 ] && printf "${YLW}  ~ %s${OFF}\n" "${NOTES[@]}"

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo
    echo "${RED}${#FAILURES[@]} problem(s):${OFF}" >&2
    printf "${RED}  !! %s${OFF}\n" "${FAILURES[@]}" >&2
    exit 1
fi

# Success, and only success: this is what lets everything downstream treat the
# file's existence as "the resolve is good".
mv "${TMP}/version.env" version.env
echo "${GRN}ok${OFF}  -> patches/series.generated, version.env"
