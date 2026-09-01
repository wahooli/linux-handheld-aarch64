#!/usr/bin/env bash
#
# Check the three upstreams for movement and rewrite sources.env if any moved.
#
# Prints nothing but a report when nothing changed; exits 0 either way. Whether
# a build follows is the workflow's decision, not this script's -- it only
# reports, via the CHANGED=... lines it appends to $GITHUB_OUTPUT.
#
#   OGC      highest mainline-stable vX.Y[.Z]-ogcN release, by version and not
#            by date -- LTS and -rc tags are deliberately passed over
#   ROCKNIX  latest release tag        (monthly cadence)
#   armada   newest commit touching kernel/, because armada-packages publishes
#            no tags or releases at all -- the patches only exist as commits on
#            main. Its kernel/ subtree moves roughly two or three times a week,
#            which is why this watches the subtree and not the branch head:
#            watching the branch would fire on every gamescope commit too.
#
# Auth: GH_TOKEN if set, else anonymous (60 req/h, which is plenty for 3 calls).
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

echo "==> polling upstreams"

# ---- OGC ------------------------------------------------------------------
#
# Two things the obvious ".[0].tag_name" gets wrong, and both have landed in
# sources.env already:
#
#   LTS  OGC cuts maintenance releases off the LTS branch alongside mainline,
#        e.g. v6.18.48-lts-ogc1 published after v7.2.1-ogc3. The API returns
#        newest-published first, so picking by date walked the base version
#        backwards -- and it does not even build: fetch-patches.sh derives base
#        "6.18.48-lts" from that tag, and cdn.kernel.org has no matching
#        linux-6.18.48-lts.tar.xz.
#   rc   GitHub's prerelease flag is not set on OGC's -rc tags (v7.2-rc7-ogc7
#        is prerelease=false), so select(.prerelease == false) does not hold
#        them back on its own.
#
# So accept only mainline-stable vX.Y[.Z]-ogcN -- which excludes both by
# construction -- and order by version rather than by publication date. The
# draft/prerelease filter stays as a second line of defence.
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

# Say so when the newest release is one we deliberately passed over, otherwise a
# long LTS-only stretch upstream looks identical to upstream being quiet.
newest_ogc="$(jq -r '[.[] | select(.draft == false and .prerelease == false)]
                     | .[0].tag_name // empty' <<<"${ogc_json}")"
[ "${newest_ogc}" != "${new_ogc}" ] && \
    echo "    (OGC's newest release ${newest_ogc} is not mainline stable; taking ${new_ogc})"

# ---- ROCKNIX --------------------------------------------------------------
new_rocknix="$(gh_get "${API}/repos/ROCKNIX/distribution/releases?per_page=10" \
    | jq -r '[.[] | select(.draft == false and .prerelease == false)] | .[0].tag_name // empty')"
[ -n "${new_rocknix}" ] || { echo "!! could not read ROCKNIX releases" >&2; exit 1; }

# ---- armada ---------------------------------------------------------------
new_armada="$(gh_get "${API}/repos/armada-os/armada-packages/commits?path=kernel&per_page=1" \
    | jq -r '.[0].sha // empty')"
[ -n "${new_armada}" ] || { echo "!! could not read armada commits" >&2; exit 1; }

# ---- the tarball the new OGC tag implies must actually exist ---------------
#
# main takes a bump optimistically: poll.yml commits sources.env and only then
# dispatches the build, and a GITHUB_TOKEN push fires no events, so check.yml
# never sees a poller commit either. That leaves this script as the only thing
# standing between a bad tag and main, so resolve the tag to a tarball here
# rather than finding out a minute into a fifty-minute build.
#
# Mirrors the derivation in fetch-patches.sh section 1 -- the -rc branch is
# omitted deliberately, because the selector above cannot return an -rc tag.
ogc_base_exists() {
    local tag="$1" base kmajor url
    [[ "${tag}" =~ ^v?(.+)-ogc[0-9]+$ ]] || return 1
    base="${BASH_REMATCH[1]}"
    kmajor="${base%%.*}"
    url="https://cdn.kernel.org/pub/linux/kernel/v${kmajor}.x/linux-${base}.tar.xz"
    curl -fsSL --head --retry 2 -o /dev/null "${url}"
}

if [ "${new_ogc}" != "${OGC_REF}" ] && [ -z "${BASE_VERSION:-}" ]; then
    if ! ogc_base_exists "${new_ogc}"; then
        echo "!! ${new_ogc}: no kernel.org tarball for the base it implies (curl said why)" >&2
        echo "!! refusing the bump; sources.env stays at ${OGC_REF}" >&2
        exit 1
    fi
fi
# BASE_VERSION pins the base by hand, so the tag's implied tarball is not what
# gets downloaded and there is nothing here to verify.

changed=()
[ "${new_ogc}"     != "${OGC_REF}" ]     && changed+=("OGC ${OGC_REF} -> ${new_ogc}")
[ "${new_rocknix}" != "${ROCKNIX_REF}" ] && changed+=("ROCKNIX ${ROCKNIX_REF} -> ${new_rocknix}")
[ "${new_armada}"  != "${ARMADA_REF}" ]  && changed+=("armada ${ARMADA_REF:0:12} -> ${new_armada:0:12}")

printf '    OGC      %-24s %s\n' "${OGC_REF}"        "$([ "${new_ogc}"     = "${OGC_REF}" ]     && echo "unchanged" || echo "-> ${new_ogc}")"
printf '    ROCKNIX  %-24s %s\n' "${ROCKNIX_REF}"    "$([ "${new_rocknix}" = "${ROCKNIX_REF}" ] && echo "unchanged" || echo "-> ${new_rocknix}")"
printf '    armada   %-24s %s\n' "${ARMADA_REF:0:12}" "$([ "${new_armada}"  = "${ARMADA_REF}" ]  && echo "unchanged" || echo "-> ${new_armada:0:12}")"

if [ ${#changed[@]} -eq 0 ]; then
    echo "nothing moved"
    [ -n "${GITHUB_OUTPUT:-}" ] && echo "changed=false" >> "${GITHUB_OUTPUT}"
    exit 0
fi

# Rewrite in place, touching only the three values. sed rather than regenerating
# the file, because the comments in sources.env are the documentation for what
# each ref means and they must survive an automated edit.
sed -i \
    -e "s|^OGC_REF=.*|OGC_REF=${new_ogc}|" \
    -e "s|^ARMADA_REF=.*|ARMADA_REF=${new_armada}|" \
    -e "s|^ROCKNIX_REF=.*|ROCKNIX_REF=${new_rocknix}|" \
    sources.env

# Re-read to prove the edit landed; a silently-failed sed would otherwise mean
# the poller commits nothing and reports success forever.
# shellcheck source=/dev/null
( source ./sources.env
  [ "${OGC_REF}" = "${new_ogc}" ] && [ "${ARMADA_REF}" = "${new_armada}" ] \
      && [ "${ROCKNIX_REF}" = "${new_rocknix}" ] ) \
  || { echo "!! sources.env did not take the new refs" >&2; exit 1; }

summary="$(IFS='; '; echo "${changed[*]}")"
echo
echo "changed: ${summary}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "changed=true"
        echo "summary=${summary}"
        echo "ogc_ref=${new_ogc}"
        echo "armada_ref=${new_armada}"
        echo "rocknix_ref=${new_rocknix}"
    } >> "${GITHUB_OUTPUT}"
fi
