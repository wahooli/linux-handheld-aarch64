#!/usr/bin/env bash
#
# Sign the built packages, fold them into the pacman repo database, and push the
# result to Cloudflare R2.
#
# Required environment:
#   R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
#   REPO_SIGNING_KEY            armored private key
#   REPO_SIGNING_KEY_PASSPHRASE
# Optional:
#   REPO_NAME (default: handheld)   pacman repo / database name
#   RETAIN    (default: 5)          versions kept per package name
#   DRY_RUN=1                       do everything except write to R2
#   CHECK_ONLY=1                    only prove the credentials work, then exit
#
# CHECK_ONLY exists because DRY_RUN touches no network, so without it the first
# thing to exercise the R2 token is a real publish at the end of a 40-minute
# build. Its write/read/delete round trip is the only way to tell a working token
# from one with the wrong permission level or scoped to another bucket.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# One pacman database serves every product: different pkgbase, no collisions.
# RETAIN is per package name, not per repository.
REPO_NAME="${REPO_NAME:-handheld}"
RETAIN="${RETAIN:-5}"
ARCH_DIR="aarch64"
DRY_RUN="${DRY_RUN:-}"

for v in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET; do
    [ -n "${!v:-}" ] || { echo "!! ${v} is not set" >&2; exit 1; }
done

command -v rclone >/dev/null || { echo "!! rclone not found" >&2; exit 1; }

# ── which repo-add ──────────────────────────────────────────────────────────
# Prefer the builder image's: its pacman is the one that built these packages.
# GitHub's Ubuntu runners ship pacman 6.0.2 against Arch's 7.1.0, old enough not
# to know --include-sigs -- and old repo-add treats an unknown option as the
# database filename rather than rejecting it. The container removes the whole
# class of version-skew bugs here.
#
# No signing happens in the container: repo-add runs without --sign and the key
# is never mounted. The database is signed afterwards, on the host.
IMAGE="${IMAGE:-linux-handheld-builder:latest}"
if command -v docker >/dev/null 2>&1 && docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    REPO_ADD_IN_CONTAINER=1
elif command -v repo-add >/dev/null; then
    REPO_ADD_IN_CONTAINER=
    if ! repo-add --help 2>&1 | grep -q -- '--include-sigs'; then
        echo "==> note: host $(repo-add --version 2>&1 | head -1) has no --include-sigs." >&2
        echo "    Signatures will not be embedded in the database, so clients fetch" >&2
        echo "    each .sig separately -- correct, just one extra request per install." >&2
    fi
else
    echo "!! neither the ${IMAGE} container nor a host repo-add is available" >&2
    exit 1
fi

