#!/usr/bin/env bash
#
# Pinned, checksum-verified rclone for the CI jobs that talk to R2. Not apt (1.60.1 predates R2
# fixes), not a piped install.sh (these jobs hold the signing key and R2 credentials).
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
