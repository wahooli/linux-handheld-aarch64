#!/usr/bin/env bash
# shellcheck disable=SC2034  # DTB/DTS arrays are consumed by the PKGBUILD
#
# Resolve the whole patch stack, the board device trees, and the mainline base,
# from the refs pinned in sources.env. Nothing this script downloads is
# committed -- that is the point. What IS committed is the manifests it reads:
#
#   patches/series.d/<device>.series   which armada patches, in what order
#   patches/ogc.select                 which OGC patches, by name regex
#   patches/local/series               patches authored here, applied last
#
# ---------------------------------------------------------------------------
# Why three sources, in this order
#
#   armada-os/armada-packages  Device support, already rebased onto our base.
#                              PRIMARY. ROCKNIX authors most of it, but armada
#                              does the rebase, and the rebase is the expensive
#                              part.
#   ROCKNIX/distribution       The true upstream, but it builds SM8750 against
#                              7.1.3. Fallback source for patches armada lacks,
#                              and the source for the staged-not-applied set.
#   OpenGamingCollective/linux An x86 handheld tree with nothing to say about
#                              Qualcomm. We take only the arch-independent
#                              parts -- currently the scheduler block.
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
#   version.env                  base version, tarball URL + sha256, pkgver
#   .fetch-report.md             job summary fragment for CI
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# shellcheck source=/dev/null
source ./sources.env

# Env overrides win over sources.env, so CI and one-off experiments do not need
# to dirty the tree.
OGC_REF="${OGC_REF_OVERRIDE:-${OGC_REF}}"
ARMADA_REF="${ARMADA_REF_OVERRIDE:-${ARMADA_REF}}"
ROCKNIX_REF="${ROCKNIX_REF_OVERRIDE:-${ROCKNIX_REF}}"
BASE_VERSION="${BASE_VERSION_OVERRIDE:-${BASE_VERSION}}"
DEVICES="${DEVICES_OVERRIDE:-${DEVICES}}"

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

# Verify OGC's per-patch signatures. On by default: it is cheap, and the pinned
# ref alone is not integrity when the patches are no longer committed.
OGC_VERIFY="${OGC_VERIFY:-1}"
# Verify the kernel tarball's PGP signature against the kernel.org release keys.
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
# 1. Base kernel version, derived from the OGC tag
# ===========================================================================
# v7.2.1-ogc3  -> base 7.2.1, ogc rev 3
# v7.2-ogc9    -> base 7.2,   ogc rev 9
# v7.2-rc7-ogc7-> base 7.2-rc7, ogc rev 7
[[ "${OGC_REF}" =~ ^v?(.+)-ogc([0-9]+)$ ]] || {
    echo "${RED}OGC_REF='${OGC_REF}' is not a <version>-ogc<N> tag${OFF}" >&2
    exit 1
}
_derived_base="${BASH_REMATCH[1]}"
OGC_REV="${BASH_REMATCH[2]}"

if [ -n "${BASE_VERSION}" ]; then
    BASE="${BASE_VERSION}"
    [ "${BASE}" = "${_derived_base}" ] || note \
        "base PINNED to ${BASE}; OGC_REF ${OGC_REF} targets ${_derived_base}. The OGC patches were not written against this tree."
else
    BASE="${_derived_base}"
fi

KMAJOR="${BASE%%.*}"
if [[ "${BASE}" == *-rc* ]]; then
    IS_RC=1
    SRC_URL="https://git.kernel.org/torvalds/t/linux-${BASE}.tar.gz"
    SRC_TAR="linux-${BASE}.tar.gz"
else
    IS_RC=
    SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/linux-${BASE}.tar.xz"
    SRC_TAR="linux-${BASE}.tar.xz"
fi

# pkgver must not contain '-'. Release bases never do; rc bases do.
PKGVER="${BASE//-/}.ogc${OGC_REV}"
[ -n "${IS_RC}" ] && note \
    "base is an -rc. pkgver is ${PKGVER}; pacman sorts '7.2rc7.ogcN' AFTER '7.2.ogcN', so an rc-to-release move needs an epoch bump in the PKGBUILD."

