#!/usr/bin/env bash
#
# The unprivileged half of the container build. Runs as `build` inside the
# builder image; see scripts/build-in-container.sh.
set -euo pipefail
cd /work

makepkg --noconfirm --syncdeps --cleanbuild --force

# ---- ROCKNIX staged dry-run -------------------------------------------------
# Against the fully prepared tree -- after the patch series AND after the
# vendored device trees have been copied in. That ordering is what makes the
# answer useful: the DTS-add patches correctly report "no", because the files
# they add are already there, which is exactly the sense in which armada
# supersedes them. Run against pristine mainline they would all say "yes" and
# tell you nothing.
#
# Never applied. See docs/PATCHES.md.
{
    echo
    echo "### ROCKNIX staged patches (not applied)"
    echo
    echo "Dry-run against the fully prepared tree — after the series *and* after the"
    echo "vendored device trees are copied in. A \"yes\" is a candidate for promotion"
    echo "into a device series, not a verdict; read docs/PATCHES.md before acting on one."
    echo
    echo "| patch | applies? |"
    echo "|---|---|"
    shopt -s nullglob
    for f in patches/rocknix-staged/*.patch; do
        if ( cd "src/${SRCNAME}" && patch -p1 --batch --forward -F0 --dry-run --quiet < "/work/${f}" ) >/dev/null 2>&1; then
            echo "| \`$(basename "${f}")\` | yes |"
        else
            echo "| \`$(basename "${f}")\` | no |"
        fi
    done
} > /work/.staged-report.md
