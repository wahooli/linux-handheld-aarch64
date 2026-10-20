#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkgver/pkgrel/_* all come from version.env
#
# Tag a successful publish and cut the matching GitHub release. Needs GH_TOKEN and push rights.
# Only after publish-r2.sh succeeds: an unpublished tag is false provenance and burns a pkgrel.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-product.sh
source "${HERE}/scripts/lib-product.sh"
lp_load "${HERE}"
# shellcheck source=/dev/null
source ./version.env

[ "${_product}" = "${PRODUCT}" ] || {
    echo "!! version.env is for product '${_product}' but PRODUCT is '${PRODUCT}'" >&2; exit 1; }

# Never rename TAG_PREFIX: tags are next-pkgrel.sh's floor, so lost history can reuse a live filename.
TAG="${TAG_PREFIX}${pkgver}-${pkgrel}"
# Entries of a local series live in patches/<product>/ or patches/shared/; 'armada' is not a file.
NCOMMITTED=0
[ -f "${_series}" ] && NCOMMITTED="$(grep -cvE '^[[:space:]]*(#|$)' "${_series}")"

# Name OGC only if it contributed; anything else is false provenance.
if [ "${_useogc}" = yes ]; then OGC_LINE="OGC           ${_ogcref}"; else OGC_LINE="OGC           not used"; fi

# Checked before tagging: a phantom tag burns a pkgrel. Only this product's files: out/ holds every product's.
mapfile -t ASSETS < <(ls "out/${_pkgbase}"-*.pkg.tar.zst "out/${_pkgbase}"-*.pkg.tar.zst.sig 2>/dev/null)
[ ${#ASSETS[@]} -gt 0 ] || {
    echo "!! no out/${_pkgbase}-*.pkg.tar.zst -- nothing published for ${_product}, refusing to tag" >&2; exit 1; }

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "!! tag ${TAG} already exists -- refusing to move it" >&2
    exit 1
fi

TAGGER_NAME="${GIT_AUTHOR_NAME:-github-actions[bot]}"
TAGGER_EMAIL="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
git config user.name  "${TAGGER_NAME}"
git config user.email "${TAGGER_EMAIL}"

# Resolved refs, not sources.env: the lasting answer to which inputs are on a device.
MSG="$(cat <<MSG
${_pkgbase} ${pkgver}-${pkgrel}

product       ${_product}
kernel source ${_kernelsource} ${_kernelref}
base kernel   ${_srcname}  (${_base})
  sha256      ${_srcsha256}
${OGC_LINE}
armada        ${_armadaref}
ROCKNIX       ${_rocknixref}
series        ${_series} (${_npatches} patches)
config        ${_configdirs}
dtbs          ${_dtbs}
committed     ${NCOMMITTED} patch(es) in patches/${_product}/ + patches/shared/
MSG
)"

# Via the Git Data API: a pushed tag on a commit main has moved past reads as a workflow edit and
# needs the workflows permission GITHUB_TOKEN cannot have. Local runs push with git.
if command -v gh >/dev/null && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    command -v jq >/dev/null || { echo "!! jq is required to create the tag via the API" >&2; exit 1; }
    REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
    TAGOBJ="$(jq -n \
        --arg tag "${TAG}" \
        --arg message "${MSG}" \
        --arg object "$(git rev-parse HEAD)" \
        --arg name "${TAGGER_NAME}" \
        --arg email "${TAGGER_EMAIL}" \
        --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{tag:$tag, message:$message, object:$object, type:"commit",
          tagger:{name:$name, email:$email, date:$date}}' \
        | gh api "repos/${REPO}/git/tags" --input - --jq .sha)"
    gh api "repos/${REPO}/git/refs" \
        -f "ref=refs/tags/${TAG}" -f "sha=${TAGOBJ}" >/dev/null
    # Fetch the ref back; re-creating it locally would mint a second tag object.
    git fetch -q origin "refs/tags/${TAG}:refs/tags/${TAG}" || true
else
    git tag -a "${TAG}" -F - <<< "${MSG}"
    git push origin "${TAG}"
fi
echo "==> tagged ${TAG}"

command -v gh >/dev/null || { echo "   (gh not available; skipping release)"; exit 0; }

gh release create "${TAG}" \
    --title "${_pkgbase} ${pkgver}-${pkgrel}" \
    --notes-file - \
    "${ASSETS[@]}" <<NOTES
Built from \`${_kernelsource}\` \`${_kernelref}\` (base \`${_base}\`).

Install from the pacman repo (see \`docs/REPO.md\`) rather than downloading these
files. They are attached as an archive that outlives the retention window in R2,
and as a fallback if the bucket is ever unreachable.

| input | ref |
|---|---|
| product | \`${_product}\` -> \`${_pkgbase}\` |
| kernel source | \`${_kernelsource}\` \`${_kernelref}\` |
| base kernel | \`${_srcname}\` |
| tarball sha256 | \`${_srcsha256}\` |
| OGC | ${OGC_LINE#OGC           } |
| armada | \`${_armadaref}\` |
| ROCKNIX | \`${_rocknixref}\` |
| series | \`${_series}\` -- ${_npatches} patches |
| config | \`${_configdirs}\` |
| dtbs | \`${_dtbs}\` |
| committed patches | ${NCOMMITTED} in \`patches/${_product}/\` + \`patches/shared/\` |
NOTES
echo "==> released ${TAG}"