echo "==> base       linux-${BASE}   (from ${OGC_REF})"
echo "==> armada     ${ARMADA_REF:0:12}"
echo "==> ROCKNIX    ${ROCKNIX_REF}   ${DIM}(staged set: ${ROCKNIX_STAGED_REF})${OFF}"
echo "==> devices    ${DEVICES}"
echo

# ===========================================================================
# 2. Kernel tarball: fetch, verify, record the checksum
# ===========================================================================
# This is what closes the sha256sums=('SKIP') TODO the old package carried. The
# PKGBUILD gets a real checksum written into version.env, and in the normal
# (release) case that checksum is anchored to a kernel.org PGP signature rather
# than to whatever the CDN happened to serve us.
KERNEL_SIGNERS=(
    647F28654894E3BD457199BE38DBBDC86092693E   # Greg Kroah-Hartman <gregkh@kernel.org>
    ABAF11C65A2970B130ABE3C479BE3E4300411886   # Linus Torvalds <torvalds@kernel.org>
    E27E5D8A3403A2EF66873BBCDEA66FF797772CDC   # Sasha Levin <sashal@kernel.org>
)

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

if [ -n "${KERNEL_VERIFY}" ] && [ -z "${IS_RC}" ]; then
    # kernel.org signs the UNCOMPRESSED tar, so decompress to verify.
    export GNUPGHOME="${TMP}/kgnupg"; mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
    if curl -fsSL --retry 3 -o "${TMP}/linux.tar.sign" \
         "https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/linux-${BASE}.tar.sign" \
       && gpg --batch --quiet --auto-key-locate wkd \
            --locate-keys gregkh@kernel.org torvalds@kernel.org sashal@kernel.org >/dev/null 2>&1
    then
        # Only trust the three fingerprints above; WKD alone proves nothing.
        for fpr in "${KERNEL_SIGNERS[@]}"; do
            gpg --batch --quiet --import-ownertrust <<< "${fpr}:6:" 2>/dev/null || true
        done
        xz -dc "${CACHED}" > "${TMP}/linux.tar"
        if gpg --batch --status-fd 3 --verify "${TMP}/linux.tar.sign" "${TMP}/linux.tar" 3>"${TMP}/gpgstatus" 2>/dev/null \
           && grep -qE "^\[GNUPG:\] VALIDSIG ($(IFS='|'; echo "${KERNEL_SIGNERS[*]}"))" "${TMP}/gpgstatus"
        then
            signer="$(awk '/VALIDSIG/{print $3}' "${TMP}/gpgstatus")"
            echo "  ${GRN}verified${OFF} linux-${BASE}.tar  signed by ${signer:0:16}..."
        else
            fail "upstream: linux-${BASE}.tar PGP signature did not verify against a known kernel.org signer"
        fi
        rm -f "${TMP}/linux.tar"
    else
        fail "upstream: could not fetch linux-${BASE}.tar.sign or the kernel.org keys (set KERNEL_VERIFY= to skip)"
    fi
    unset GNUPGHOME
elif [ -n "${IS_RC}" ]; then
    note "base is an -rc: git.kernel.org snapshots are unsigned, so the tarball is trust-on-first-use at sha256 ${SRC_SHA:0:16}..."
fi
echo "  sha256  ${SRC_SHA}"
echo

# ===========================================================================
# 3. OGC: select by name, guard contiguity, fetch
# ===========================================================================
mkdir -p patches dts

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

ogc_selected=()       # "0028 0028-FROM-ML-....patch"
ogc_unselected=()
ogc_names=()

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

    OGC_SERIES=(); n_new=0; n_bad=0
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
echo

