#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkgver/pkgrel/_* all come from version.env
#
# Decide this build's pkgrel and write it into version.env.
#
#   pkgrel = 1 + the highest EVER used for this pkgbase-pkgver,
#            floored on both the R2 listing and the git tags.
#
# pkgver does not encode the armada commit, so a patch-only change rebuilds an
# identical pkgver; without a distinct pkgrel pacman sees no upgrade.
#
# The floor is "ever used" rather than "currently in R2" because packages are
# served immutable: reusing a filename leaves the edge serving the old bytes
# against the new signature, which on the device reads as a corrupted package and
# cannot be cleared there. An R2 listing cannot answer "ever used" -- pruning
# frees names whose cached URL may still be alive, and a failed listing is
# indistinguishable from an empty one.
#
# Tags are written only after a successful publish and are never pruned, so they
# are the durable record. CI must check out with fetch-tags: true.
#
# PKGREL_REQUIRE_R2 makes a missing credential or a failed listing an error.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-product.sh
source "${HERE}/scripts/lib-product.sh"
lp_load "${HERE}"

[ -f version.env ] || { echo "!! no version.env -- run scripts/fetch-patches.sh" >&2; exit 1; }
# shellcheck source=/dev/null
source ./version.env

[ "${_product}" = "${PRODUCT}" ] || {
    echo "!! version.env is for product '${_product}' but PRODUCT is '${PRODUCT}'" >&2
    echo "!! re-run scripts/fetch-patches.sh for this product" >&2
    exit 1
}

ARCH_DIR="aarch64"

# The workflow passes the string 'true' or 'false' -- a GitHub expression cannot
# cleanly produce an empty string -- so a plain -n test would read 'false' as
# "yes, require it".
case "${PKGREL_REQUIRE_R2:-}" in
    1|true|yes) REQUIRE_R2=1 ;;
    *)          REQUIRE_R2=  ;;
esac

# ---------------------------------------------------------------------------
# Floor 1: git tags. Works with no credentials and survives pruning.
# ---------------------------------------------------------------------------
highest_tag=0
n_tags=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while read -r t; do
        [ -n "${t}" ] || continue
        rel="${t##*-}"
        [[ "${rel}" =~ ^[0-9]+$ ]] || continue
        n_tags=$((n_tags + 1))
        [ "${rel}" -gt "${highest_tag}" ] && highest_tag="${rel}"
    done < <(git tag --list "${TAG_PREFIX}${pkgver}-*" 2>/dev/null || true)
    # A checkout with no tags is indistinguishable from "never published", which
    # is the case this floor exists to cover. Say so rather than pass it as
    # evidence.
    if [ "$(git tag --list | wc -l)" -eq 0 ]; then
        echo "==> note: this checkout has NO tags at all, so they contribute no floor."
        echo "    In CI that means actions/checkout ran without fetch-tags: true."
    fi
else
    echo "==> note: not a git checkout; tags contribute no floor"
fi

# ---------------------------------------------------------------------------
# Floor 2: what is in R2 right now
# ---------------------------------------------------------------------------
highest_r2=0
have_r2=

if [ -z "${R2_ACCOUNT_ID:-}" ] || [ -z "${R2_ACCESS_KEY_ID:-}" ] || ! command -v rclone >/dev/null; then
    if [ -n "${REQUIRE_R2}" ]; then
        echo "!! PKGREL_REQUIRE_R2 is set but R2 credentials or rclone are missing." >&2
        echo "!! Refusing to guess a pkgrel on the publishing path: a reused filename is" >&2
        echo "!! served immutable and cannot be fixed on the device." >&2
        exit 1
    fi
    echo "==> no R2 access; the floor is git tags only"
