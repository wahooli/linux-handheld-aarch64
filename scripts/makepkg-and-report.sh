#!/usr/bin/env bash
#
# The unprivileged half of the container build. Runs as `build` inside the
# builder image; see scripts/build-in-container.sh.
set -euo pipefail
cd /work

# --nobuild stops after prepare(), which is the cheap way to find out that an
# upstream moved: the series, the device trees and the config are all resolved,
# nothing is compiled. The reports below still work, because they read the
# prepared src/ tree rather than the packages.
args=(--noconfirm --syncdeps --cleanbuild --force)
[ -n "${NOBUILD:-}" ] && args+=(--nobuild)

# tee'd so the report below can quote the build rather than re-deriving anything
# from it. pipefail is on, so makepkg's exit status still fails this script.
makepkg "${args[@]}" 2>&1 | tee /work/.makepkg.log

{
    # ---- patches already in the base ------------------------------------
    # prepare() reverse-dry-runs anything that will not apply and reports
    # "already in the base" instead of failing. Lifted into the job summary
    # because it is the answer to whether the base already carries what we are
    # applying on top of it.
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
    # Against the fully prepared tree -- after the series AND after the vendored
    # device trees are copied in. That ordering is what makes it useful: the
    # DTS-add patches correctly report "no" because the files they add are
    # already there. Never applied; see docs/PATCHES.md.
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
