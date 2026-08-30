#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkgver/pkgrel/_* all come from version.env
#
# Decide this build's pkgrel and write it into version.env.
#
# pkgver encodes the upstream inputs that have version numbers (base kernel +
# OGC patchset revision). It does NOT encode the armada commit, and armada is
# tracked by moving subtree HEAD -- so a device-patch-only change produces a
# build with an identical pkgver. Without a distinct pkgrel that build is not an
# upgrade and pacman will not install it.
#
# So: pkgrel = 1 + the highest pkgrel already published for this exact pkgver.
# R2 is the source of truth rather than a counter in git, because R2 is what
# devices actually see; a counter file would drift the moment a publish failed
# after the commit.
#
# No R2 credentials (local build) -> pkgrel stays whatever version.env has.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

[ -f version.env ] || { echo "!! no version.env -- run scripts/fetch-patches.sh" >&2; exit 1; }
# shellcheck source=/dev/null
source ./version.env

REPO_NAME="${REPO_NAME:-handheld}"
ARCH_DIR="aarch64"

if [ -z "${R2_ACCOUNT_ID:-}" ] || [ -z "${R2_ACCESS_KEY_ID:-}" ] || ! command -v rclone >/dev/null; then
    echo "==> no R2 access; keeping pkgrel=${pkgrel}"
    exit 0
fi

export RCLONE_CONFIG=""
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_S3_NO_CHECK_BUCKET=true

# Only the kernel package is consulted. The headers package always ships in
# lockstep with it, so asking both could only disagree if a previous publish
# half-failed -- in which case the kernel package is the one devices resolve
# against and the one whose number must not be reused.
highest=0
while read -r f; do
    [ -n "${f}" ] || continue
    rel="$(sed -E "s/^linux-handheld-aarch64-${pkgver//./\\.}-([0-9]+)-aarch64\.pkg\.tar\.zst$/\1/" <<< "${f}")"
    [[ "${rel}" =~ ^[0-9]+$ ]] || continue
    [ "${rel}" -gt "${highest}" ] && highest="${rel}"
done < <(rclone lsf "R2:${R2_BUCKET}/${ARCH_DIR}" \
            --include "linux-handheld-aarch64-${pkgver}-*-aarch64.pkg.tar.zst" 2>/dev/null || true)

next=$((highest + 1))
sed -i "s/^pkgrel=.*/pkgrel=${next}/" version.env
if [ "${highest}" -eq 0 ]; then
    echo "==> pkgver ${pkgver} not yet published; pkgrel=${next}"
else
    echo "==> pkgver ${pkgver} published up to -${highest}; pkgrel=${next}"
fi

[ -n "${GITHUB_OUTPUT:-}" ] && {
    echo "pkgver=${pkgver}"
    echo "pkgrel=${next}"
    echo "tag=v${pkgver}-${next}"
} >> "${GITHUB_OUTPUT}"
exit 0