else
    export RCLONE_CONFIG=""
    export RCLONE_CONFIG_R2_TYPE=s3
    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
    export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
    export RCLONE_S3_NO_CHECK_BUCKET=true
    export RCLONE_RETRIES=2
    export RCLONE_LOW_LEVEL_RETRIES=2
    export RCLONE_CONTIMEOUT=15s
    export RCLONE_TIMEOUT=120s

    # Not `|| true`: an empty and a failed listing look identical afterwards, and
    # treating the second as the first is how a live filename gets reused. rclone
    # exits 0 with no output for an empty prefix, so the exit status is the only
    # thing that separates them.
    if ! listing="$(rclone lsf "R2:${R2_BUCKET}/${ARCH_DIR}" \
                        --include "${_pkgbase}-*-aarch64.pkg.tar.zst" 2>"${HERE}/.rclone-err")"; then
        sed 's/^/    /' "${HERE}/.rclone-err" >&2 || true
        rm -f "${HERE}/.rclone-err"
        echo "!! could not list R2 -- refusing to choose a pkgrel from an unknown state." >&2
        echo "!! (An unreadable bucket used to mean pkgrel=1, i.e. overwrite whatever" >&2
        echo "!!  is published. Fix the credentials or the network and re-run.)" >&2
        exit 1
    fi
    rm -f "${HERE}/.rclone-err"
    have_r2=1

    # Only this pkgbase's own packages, at this exact pkgver. The headers package
    # ships in lockstep and is not consulted; the kernel package is the one
    # devices resolve against.
    while read -r f; do
        [ -n "${f}" ] || continue
        rel="$(sed -E "s/^${_pkgbase}-${pkgver//./\\.}-([0-9]+)-aarch64\.pkg\.tar\.zst$/\1/" <<< "${f}")"
        [[ "${rel}" =~ ^[0-9]+$ ]] || continue
        [ "${rel}" -gt "${highest_r2}" ] && highest_r2="${rel}"
    done <<< "${listing}"
fi

# ---------------------------------------------------------------------------
# Is this pkgver even an upgrade?
# ---------------------------------------------------------------------------
# A base swap can move pkgver backwards in pacman's ordering while looking like
# progress: 7.2.1.ogc3 -> 7.2.1.cachy1 is a downgrade, because the trailing
# segment compares alphabetically and 'c' < 'o'. Nothing else in the pipeline
# would notice -- devices would just stop offering the update.
#
# vercmp is the only authority on that ordering, and it lives in pacman, which
# the runner does not have. So: the builder container when available, skipped
# with a note when not.
IMAGE="${IMAGE:-linux-handheld-builder:latest}"
vercmp_() {   # $1 $2 -> -1/0/1 on stdout, or nothing if unavailable
    if command -v vercmp >/dev/null 2>&1; then
        vercmp "$1" "$2"
    elif command -v docker >/dev/null 2>&1 && docker image inspect "${IMAGE}" >/dev/null 2>&1; then
        docker run --rm "${IMAGE}" vercmp "$1" "$2"
    fi
}

if [ -n "${have_r2}" ]; then
    newest_published=""
    while read -r f; do
        [ -n "${f}" ] || continue
        v="$(sed -E "s/^${_pkgbase}-(.+)-[0-9]+-aarch64\.pkg\.tar\.zst$/\1/" <<< "${f}")"
        [ "${v}" != "${f}" ] || continue
        if [ -z "${newest_published}" ]; then
            newest_published="${v}"
        else
            c="$(vercmp_ "${v}" "${newest_published}")"
            [ -n "${c}" ] || { newest_published=; break; }   # no vercmp: give up cleanly
            [ "${c}" -gt 0 ] && newest_published="${v}"
        fi
    done <<< "${listing}"

    if [ -n "${newest_published}" ]; then
        c="$(vercmp_ "${pkgver}" "${newest_published}")"
        if [ -z "${c}" ]; then
            echo "==> note: no vercmp available (no pacman, no builder image), so the"
            echo "    downgrade check was skipped. publish-r2.sh checks again."
        elif [ "${c}" -lt 0 ]; then
            echo "!! pkgver ${pkgver} is OLDER than the published ${newest_published}" >&2
            echo "!! by pacman's ordering, so devices would never offer it as an update." >&2
            echo "!! This is what a base swap looks like when the version tail changes:" >&2
            echo "!!   7.2.1.ogc3 -> 7.2.1.cachy1 sorts BACKWARDS ('c' < 'o')." >&2
            echo "!! Move the base forward, or add an epoch to the PKGBUILD." >&2
            exit 1
        fi
    fi
fi

# ---------------------------------------------------------------------------
highest="${highest_r2}"
[ "${highest_tag}" -gt "${highest}" ] && highest="${highest_tag}"
next=$((highest + 1))

sed -i "s/^pkgrel=.*/pkgrel=${next}/" version.env
# Prove the edit landed: a silently failed sed builds with the old pkgrel and
# publishes over an existing filename, which is the failure mode this file exists
# to prevent.
( source ./version.env; [ "${pkgrel}" = "${next}" ] ) \
    || { echo "!! version.env did not take pkgrel=${next}" >&2; exit 1; }

printf '==> %s %s: floor R2 -%s, tags -%s (%d tag(s) seen) -> pkgrel=%s\n' \
    "${_pkgbase}" "${pkgver}" "${highest_r2}" "${highest_tag}" "${n_tags}" "${next}"

[ -n "${GITHUB_OUTPUT:-}" ] && {
    echo "product=${PRODUCT}"
    echo "pkgbase=${_pkgbase}"
    echo "pkgver=${pkgver}"
    echo "pkgrel=${next}"
    echo "tag=${TAG_PREFIX}${pkgver}-${next}"
} >> "${GITHUB_OUTPUT}"
exit 0
