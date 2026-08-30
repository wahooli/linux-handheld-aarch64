#!/usr/bin/env bash
#
# Open (or comment on) the build-failure issue. Deduped by title so a repeated
# failure adds a comment instead of a second issue.
#
# Needs GH_TOKEN. RUN_URL is optional and is just a link back to the logs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"
# shellcheck source=/dev/null
source ./sources.env

command -v gh >/dev/null || { echo "!! gh not available" >&2; exit 0; }

base="${BASE_VERSION:-derived from ${OGC_REF}}"
title="build failed: ${OGC_REF} / base ${base}"

body="$(cat <<BODY
${RUN_URL:-(no run url)}

| input | ref |
|---|---|
| OGC | \`${OGC_REF}\` |
| armada | \`${ARMADA_REF}\` |
| ROCKNIX | \`${ROCKNIX_REF}\` |
| base | \`${base}\` |
| devices | \`${DEVICES}\` |

R2 was not touched, so devices keep the last good kernel.

**If upstream patches stopped applying** this is a base bump the device stack has
not caught up with. armada rebases its stack onto new mainline releases on its own
schedule; pin \`BASE_VERSION\` in \`sources.env\` to hold the base still and let
the next poll pick armada up when it lands.

**If local patches failed** nobody upstream rebases those for you. Refresh them
against the new base and update the Local divergence section of
\`docs/PATCHES.md\`.

**If the OGC contiguity guard fired** a patch appeared inside the selected
scheduler block that matches no rule. Decide whether it belongs in
\`patches/ogc.select\` (we want it) or \`patches/ogc.select.deny\` (we looked and
said no) -- the guard exists so that choice is never made by silence.
BODY
)"

existing="$(gh issue list --state open --search "\"${title}\" in:title" \
              --json number,title \
              --jq ".[] | select(.title == \"${title}\") | .number" | head -1)"

if [ -n "${existing}" ]; then
    gh issue comment "${existing}" --body "${body}"
    echo "==> commented on issue #${existing}"
else
    gh issue create --title "${title}" --body "${body}" --label build-failure 2>/dev/null \
        || gh issue create --title "${title}" --body "${body}"
    echo "==> opened issue: ${title}"
fi
