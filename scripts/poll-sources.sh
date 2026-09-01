#!/usr/bin/env bash
#
# Check the upstreams every product depends on for movement, and rewrite
# sources.env if any moved.
#
# Prints a report and exits 0 either way. Whether a build follows is the
# workflow's decision, not this script's -- it only reports, via the lines it
# appends to $GITHUB_OUTPUT.
#
# WHICH upstreams get polled depends on what the products actually use. A source
# nothing selects is not polled and not reported: bumping a ref no build reads
# would produce a commit, a dispatched build, and an identical kernel. That is
# how the OGC ref used to move the whole pipeline after the base swap made it
# unused.
#
#   CachyOS  highest stable cachyos-X.Y[.Z]-N release, by version and not by
#            date -- LTS (6.18.x) and -rc tags are deliberately passed over
#   OGC      highest mainline-stable vX.Y[.Z]-ogcN release, same reasoning
#   ROCKNIX  latest release tag        (monthly cadence)
#   armada   newest commit touching kernel/, because armada-packages publishes
#            no tags or releases at all -- the patches only exist as commits on
#            main. Its kernel/ subtree moves roughly two or three times a week,
#            which is why this watches the subtree and not the branch head:
#            watching the branch would fire on every gamescope commit too.
#
# kernel.org is NOT polled: KERNELORG_REF is pinned by hand, because a product on
# that base exists to be held still while something else is under suspicion.
#
# Auth: GH_TOKEN if set, else anonymous (60 req/h, which is plenty).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"
# shellcheck source=/dev/null
source ./sources.env

