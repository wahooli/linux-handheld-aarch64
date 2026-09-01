#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkgver/pkgrel/_* all come from version.env
#
# Tag a successful publish and cut the matching GitHub release.
#
# Runs only after scripts/publish-r2.sh succeeds. A tag that exists but was
# never published would be the worst kind of provenance record: one that looks
# authoritative and is not.
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

# The tag prefix is per product, and it is not decoration: scripts/next-pkgrel.sh
# uses these tags as the floor that stops a published pkgrel being handed out
# twice. Two products sharing a prefix would let one product's tags raise the
# other's pkgrel -- harmless -- but a product whose prefix CHANGES loses its
# history and can reuse a live filename. Don't rename them.
TAG="${TAG_PREFIX}${pkgver}-${pkgrel}"
NCOMMITTED=0
[ -d "patches/${PRODUCT}" ] \
    && NCOMMITTED="$(find "patches/${PRODUCT}" -name '*.patch' | wc -l)"

# Only the inputs that actually contributed. Printing "OGC v7.2.1-ogc3" on a
# build that never fetched an OGC patch is the kind of provenance record that
# looks authoritative and is not.
if [ "${_useogc}" = yes ]; then OGC_LINE="OGC           ${_ogcref}"; else OGC_LINE="OGC           not used"; fi

# Refuse to tag a build with nothing published behind it -- and refuse BEFORE
# the tag exists. Pushing first and checking assets after is how a product that
# failed to build would get a phantom tag: one that burns a pkgrel through
# next-pkgrel.sh's tag floor and then blocks the re-run that could fix it.
#
# Only THIS product's files. out/ can hold every product's packages: the
# publish job merges all the build artifacts into one directory so the pacman
# database is written once, and a bare out/*.pkg.tar.zst would attach the other
# product's kernel to this product's release.
mapfile -t ASSETS < <(ls "out/${_pkgbase}"-*.pkg.tar.zst "out/${_pkgbase}"-*.pkg.tar.zst.sig 2>/dev/null)
[ ${#ASSETS[@]} -gt 0 ] || {
    echo "!! no out/${_pkgbase}-*.pkg.tar.zst -- nothing published for ${_product}, refusing to tag" >&2; exit 1; }

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "!! tag ${TAG} already exists -- refusing to move it" >&2
    exit 1
fi

git config user.name  "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

# The message carries the RESOLVED refs rather than whatever sources.env said at
# checkout time. armada is tracked by moving subtree HEAD, so without this there
# is no way to answer "which armada commit is on the kernel my device is
# running?" once retention has pruned the package.
git tag -a "${TAG}" -F - <<MSG
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

git push origin "${TAG}"
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