CHECK_ONLY="${CHECK_ONLY:-}"
PKGS=(out/*.pkg.tar.zst)
if [ -z "${CHECK_ONLY}" ] && [ ! -e "${PKGS[0]}" ]; then
    echo "!! no packages in out/ -- run scripts/build.sh" >&2; exit 1
fi

# --------------------------------------------------------------------------
# rclone remote, configured entirely from env so nothing lands on disk
# --------------------------------------------------------------------------
export RCLONE_CONFIG=""                      # no config file at all
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_ACL=private
# no-check-bucket, set both ways on purpose. Without it rclone issues a
# CreateBucket call before every upload and R2 answers 501, so every object fails
# once and succeeds on the retry. The backend-wide RCLONE_S3_* form alone does
# not take on the rclone 1.60.1 Ubuntu 24.04 ships when the remote is defined
# entirely by env vars; the remote-scoped form is the one that binds.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_S3_NO_CHECK_BUCKET=true
export RCLONE_S3_UPLOAD_CUTOFF=5G
# Fail fast: rclone's defaults retry for minutes, which in CI reads as a hung
# publish rather than as a bad secret.
export RCLONE_RETRIES=2
export RCLONE_LOW_LEVEL_RETRIES=2
export RCLONE_CONTIMEOUT=15s
export RCLONE_TIMEOUT=120s

REMOTE="R2:${R2_BUCKET}/${ARCH_DIR}"
rclone_() { if [ -n "${DRY_RUN}" ]; then echo "   [dry-run] rclone $*"; else rclone "$@"; fi; }


if [ -n "${CHECK_ONLY}" ]; then
    echo "==> endpoint  https://${R2_ACCOUNT_ID:0:6}...${R2_ACCOUNT_ID: -4}.r2.cloudflarestorage.com"
    echo "==> bucket    ${R2_BUCKET}"
    T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
    echo "handheld repo access check" > "${T}/probe"
    P=".r2-access-check"
    rclone lsf "R2:${R2_BUCKET}" --max-depth 1 >/dev/null 2>"${T}/e" \
        || { sed 's/^/    /' "${T}/e" >&2; echo "!! cannot list ${R2_BUCKET} -- wrong bucket, wrong account id, or the token is not scoped to it" >&2; exit 1; }
    echo "  ok  list"
    rclone copyto "${T}/probe" "R2:${R2_BUCKET}/${P}" 2>"${T}/e" \
        || { sed 's/^/    /' "${T}/e" >&2; echo "!! cannot write -- the token is probably 'Object Read only'; it needs 'Object Read & Write'" >&2; exit 1; }
    echo "  ok  write"
    rclone cat "R2:${R2_BUCKET}/${P}" 2>/dev/null | diff -q - "${T}/probe" >/dev/null \
        || { echo "!! wrote the probe but could not read it back identically" >&2; exit 1; }
    echo "  ok  read back"
    rclone deletefile "R2:${R2_BUCKET}/${P}" 2>"${T}/e" \
        || { sed 's/^/    /' "${T}/e" >&2; echo "!! cannot delete -- publishing would work but retention pruning would not" >&2; exit 1; }
    echo "  ok  delete  (needed by retention pruning)"
    echo
    echo "credentials are good"
    exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"; [ -n "${GNUPGHOME:-}" ] && rm -rf "${GNUPGHOME}"' EXIT

# --------------------------------------------------------------------------
# 1. Signing key, in a throwaway keyring
# --------------------------------------------------------------------------
export GNUPGHOME="${WORK}/gnupg"; mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
[ -n "${REPO_SIGNING_KEY:-}" ] || { echo "!! REPO_SIGNING_KEY is not set" >&2; exit 1; }
printf '%s' "${REPO_SIGNING_KEY}" | gpg --batch --quiet --import
GPGKEY="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "${GPGKEY}" ] || { echo "!! no secret key after import" >&2; exit 1; }
echo "==> signing as ${GPGKEY}"

gpg_sign() {   # $1 = file to detach-sign
    gpg --batch --yes --quiet --pinentry-mode loopback \
        --passphrase "${REPO_SIGNING_KEY_PASSPHRASE:-}" \
        --local-user "${GPGKEY}" --detach-sign --no-armor "$1"
}

for p in "${PKGS[@]}"; do
    [ -f "${p}.sig" ] || gpg_sign "${p}"
done

# The bootstrap key, published at the bucket root so a device with no keyring can
# `pacman-key --add` it over https before trusting anything.
gpg --batch --yes --export --output "${WORK}/${REPO_NAME}.gpg" "${GPGKEY}"

# --------------------------------------------------------------------------
# 2. Refuse to overwrite a filename that is already published
# --------------------------------------------------------------------------
# Objects are served `Cache-Control: immutable`, so a filename promises its bytes
# never change. Overwrite one and the edge keeps serving the previous build while
# the database (max-age=60) already carries the new sha256; the device reports
# "invalid or corrupted package (PGP signature)" and cannot clear it.
#
# next-pkgrel.sh is the primary defence; this is the backstop for the paths that
# bypass it (a hand-written version.env, a pinned pkgrel).
#
# Identical bytes pass, so re-running a half-failed publish stays idempotent.
# Hashes come from one rclone listing rather than a HEAD per package: R2 returns
# the md5 as the etag for single-part uploads, which is what this makes
# (UPLOAD_CUTOFF=5G).
if [ -z "${DRY_RUN}" ]; then
    echo "==> checking that no published filename is being overwritten"
    declare -A REMOTE_MD5=()
    if ! _listing="$(rclone lsf "${REMOTE}" --include '*.pkg.tar.zst' \
                        --hash MD5 --format ph --separator '|' 2>&1)"; then
        while IFS= read -r _l; do printf '    %s\n' "${_l}"; done <<< "${_listing}" >&2
        echo "!! could not list ${REMOTE}; refusing to publish blind" >&2
        exit 1
    fi
    while IFS='|' read -r rname rhash; do
        [ -n "${rname}" ] && REMOTE_MD5["${rname}"]="${rhash}"
    done <<< "${_listing}"

    clash=()
    for p in "${PKGS[@]}"; do
        b="$(basename "${p}")"
        [ -n "${REMOTE_MD5[${b}]+x}" ] || continue          # not published yet
        local_md5="$(md5sum "${p}" | cut -d' ' -f1)"
        # An empty remote hash means the object exists but R2 gave no md5 (a
        # multipart upload from another tool). Unknown is not "the same".
        [ -n "${REMOTE_MD5[${b}]}" ] && [ "${REMOTE_MD5[${b}]}" = "${local_md5}" ] && {
            echo "    ${b} is already published, byte-identical -- fine"
            continue
        }
        clash+=("${b}")
    done

    if [ ${#clash[@]} -gt 0 ]; then
        cat >&2 <<EOM
!!
!! These filenames are ALREADY PUBLISHED with different bytes:
$(printf '!!   %s\n' "${clash[@]}")
!!
!! Publishing them would overwrite objects served as immutable, so devices would
!! keep getting the old bytes with the new signature -- which reads as
!! "signature is invalid / package is corrupted" and cannot be fixed on the
!! device.
!!
!! Bump pkgrel and rebuild: new bytes need a new filename, and a new filename is
!! the only thing that invalidates the edge. scripts/next-pkgrel.sh does that
!! automatically when it can see R2 and the git tags; if it ran without either,
!! that is the actual bug to fix.
EOM
        exit 1
    fi
    echo "    ok -- nothing published is being rewritten"
else
    echo "==> [dry-run] skipping the already-published check (needs the network)"
fi

# --------------------------------------------------------------------------
# 3. Pull the current database, fold the new packages in
# --------------------------------------------------------------------------
DB="${WORK}/db"; mkdir -p "${DB}"
# A dry run must not need the network: it checks the signing and database logic,
# and reaching for a bucket it will not write to only turns a bad credential into
# a slow, confusing failure.
if [ -z "${DRY_RUN}" ]; then
    echo "==> fetching current ${REPO_NAME} database"
    rclone copy "${REMOTE}" "${DB}" \
        --include "${REPO_NAME}.db*" --include "${REPO_NAME}.files*" 2>/dev/null || true
    ls -1 "${DB}" 2>/dev/null | sed 's/^/    have /' || echo "    (empty -- first publish)"
else
    echo "==> [dry-run] not fetching the remote database"
fi

cp "${PKGS[@]}" "${DB}/"
for p in "${PKGS[@]}"; do cp "${p}.sig" "${DB}/"; done

( cd "${DB}"
  # --include-sigs embeds each package's signature in the database, so a client
  # on SigLevel=Required does not fetch a separate .sig per package.
  #
  # No --remove: it deletes superseded package files from disk, which here is a
  # temp directory holding only the new ones. Retention is handled against R2
  # further down.
  #
  # No --sign either, and that one is not cosmetic: repo-add shells out to gpg
  # without loopback pinentry, so a passphrase-protected key gets a warning and
  # exit 0 -- shipping an UNSIGNED database that DatabaseOptional clients accept
  # without complaint. Signed below instead, via the working loopback path.
  if [ -n "${REPO_ADD_IN_CONTAINER}" ]; then
      docker run --rm -v "${DB}:/db" -w /db \
          --user "$(id -u):$(id -g)" -e HOME=/tmp \
          "${IMAGE}" repo-add --quiet --include-sigs "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst
  else
      inc=(); repo-add --help 2>&1 | grep -q -- '--include-sigs' && inc=(--include-sigs)
      repo-add --quiet "${inc[@]}" "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst
  fi

  # repo-add leaves <repo>.db and <repo>.files as symlinks to the .tar.gz files,
  # and those are the names pacman fetches. rclone skips symlinks, so materialise
  # them or the upload silently omits the database a device asks for by name.
  for n in db files; do
      if [ -L "${REPO_NAME}.${n}" ]; then
          rm -f "${REPO_NAME}.${n}"
          cp "${REPO_NAME}.${n}.tar.gz" "${REPO_NAME}.${n}"
      fi
  done
) < /dev/null

for n in db db.tar.gz files files.tar.gz; do
    [ -f "${DB}/${REPO_NAME}.${n}" ] || continue
    rm -f "${DB}/${REPO_NAME}.${n}.sig"
    gpg_sign "${DB}/${REPO_NAME}.${n}"
done
echo "==> database signed"

# --------------------------------------------------------------------------
# 4. Upload -- ORDER MATTERS
# --------------------------------------------------------------------------
# Packages first, database last: a `pacman -Sy` mid-publish must never get a
# database referencing a package that is not there yet. The reverse -- a package
# nothing points at -- is harmless.
#
# Cache headers matter because a custom domain puts Cloudflare's edge in front of
# this. Package filenames never change, so they cache forever; the database
# changes every publish and must not, or devices get a stale index.
echo "==> uploading packages"
for p in "${PKGS[@]}"; do
    b="$(basename "${p}")"
    rclone_ copyto "${p}"      "${REMOTE}/${b}"     --header-upload "Cache-Control: public, max-age=31536000, immutable"
    rclone_ copyto "${p}.sig"  "${REMOTE}/${b}.sig" --header-upload "Cache-Control: public, max-age=31536000, immutable"
    echo "    ${b}"
done

echo "==> uploading database"
for f in "${DB}/${REPO_NAME}".{db,files}{,.tar.gz}{,.sig}; do
    [ -f "${f}" ] || continue
    rclone_ copyto "${f}" "${REMOTE}/$(basename "${f}")" \
        --header-upload "Cache-Control: public, max-age=60, must-revalidate"
    echo "    $(basename "${f}")"
done

rclone_ copyto "${WORK}/${REPO_NAME}.gpg" "R2:${R2_BUCKET}/${REPO_NAME}.gpg" \
    --header-upload "Cache-Control: public, max-age=300"

# --------------------------------------------------------------------------
# 5. Prune -- last, and never below what the database references
# --------------------------------------------------------------------------
# Keep the newest RETAIN versions per package name so a bad kernel can be rolled
# back with `pacman -U <url>`. After the database is live, so a client mid-sync
# never loses a file the index still points at.
#
# repo-add keeps only the newest version of each name in the database, so
# retained packages are direct-URL rollback targets only -- which is why RETAIN
# below 2 leaves nothing to roll back to.
#
# Deleting an object does not free its name: the URL was served immutable, so the
# edge can still answer for it. A pruned pkgrel must never be reissued, hence
# next-pkgrel.sh floors on git tags rather than on this listing.

# Sort pacman versions oldest-first.
vercmp_sort() {
    local -a a=(); mapfile -t a
    [ ${#a[@]} -gt 0 ] || return 0

    # In the container when available, for the same reason repo-add is: version
    # comparison differs quietly between pacman 6.0.2 and 7.1.0, and this decides
    # what gets deleted. One invocation for the whole sort -- the insertion sort
    # is O(n^2), so a docker call per comparison would take a minute.
    if [ -n "${REPO_ADD_IN_CONTAINER}" ]; then
        printf '%s\n' "${a[@]}" | docker run --rm -i "${IMAGE}" bash -c "$(_vercmp_sort_body)"
    else
        printf '%s\n' "${a[@]}" | bash -c "$(_vercmp_sort_body)"
    fi
}

# The sort itself, as a string so it runs here or in the container unchanged.
#
# `sort -V` is not a substitute for vercmp: it places 7.2.ogc9 after 7.2.1.ogc10,
# while pacman considers 7.2.ogc9 the older -- so it would delete the newest
# package the first time the base moved. (pacsort would do this in one call, but
# pacman 7.x no longer ships it.) n is a handful of versions, so insertion sort
# with a subprocess per comparison is still instant.
_vercmp_sort_body() {
cat <<'BODY'
set -euo pipefail
mapfile -t a
[ ${#a[@]} -gt 0 ] || exit 0
for ((i = 1; i < ${#a[@]}; i++)); do
    x="${a[i]}"
    for ((j = i - 1; j >= 0; j--)); do
        [ "$(vercmp "${a[j]}" "${x}")" -gt 0 ] || break
        a[j+1]="${a[j]}"
    done
    a[j+1]="${x}"
done
printf '%s\n' "${a[@]}"
BODY
}

echo "==> pruning to the newest ${RETAIN} version(s) per package"
if [ -n "${DRY_RUN}" ]; then
    # Nothing was uploaded, so pretend the remote holds exactly what was just
    # built: the grouping and vercmp sort still get exercised.
    mapfile -t REMOTE_PKGS < <(for p in "${PKGS[@]}"; do basename "${p}"; done | sort)
else
    mapfile -t REMOTE_PKGS < <(rclone lsf "${REMOTE}" --include '*.pkg.tar.zst' 2>/dev/null | sort)
fi
declare -A KEEP=()
for p in "${PKGS[@]}"; do KEEP["$(basename "${p}")"]=1; done

# Group by package name: strip the trailing -<pkgver>-<pkgrel>-<arch>.pkg.tar.zst
declare -A BYNAME=()
for f in "${REMOTE_PKGS[@]}"; do
    name="$(sed -E 's/-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst$//' <<< "${f}")"
    BYNAME["${name}"]+="${f}"$'\n'
done

for name in "${!BYNAME[@]}"; do
    mapfile -t versions < <(printf '%s' "${BYNAME[$name]}" | grep -v '^$' \
        | sed -E "s/^${name}-//; s/-aarch64\.pkg\.tar\.zst$//" | vercmp_sort)
    total=${#versions[@]}
    [ "${total}" -gt "${RETAIN}" ] || { echo "    ${name}: ${total} version(s), nothing to prune"; continue; }
    drop=$((total - RETAIN))
    for v in "${versions[@]:0:${drop}}"; do
        f="${name}-${v}-aarch64.pkg.tar.zst"
        [ -n "${KEEP[${f}]:-}" ] && { echo "    ${name}: refusing to prune the build we just published (${v})"; continue; }
        echo "    prune ${f}"
        rclone_ deletefile "${REMOTE}/${f}"      2>/dev/null || true
        rclone_ deletefile "${REMOTE}/${f}.sig"  2>/dev/null || true
    done
done

echo
echo "published ${#PKGS[@]} package(s) to ${REMOTE}"