API="https://api.github.com"
gh_get() {
    local url="$1"
    if [ -n "${GH_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" \
             -H "Accept: application/vnd.github+json" "${url}"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "${url}"
    fi
}

# ---------------------------------------------------------------------------
# Which sources are in use, across every product
# ---------------------------------------------------------------------------
# Each conf is read in a SUBSHELL: they set the same variable names, so sourcing
# two here would leave the last one's values standing.
uses_cachyos=; uses_ogc=; uses_armada=; uses_rocknix=; product_list=()
for _p in ${PRODUCTS}; do
    conf="products/${_p}.conf"
    [ -f "${conf}" ] || { echo "!! PRODUCTS names ${_p} but ${conf} is missing" >&2; exit 1; }
    product_list+=("${_p}")
    # shellcheck disable=SC1090
    read -r ks ogc arm rock < <( . "${conf}" >/dev/null 2>&1
                                 echo "${KERNEL_SOURCE:-} ${USE_OGC:-no} ${USE_ARMADA:-no} ${USE_ROCKNIX:-no}" )
    [ "${ks}"   = cachyos ] && uses_cachyos=1
    [ "${ogc}"  = yes ]     && uses_ogc=1
    [ "${arm}"  = yes ]     && uses_armada=1
    [ "${rock}" = yes ]     && uses_rocknix=1
done

echo "==> polling for ${#product_list[@]} product(s): ${product_list[*]}"

changed=(); outputs=()
new_cachyos="${CACHYOS_REF:-}"; new_ogc="${OGC_REF:-}"
new_armada="${ARMADA_REF:-}";   new_rocknix="${ROCKNIX_REF:-}"

# ---------------------------------------------------------------------------
# CachyOS
# ---------------------------------------------------------------------------
# Two traps, same as OGC:
#
#   LTS  CachyOS tags LTS maintenance releases alongside mainline
#        (cachyos-6.18.48-2 published after cachyos-7.2.2-1), so picking by
#        publication date walks the base backwards.
#   rc   cachyos-7.3-rc1-2 is not flagged prerelease, so the API flag does not
#        hold it back; the numeric-only pattern excludes it instead.
#
# Ordered by [major, minor, patch, tagrel], so a new tag revision of the same
# kernel (-1 -> -2, a rebase of CachyOS's branches) counts as movement.
if [ -n "${uses_cachyos}" ]; then
    cachy_json="$(gh_get "${API}/repos/CachyOS/linux/releases?per_page=100")"
    new_cachyos="$(jq -r '
        [ .[]
          | select(.draft == false)
          | .tag_name
          | . as $tag
          | capture("^cachyos-(?<x>[0-9]+)\\.(?<y>[0-9]+)(\\.(?<z>[0-9]+))?-(?<n>[0-9]+)$")
          | { tag: $tag,
              ver: [(.x|tonumber), (.y|tonumber), (.z // "0"|tonumber), (.n|tonumber)] } ]
        | sort_by(.ver) | last | .tag // empty' <<<"${cachy_json}")"
    [ -n "${new_cachyos}" ] || {
        echo "!! no stable cachyos-X.Y[.Z]-N tag in the newest 100 CachyOS releases" >&2
        exit 1
    }
    newest_any="$(jq -r '[.[] | select(.draft == false)] | .[0].tag_name // empty' <<<"${cachy_json}")"
    [ "${newest_any}" != "${new_cachyos}" ] && \
        echo "    (CachyOS's newest release ${newest_any} is not mainline stable; taking ${new_cachyos})"

    # The release must actually carry the two assets the build downloads. A tag
    # whose upload is still in flight, or that ships a different asset name,
    # otherwise fails fifty minutes into a build instead of here.
    if [ "${new_cachyos}" != "${CACHYOS_REF}" ]; then
        base_url="https://github.com/CachyOS/linux/releases/download/${new_cachyos}/${new_cachyos}.tar.gz"
        for u in "${base_url}" "${base_url}.asc"; do
            curl -fsIL --retry 2 -o /dev/null "${u}" || {
                echo "!! ${new_cachyos}: ${u##*/} is not downloadable yet" >&2
                echo "!! refusing the bump; sources.env stays at ${CACHYOS_REF}" >&2
                exit 1
            }
        done
    fi
    [ "${new_cachyos}" != "${CACHYOS_REF}" ] && changed+=("CachyOS ${CACHYOS_REF} -> ${new_cachyos}")
    outputs+=("cachyos_ref=${new_cachyos}")
fi

# ---------------------------------------------------------------------------
# OGC
# ---------------------------------------------------------------------------
if [ -n "${uses_ogc}" ]; then
    ogc_json="$(gh_get "${API}/repos/OpenGamingCollective/linux/releases?per_page=100")"
    new_ogc="$(jq -r '
        [ .[]
          | select(.draft == false and .prerelease == false)
          | .tag_name
          | . as $tag
          | capture("^v(?<x>[0-9]+)\\.(?<y>[0-9]+)(\\.(?<z>[0-9]+))?-ogc(?<n>[0-9]+)$")
          | { tag: $tag,
              ver: [(.x|tonumber), (.y|tonumber), (.z // "0"|tonumber), (.n|tonumber)] } ]
        | sort_by(.ver) | last | .tag // empty' <<<"${ogc_json}")"
    [ -n "${new_ogc}" ] || {
        echo "!! no mainline-stable vX.Y[.Z]-ogcN tag in the newest 100 OGC releases" >&2
        exit 1
    }
    newest_ogc="$(jq -r '[.[] | select(.draft == false and .prerelease == false)]
                         | .[0].tag_name // empty' <<<"${ogc_json}")"
    [ "${newest_ogc}" != "${new_ogc}" ] && \
        echo "    (OGC's newest release ${newest_ogc} is not mainline stable; taking ${new_ogc})"

    # An OGC bump only implies a kernel.org tarball for a product that derives
    # its base from the tag -- i.e. KERNEL_SOURCE=kernel.org with no explicit
    # ref. On a cachyos product the tag supplies patches only, and the base is
    # untouched, so there is nothing to resolve.
    if [ "${new_ogc}" != "${OGC_REF}" ] && [ -z "${KERNELORG_REF:-}" ] && [ -z "${BASE_VERSION:-}" ]; then
        if [[ "${new_ogc}" =~ ^v?(.+)-ogc[0-9]+$ ]]; then
            b="${BASH_REMATCH[1]}"; km="${b%%.*}"
            curl -fsSL --head --retry 2 -o /dev/null \
                "https://cdn.kernel.org/pub/linux/kernel/v${km}.x/linux-${b}.tar.xz" || {
                echo "!! ${new_ogc}: no kernel.org tarball for the base it implies" >&2
                echo "!! refusing the bump; sources.env stays at ${OGC_REF}" >&2
                exit 1
            }
        fi
    fi
    [ "${new_ogc}" != "${OGC_REF}" ] && changed+=("OGC ${OGC_REF} -> ${new_ogc}")
    outputs+=("ogc_ref=${new_ogc}")
fi

# ---------------------------------------------------------------------------
# ROCKNIX and armada
# ---------------------------------------------------------------------------
if [ -n "${uses_rocknix}" ]; then
    new_rocknix="$(gh_get "${API}/repos/ROCKNIX/distribution/releases?per_page=10" \
        | jq -r '[.[] | select(.draft == false and .prerelease == false)] | .[0].tag_name // empty')"
    [ -n "${new_rocknix}" ] || { echo "!! could not read ROCKNIX releases" >&2; exit 1; }
    [ "${new_rocknix}" != "${ROCKNIX_REF}" ] && changed+=("ROCKNIX ${ROCKNIX_REF} -> ${new_rocknix}")
    outputs+=("rocknix_ref=${new_rocknix}")
fi

if [ -n "${uses_armada}" ]; then
    new_armada="$(gh_get "${API}/repos/armada-os/armada-packages/commits?path=kernel&per_page=1" \
        | jq -r '.[0].sha // empty')"
    [ -n "${new_armada}" ] || { echo "!! could not read armada commits" >&2; exit 1; }
    [ "${new_armada}" != "${ARMADA_REF}" ] && changed+=("armada ${ARMADA_REF:0:12} -> ${new_armada:0:12}")
    outputs+=("armada_ref=${new_armada}")
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
row() {   # $1 label, $2 current, $3 new, $4 in-use flag
    if [ -z "${4}" ]; then
        printf '    %-9s %-26s %s\n' "${1}" "${2:-–}" "not used by any product"
    elif [ "${2}" = "${3}" ]; then
        printf '    %-9s %-26s %s\n' "${1}" "${2}" "unchanged"
    else
        printf '    %-9s %-26s %s\n' "${1}" "${2}" "-> ${3}"
    fi
}
row CachyOS "${CACHYOS_REF:-}"      "${new_cachyos}"      "${uses_cachyos}"
row OGC     "${OGC_REF:-}"          "${new_ogc}"          "${uses_ogc}"
row ROCKNIX "${ROCKNIX_REF:-}"      "${new_rocknix}"      "${uses_rocknix}"
row armada  "${ARMADA_REF:0:12}"    "${new_armada:0:12}"  "${uses_armada}"

if [ ${#changed[@]} -eq 0 ]; then
    echo "nothing moved"
    [ -n "${GITHUB_OUTPUT:-}" ] && echo "changed=false" >> "${GITHUB_OUTPUT}"
    exit 0
fi

# Rewrite in place, touching only the values that moved. sed rather than
# regenerating the file, because the comments in sources.env are the
# documentation for what each ref means and they must survive an automated edit.
[ -n "${uses_cachyos}" ] && sed -i "s|^CACHYOS_REF=.*|CACHYOS_REF=${new_cachyos}|" sources.env
[ -n "${uses_ogc}" ]     && sed -i "s|^OGC_REF=.*|OGC_REF=${new_ogc}|"             sources.env
[ -n "${uses_armada}" ]  && sed -i "s|^ARMADA_REF=.*|ARMADA_REF=${new_armada}|"    sources.env
[ -n "${uses_rocknix}" ] && sed -i "s|^ROCKNIX_REF=.*|ROCKNIX_REF=${new_rocknix}|" sources.env

# Re-read to prove the edits landed; a silently-failed sed would otherwise mean
# the poller commits nothing and reports success forever.
# shellcheck source=/dev/null
( source ./sources.env
  [ -z "${uses_cachyos}" ] || [ "${CACHYOS_REF}" = "${new_cachyos}" ] || exit 1
  [ -z "${uses_ogc}" ]     || [ "${OGC_REF}"     = "${new_ogc}" ]     || exit 1
  [ -z "${uses_armada}" ]  || [ "${ARMADA_REF}"  = "${new_armada}" ]  || exit 1
  [ -z "${uses_rocknix}" ] || [ "${ROCKNIX_REF}" = "${new_rocknix}" ] || exit 1 ) \
  || { echo "!! sources.env did not take the new refs" >&2; exit 1; }

summary="$(IFS='; '; echo "${changed[*]}")"
echo
echo "changed: ${summary}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "changed=true"
        echo "summary=${summary}"
        printf '%s\n' "${outputs[@]}"
    } >> "${GITHUB_OUTPUT}"
fi
