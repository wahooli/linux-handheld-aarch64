#!/usr/bin/env bash
#
# Open, or comment on, the build-failure issue (deduped by title). Needs GH_TOKEN; RUN_URL optional.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-product.sh
source "${HERE}/scripts/lib-product.sh"
lp_load "${HERE}"

command -v gh >/dev/null || { echo "!! gh not available" >&2; exit 0; }

# Must work without version.env: a broken fetch is a likely reason to be here.
if [ -f version.env ]; then
    # shellcheck source=/dev/null
    source ./version.env
    base="${_srcname} (${_kernelsource} ${_kernelref})"
    base_short="${_srcname}"
    resolved="resolved"
else
    base="${KERNEL_SOURCE} ${KERNEL_REF:-unresolved}${BASE_VERSION:+ pinned to ${BASE_VERSION}}"
    base_short="${KERNEL_REF:-${KERNEL_SOURCE}}"
    resolved="requested; version.env was never written, so the failure is at or before fetch"
fi

# Precomputed: backticks in the unquoted heredoc below would need escaping.
if [ "${USE_OGC}" = yes ]; then ogc_cell="\`${OGC_REF}\`"; else ogc_cell="off for this product"; fi

# The advice depends on whether there is an upstream to wait for (armada) or only BORE.
if [ "${USE_ARMADA}" = yes ]; then
    UPSTREAM_ADVICE="**If upstream patches stopped applying** this is a base bump the device stack has
not caught up with. armada rebases its stack onto new mainline releases on its own
schedule; pin the base for THIS PRODUCT ONLY -- \`KERNEL_REF\` (or \`BASE_VERSION\`)
in \`products/${PRODUCT}.conf\` -- and let the next poll pick armada up when it
lands. The shared refs in \`sources.env\` are the wrong lever: holding them still
would freeze every other product too."
else
    UPSTREAM_ADVICE="**If a fetched patch stopped applying** the only fetched patch this product has
is the CachyOS scheduler patch, which is rebased against whichever tree CachyOS
was last on. Either pin \`CACHY_PATCHES_REF\` back, or set \`CACHY_SCHED=\` in
\`products/${PRODUCT}.conf\` to drop it -- everything else here is committed."
fi

# The product is in the title so two products' failures dedupe separately.
title="build failed: ${PRODUCT} / base ${base_short}"

body="$(cat <<BODY
${RUN_URL:-(no run url)}

| input | ref |
|---|---|
| product | \`${PRODUCT}\` -> \`${PKGBASE}\` |
| base | \`${base}\` (${resolved}) |
| armada | \`${ARMADA_REF}\` |
| ROCKNIX | \`${ROCKNIX_REF}\` |
| OGC | ${ogc_cell} |
| series | \`${SERIES}\` |
| boards | ${PRODUCT_BOARDS:-unnamed} |

R2 was not touched, so devices keep the last good kernel.

${UPSTREAM_ADVICE}

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