# ===========================================================================
# 4. Device patches and device trees
# ===========================================================================
try_armada() { curl -fsSL --retry 3 -o "$2" "${ARMADA_RAW}/$1"; }
# ROCKNIX spreads patches over several directories, so most probes are expected
# to 404. No --retry (a 404 is not transient) and stderr is dropped, or every
# lookup narrates four failures before the one that works.
try_rocknix() {
    local name="$1" out="$2" d root="${3:-${ROCKNIX_RAW}}"
    for d in "${ROCKNIX_DIRS[@]}"; do
        curl -fsSL -o "${out}" "${root}/${d}/${name}" 2>/dev/null && return 0
    done
    return 1
}

DEVICE_SERIES=(); seen_patch=" "
n_armada=0; n_rocknix=0

for dev in ${DEVICES}; do
    conf="devices/${dev}.conf"
    [ -f "${conf}" ] || { fail "upstream: no ${conf} for device '${dev}' listed in DEVICES"; continue; }
    # shellcheck source=/dev/null
    # Reset before sourcing so a previous device's arrays cannot leak into this
    # one. DTB is unused here on purpose -- only the PKGBUILD installs dtbs --
    # but it still has to be cleared, or device N+1 inherits device N's list.
    # shellcheck disable=SC2034
    DTS=(); DTS_DELTA=(); DTB=(); ROCKNIX_STAGED=(); ROCKNIX_DIRS=(); source "${conf}"
    echo "==> device ${dev} -- ${DEVICE_DESC}"

    while IFS= read -r line; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [ -n "${line}" ] || continue
        [[ "${seen_patch}" == *" ${line} "* ]] && continue   # shared across devices
        seen_patch+="${line} "
        DEVICE_SERIES+=("${line}")
        out="patches/${line}"
        if [ -f "${out}" ] && [ -z "${FORCE}" ]; then continue; fi
        if try_armada "patches/${line}" "${out}"; then
            n_armada=$((n_armada+1))
        elif try_rocknix "${line}" "${out}"; then
            n_rocknix=$((n_rocknix+1))
            note "${line} came from ROCKNIX (7.1.3-based), not armada -- verify it applies"
        else
            rm -f "${out}"
            fail "upstream: ${line} not found in armada@${ARMADA_REF:0:12} or ROCKNIX@${ROCKNIX_REF}"
        fi
    done < "${SERIES}"

    for f in "${DTS[@]}" "${DTS_DELTA[@]}"; do
        [ -f "dts/${f}" ] && [ -z "${FORCE}" ] && continue
        try_armada "dts/${f}" "dts/${f}" || { rm -f "dts/${f}"; fail "upstream: dts/${f} not in armada@${ARMADA_REF:0:12}"; }
    done

    # Staged, never applied. The dry-run report lives in scripts/build.sh.
    if [ ${#ROCKNIX_STAGED[@]} -gt 0 ]; then
        mkdir -p patches/rocknix-staged
        for f in "${ROCKNIX_STAGED[@]}"; do
            [ -f "patches/rocknix-staged/${f}" ] && [ -z "${FORCE}" ] && continue
            try_rocknix "${f}" "patches/rocknix-staged/${f}" "${ROCKNIX_STAGED_RAW}" \
                || { rm -f "patches/rocknix-staged/${f}"; note "ROCKNIX-staged ${f} not found at ${ROCKNIX_STAGED_REF} (upstream may have renamed or dropped it)"; }
        done
    fi
    echo "  ${#DEVICE_SERIES[@]} patches, ${#DTS[@]} device trees"
done
echo

# ===========================================================================
# 5. Local patches
# ===========================================================================
# Never fetched -- they are committed, because they have no upstream.
LOCAL_SERIES=()
while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [ -n "${line}" ] || continue
    if [ -f "patches/local/${line}" ]; then
        LOCAL_SERIES+=("local/${line}")
    else
        fail "local: patches/local/${line} is named in patches/local/series but does not exist"
    fi
done < patches/local/series
[ ${#LOCAL_SERIES[@]} -gt 0 ] \
    && echo "==> local   ${#LOCAL_SERIES[@]} repo-specific patches" \
    || echo "==> local   none"
echo

# ===========================================================================
# 6. Generated outputs
# ===========================================================================
{
    echo "# GENERATED by scripts/fetch-patches.sh -- do not edit, do not commit."
    echo "# base ${BASE} | ogc ${OGC_REF} | armada ${ARMADA_REF:0:12} | rocknix ${ROCKNIX_REF}"
    echo "# devices: ${DEVICES}"
    echo
    echo "# --- device stack -------------------------------------------------"
    printf '%s\n' "${DEVICE_SERIES[@]}"
    if [ ${#OGC_SERIES[@]} -gt 0 ]; then
        echo
        echo "# --- OGC, arch-independent ----------------------------------------"
        echo "# Applies after the device stack: nothing here touches Qualcomm code,"
        echo "# so the relative ordering is irrelevant."
        printf '%s\n' "${OGC_SERIES[@]}"
    fi
    if [ ${#LOCAL_SERIES[@]} -gt 0 ]; then
        echo
        echo "# --- local, authored in this repo ---------------------------------"
        printf '%s\n' "${LOCAL_SERIES[@]}"
    fi
} > patches/series.generated

# Drop any fetched patch the generated series no longer references, so the
# directory cannot accumulate orphans across a series edit.
refs=" $(grep -vE '^\s*(#|$)' patches/series.generated | tr '\n' ' ') "
for f in patches/*.patch; do
    [ -e "${f}" ] || continue
    b="$(basename "${f}")"
    [[ "${refs}" == *" ${b} "* ]] || { echo "  ${DIM}prune   ${b}${OFF}"; rm -f "${f}"; }
done

cat > version.env <<EOF
# GENERATED by scripts/fetch-patches.sh from sources.env -- do not edit.
# The PKGBUILD sources this, so there is exactly one place that decides which
# kernel gets built.
_base=${BASE}
_ogcrev=${OGC_REV}
_srcname=linux-${BASE}
_srcurl=${SRC_URL}
_srcsha256=${SRC_SHA}
pkgver=${PKGVER}
pkgrel=${PKGREL:-1}
_ogcref=${OGC_REF}
_armadaref=${ARMADA_REF}
_rocknixref=${ROCKNIX_REF}
_devices="${DEVICES}"
EOF

# ===========================================================================
# 7. Report
# ===========================================================================
{
    echo "### Patch stack"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| base | \`linux-${BASE}\` (from \`${OGC_REF}\`) |"
    echo "| pkgver | \`${PKGVER}-${PKGREL:-1}\` |"
    echo "| device patches | ${#DEVICE_SERIES[@]} (armada \`${ARMADA_REF:0:12}\`) |"
    echo "| OGC patches | ${#OGC_SERIES[@]} of ${#ogc_names[@]} |"
    echo "| local patches | ${#LOCAL_SERIES[@]} |"
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
printf ' device patches : %d  (armada %d new, ROCKNIX %d)\n' "${#DEVICE_SERIES[@]}" "${n_armada}" "${n_rocknix}"
printf ' OGC patches    : %d of %d\n' "${#OGC_SERIES[@]}" "${#ogc_names[@]}"
printf ' local patches  : %d\n' "${#LOCAL_SERIES[@]}"
printf ' staged (unused): %d\n' "$(ls -1 patches/rocknix-staged 2>/dev/null | wc -l)"
echo "──────────────────────────────────────────────"
[ ${#NOTES[@]} -gt 0 ] && printf "${YLW}  ~ %s${OFF}\n" "${NOTES[@]}"

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo
    echo "${RED}${#FAILURES[@]} problem(s):${OFF}" >&2
    printf "${RED}  !! %s${OFF}\n" "${FAILURES[@]}" >&2
    exit 1
fi
echo "${GRN}ok${OFF}  -> patches/series.generated, version.env"
