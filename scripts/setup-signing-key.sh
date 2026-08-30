#!/usr/bin/env bash
#
# Generate the repo signing key and load it into GitHub Actions secrets.
#
#   scripts/setup-signing-key.sh                 generate + upload via gh
#   OUT_DIR=~/keys scripts/setup-signing-key.sh  also keep a backup copy there
#   NO_UPLOAD=1 scripts/setup-signing-key.sh     generate only, do not touch gh
#
# The private key is never printed. It goes from a throwaway keyring straight
# into `gh secret set` over stdin, and into a 0600 backup file if you asked for
# one. Only the fingerprint and the public key are ever shown -- a private key
# echoed to a terminal ends up in scrollback, shell history and any log that is
# capturing the session, and you cannot un-leak it afterwards.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

UID_NAME="${UID_NAME:-handheld repo}"
UID_EMAIL="${UID_EMAIL:-}"
OUT_DIR="${OUT_DIR:-}"
NO_UPLOAD="${NO_UPLOAD:-}"

[ -n "${UID_EMAIL}" ] || {
    echo "!! set UID_EMAIL to the address to put on the key, e.g." >&2
    echo "     UID_EMAIL=you@wahoo.li $0" >&2
    exit 1
}

# ── preflight ───────────────────────────────────────────────────────────────
# Everything that can fail is checked BEFORE a key exists. Discovering that gh
# cannot find the repository after generating means the key has to be thrown
# away and regenerated, which is exactly the situation this script exists to
# make safe.
command -v gpg >/dev/null || { echo "!! gpg not found" >&2; exit 1; }
if [ -z "${NO_UPLOAD}" ]; then
    command -v gh >/dev/null || { echo "!! gh not found (or set NO_UPLOAD=1)" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "!! gh is not authenticated -- run: gh auth login" >&2; exit 1; }
    if ! gh repo view >/dev/null 2>&1; then
        cat >&2 <<'MSG'
!! gh cannot work out which repository to target from here.
   `gh secret set` resolves the repo from the git remote, and there is none yet.

   Either point this checkout at the repo first:
       git remote add origin git@github.com:wahooli/linux-handheld-aarch64.git
   or generate the key now and add the secrets by hand:
       NO_UPLOAD=1 OUT_DIR=~/keys UID_EMAIL=... scripts/setup-signing-key.sh
MSG
        exit 1
    fi
fi

# Passphrase: generated, not chosen. It is only ever handled by scripts, so a
# memorable one buys nothing and a weak one costs real protection on a secret
# that lives in someone else's infrastructure.
PASS="$(gpg --gen-random --armor 1 24)"

W="$(mktemp -d)"; chmod 700 "${W}"
trap 'rm -rf "${W}"' EXIT
export GNUPGHOME="${W}/gnupg"; mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"

echo "==> generating ed25519 signing key for '${UID_NAME} <${UID_EMAIL}>'"
# ed25519, sign-only, no expiry: an expiring repo key means every device stops
# trusting updates on a date you will not remember, and rotation here is a
# deliberate act, not something to be forced into at an arbitrary moment.
gpg --batch --passphrase "${PASS}" \
    --quick-gen-key "${UID_NAME} <${UID_EMAIL}>" ed25519 sign never 2>/dev/null

FPR="$(gpg --batch --with-colons --list-keys | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "${FPR}" ] || { echo "!! key generation produced no key" >&2; exit 1; }
echo "    fingerprint  ${FPR}"

gpg --batch --yes --pinentry-mode loopback --passphrase "${PASS}" \
    --armor --export-secret-keys "${FPR}" > "${W}/private.asc"
gpg --batch --yes --armor --export "${FPR}" > "${W}/public.asc"
chmod 600 "${W}/private.asc"

# The backup is written BEFORE the upload, deliberately. The key exists only
# inside a temp directory that the exit trap removes; if the upload runs first
# and fails, `set -e` takes the script out before the backup and the key is gone
# for good. Persist it first, then push it.
if [ -n "${OUT_DIR}" ]; then
    mkdir -p "${OUT_DIR}"; chmod 700 "${OUT_DIR}"
    cp "${W}/private.asc" "${OUT_DIR}/handheld-repo-private.asc"
    cp "${W}/public.asc"  "${OUT_DIR}/handheld-repo-public.asc"
    printf '%s\n' "${PASS}" > "${OUT_DIR}/handheld-repo-passphrase.txt"
    chmod 600 "${OUT_DIR}"/handheld-repo-*
    echo "==> backup written to ${OUT_DIR}/ (mode 600)"
    echo "    handheld-repo-private.asc"
    echo "    handheld-repo-passphrase.txt"
fi

if [ -z "${NO_UPLOAD}" ]; then
    echo "==> uploading to GitHub Actions secrets"
    if gh secret set REPO_SIGNING_KEY < "${W}/private.asc" \
       && printf '%s' "${PASS}" | gh secret set REPO_SIGNING_KEY_PASSPHRASE; then
        echo "    REPO_SIGNING_KEY"
        echo "    REPO_SIGNING_KEY_PASSPHRASE"
    else
        # An upload failure must never cost the key. With a backup it is already
        # safe; without one, keep the temp directory alive and say where it is,
        # rather than letting the trap take it.
        if [ -n "${OUT_DIR}" ]; then
            echo "!! upload failed -- the key is safe in ${OUT_DIR}/, add the secrets by hand" >&2
        else
            KEEP="$(mktemp -d "${TMPDIR:-/tmp}/handheld-repo-key.XXXXXX")"
            chmod 700 "${KEEP}"
            cp "${W}/private.asc" "${W}/public.asc" "${KEEP}/"
            printf '%s\n' "${PASS}" > "${KEEP}/passphrase.txt"
            chmod 600 "${KEEP}"/*
            echo "!! upload failed. The key was NOT discarded -- it is in:" >&2
            echo "     ${KEEP}" >&2
            echo "   Move it somewhere safe, then add the secrets by hand." >&2
        fi
        exit 1
    fi
fi

echo
echo "──────────────────────────────────────────────"
echo " fingerprint : ${FPR}"
echo "──────────────────────────────────────────────"
if [ -z "${OUT_DIR}" ]; then
    cat <<'WARN'

 NO BACKUP WAS KEPT. The key now exists only in GitHub's secret store, which
 you cannot read back. Losing it means every device needs its keyring replaced
 by hand before it can take another update.

 Re-run with OUT_DIR=<somewhere-safe> if you want a copy, and put that copy in
 a password manager rather than leaving it on disk.
WARN
fi
