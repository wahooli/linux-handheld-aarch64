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
cd "${HERE}"
# shellcheck source=/dev/null
source ./version.env

TAG="v${pkgver}-${pkgrel}"
NLOCAL="$(grep -cvE '^[[:space:]]*(#|$)' patches/local/series || true)"

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
linux-handheld-aarch64 ${pkgver}-${pkgrel}

base kernel   linux-${_base}
  sha256      ${_srcsha256}
OGC           ${_ogcref}
armada        ${_armadaref}
ROCKNIX       ${_rocknixref}
devices       ${_devices}
local patches ${NLOCAL}
MSG

git push origin "${TAG}"
echo "==> tagged ${TAG}"

command -v gh >/dev/null || { echo "   (gh not available; skipping release)"; exit 0; }

gh release create "${TAG}" \
    --title "linux-handheld-aarch64 ${pkgver}-${pkgrel}" \
    --notes-file - \
    out/*.pkg.tar.zst out/*.pkg.tar.zst.sig <<NOTES
Built from \`${_ogcref}\` on mainline \`${_base}\`.

Install from the pacman repo (see \`docs/REPO.md\`) rather than downloading these
files. They are attached as an archive that outlives the retention window in R2,
and as a fallback if the bucket is ever unreachable.

| input | ref |
|---|---|
| base kernel | \`linux-${_base}\` |
| tarball sha256 | \`${_srcsha256}\` |
| OGC | \`${_ogcref}\` |
| armada | \`${_armadaref}\` |
| ROCKNIX | \`${_rocknixref}\` |
| devices | \`${_devices}\` |
| local patches | ${NLOCAL} |
NOTES
echo "==> released ${TAG}"
