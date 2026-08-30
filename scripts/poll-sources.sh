#!/usr/bin/env bash
#
# Check the three upstreams for movement and rewrite sources.env if any moved.
#
# Prints nothing but a report when nothing changed; exits 0 either way. Whether
# a build follows is the workflow's decision, not this script's -- it only
# reports, via the CHANGED=... lines it appends to $GITHUB_OUTPUT.
#
#   OGC      latest non-draft, non-prerelease release tag
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
new_ogc="$(gh_get "${API}/repos/OpenGamingCollective/linux/releases?per_page=20" \
    | jq -r '[.[] | select(.draft == false and .prerelease == false)] | .[0].tag_name // empty')"
[ -n "${new_ogc}" ] || { echo "!! could not read OGC releases" >&2; exit 1; }

# ---- ROCKNIX --------------------------------------------------------------
new_rocknix="$(gh_get "${API}/repos/ROCKNIX/distribution/releases?per_page=10" \
    | jq -r '[.[] | select(.draft == false and .prerelease == false)] | .[0].tag_name // empty')"
[ -n "${new_rocknix}" ] || { echo "!! could not read ROCKNIX releases" >&2; exit 1; }

# ---- armada ---------------------------------------------------------------
new_armada="$(gh_get "${API}/repos/armada-os/armada-packages/commits?path=kernel&per_page=1" \
    | jq -r '.[0].sha // empty')"
[ -n "${new_armada}" ] || { echo "!! could not read armada commits" >&2; exit 1; }

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
