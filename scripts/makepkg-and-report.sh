#!/usr/bin/env bash
#
# Unprivileged half of the container build; runs as `build`, see scripts/build-in-container.sh.
set -euo pipefail
cd /work

# --nobuild stops after prepare(); the reports below read the prepared src/ tree.
args=(--noconfirm --syncdeps --cleanbuild --force)
[ -n "${NOBUILD:-}" ] && args+=(--nobuild)

# Zeroed: counters accumulate in the cache dir, so a cumulative rate hides a fully missed run.
command -v ccache >/dev/null && ccache -z >/dev/null 2>&1 || true

# pipefail keeps makepkg's exit status through tee.
makepkg "${args[@]}" 2>&1 | tee /work/.makepkg.log

# Near-0% hits on a warm cache: a new base version or a toolchain bump changed the keys.
if command -v ccache >/dev/null; then
    echo "==> ccache"
    ccache -s | sed 's/^/    /'
fi

{
    # ---- patches already in the base ------------------------------------
    if grep -q 'already in the base' /work/.makepkg.log; then
        echo
        echo "### Patches already in the base (skipped, not applied)"
        echo
        echo "These were in the tree before the series ran, so applying them would"
        echo "have been a no-op. On a \`cachyos\` base this is expected for the OGC"
        echo "scheduler block: CachyOS merges the same mailing-list series. If a"
        echo "whole selection shows up here, narrow it or turn it off -- carrying a"
        echo "patch that never applies only costs a rebase decision every bump."
        echo
        echo "| patch | kind |"
        echo "|---|---|"
        sed -n 's/^::  already in the base (\(.*\)), skipped: \(.*\)$/| `\2` | \1 |/p' \
            /work/.makepkg.log
    fi

    # ---- ROCKNIX staged dry-run ------------------------------------------
    # After the series and the vendored trees, so DTS-adding patches correctly report no.
    shopt -s nullglob
    staged=(patches/rocknix-staged/*.patch)
    if [ ${#staged[@]} -gt 0 ]; then
        echo
        echo "### ROCKNIX staged patches (not applied)"
        echo
        echo "Dry-run against the fully prepared tree — after the series *and* after the"
        echo "vendored device trees are copied in. A \"yes\" is a candidate for promotion"
        echo "into a device series, not a verdict; read docs/PATCHES.md before acting on one."
        echo
        echo "| patch | applies? |"
        echo "|---|---|"
        for f in "${staged[@]}"; do
            if ( cd "src/${SRCNAME}" && patch -p1 --batch --forward -F0 --dry-run --quiet < "/work/${f}" ) >/dev/null 2>&1; then
                echo "| \`$(basename "${f}")\` | yes |"
            else
                echo "| \`$(basename "${f}")\` | no |"
            fi
        done
    fi
} > /work/.staged-report.md
