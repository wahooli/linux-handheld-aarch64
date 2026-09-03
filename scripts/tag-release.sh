#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkgver/pkgrel/_* all come from version.env
#
# Tag a successful publish and cut the matching GitHub release.
#
# Runs only after scripts/publish-r2.sh succeeds: a tag with nothing published
# behind it is a provenance record that looks authoritative and is not.
#
# Needs GH_TOKEN and a git checkout with push rights.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-product.sh
source "${HERE}/scripts/lib-product.sh"
lp_load "${HERE}"
# shellcheck source=/dev/null
source ./version.env

[ "${_product}" = "${PRODUCT}" ] || {
    echo "!! version.env is for product '${_product}' but PRODUCT is '${PRODUCT}'" >&2; exit 1; }

# The tag prefix is per product and must not be renamed: next-pkgrel.sh uses
# these tags as the floor that stops a published pkgrel being handed out twice,
# so a product whose prefix changes loses its history and can reuse a live
# filename.
TAG="${TAG_PREFIX}${pkgver}-${pkgrel}"
NCOMMITTED=0
[ -d "patches/${PRODUCT}" ] \
    && NCOMMITTED="$(find "patches/${PRODUCT}" -name '*.patch' | wc -l)"

# Only the inputs that actually contributed: naming an OGC ref on a build that
# fetched no OGC patch would be a false provenance record.
if [ "${_useogc}" = yes ]; then OGC_LINE="OGC           ${_ogcref}"; else OGC_LINE="OGC           not used"; fi

# Checked before the tag exists: a phantom tag burns a pkgrel through
# next-pkgrel.sh's floor and then blocks the re-run that could fix it.
#
# Only this product's files -- the publish job merges every product's artifacts
# into one out/ so the pacman database is written once, and a bare
# out/*.pkg.tar.zst would attach the other product's kernel to this release.
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

# The resolved refs, not whatever sources.env said at checkout time: armada is
# tracked by moving subtree HEAD, so this is the only lasting answer to "which
# armada commit is on the kernel my device is running?"
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
committed     ${NCOMMITTED} patch(es) in patches/${_product}/
MSG
)"

# Created through the Git Data API rather than `git push origin "${TAG}"`:
# GitHub diffs a pushed tag ref against the default branch, so tagging a commit
# main has moved past reads as a workflow edit and is rejected for lacking the
# `workflows` permission -- which GITHUB_TOKEN cannot be granted. The API creates
# the identical annotated tag object against a commit that already exists
# server-side, so `contents: write` is enough.
#
# The git path stays for local runs, where the pusher has a PAT or an SSH key.
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
    # Bring the ref back rather than re-creating it locally, which would mint a
    # second tag object with a different timestamp.
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
| committed patches | ${NCOMMITTED} in \`patches/${_product}/\` |
NOTES
echo "==> released ${TAG}"
