#!/usr/bin/env bash
#
# Install a pinned rclone into /usr/local/bin. Used by both CI jobs that talk to
# R2 -- the build job needs it for next-pkgrel.sh's listing, the publish job for
# the upload -- so the version and its checksum live in one place.
#
# Not from apt: Ubuntu 24.04 ships 1.60.1, from before much of the R2
# compatibility work. Not piped from install.sh either -- these jobs run with the
# signing key and R2 credentials in scope, so the tarball is checksum-verified.
set -euo pipefail

RCLONE_VER="${RCLONE_VER:-v1.75.0}"
RCLONE_SHA="${RCLONE_SHA:-d0ad88ba4c8e285b7c9efa591e0ab643280a91741e13c27f3a9c0957ccfa5203}"
ARCH="${RCLONE_ARCH:-linux-arm64}"

if command -v rclone >/dev/null && rclone version | head -1 | grep -q "${RCLONE_VER#v}"; then
    echo "==> rclone ${RCLONE_VER} already present"
    exit 0
fi

command -v unzip >/dev/null || { echo "!! unzip is required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
curl -fsSL --retry 3 -o "${tmp}/rclone.zip" \
    "https://github.com/rclone/rclone/releases/download/${RCLONE_VER}/rclone-${RCLONE_VER}-${ARCH}.zip"
echo "${RCLONE_SHA}  ${tmp}/rclone.zip" | sha256sum -c -
unzip -q -j "${tmp}/rclone.zip" '*/rclone' -d "${tmp}"
sudo install -m755 "${tmp}/rclone" /usr/local/bin/rclone
rclone version | head -1
