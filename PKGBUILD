# Maintainer: Waltteri Hooli <1420194+wahooli@users.noreply.github.com>
#
# One kernel product, packaged for Arch Linux ARM. Which product -- pkgbase,
# kernel source, config fragments, devices, patch stack -- is decided by
# products/<name>.conf; this file is the same for every product.
#
# Run scripts/fetch-patches.sh first. It writes the two files read here:
#
#   version.env              which product, which kernel, from where, checksum
#   patches/series.generated the single ordered list of patches to apply

# shellcheck source=/dev/null
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/version.env"

pkgbase="${_pkgbase}"
pkgname=("${_pkgbase}" "${_pkgbase}-headers")
# pkgver (base version + patchset revision) and pkgrel (build counter, set by CI
# from what is already in R2) come from version.env. vercmp orders these right:
#   7.2.1.ogc3 < 7.2.1.ogc4 < 7.2.1.ogc10 < 7.2.2.ogc1, and 7.2.ogc9 < 7.2.1.ogc1
pkgdesc="${_pkgdesc}"
arch=('aarch64')
url='https://github.com/wahooli/linux-handheld-aarch64'
license=('GPL-2.0-only')
# pahole is not optional: without it DEBUG_INFO_BTF -- and therefore
# SCHED_CLASS_EXT -- is silently dropped from .config at build time.
makedepends=('bc' 'cpio' 'gettext' 'kmod' 'libelf' 'pahole' 'perl' 'python'
             'tar' 'xz' 'zstd' 'dtc' 'bison' 'flex' 'openssl')
options=('!strip' '!debug')

source=("${_srcurl}")
sha256sums=("${_srcsha256}")

_srcdir="${_srcname}"

# Where the fetched-but-uncommitted inputs live. startdir rather than the source
# array because the patch set is only known at fetch time; the trade-off is that
# this PKGBUILD needs its sibling directories.
_repo() { printf '%s' "${startdir}"; }

prepare() {
    cd "${srcdir}/${_srcdir}"
    local repo; repo="$(_repo)"

    # ---- patch stack -------------------------------------------------------
    # Dry-run before applying, always: GNU patch can exit 0 after consuming only
    # the first hunk, and a half-applied patch fails later during compile,
    # pointing at nothing.
    #
    # Upstream and local failures are reported separately because the fix
    # differs: upstream means waiting for a rebase, local means doing it.
    local p f n=0 kind
    local -a failed_upstream=() failed_local=() already=()

    while read -r p; do
        p="${p%%#*}"; p="${p//[[:space:]]/}"
        [ -n "${p}" ] || continue
        f="${repo}/patches/${p}"
        [ -f "${f}" ] || { echo "::  missing patch: ${p} (run scripts/fetch-patches.sh)"; return 1; }

        # patches/<product>/ holds ours; anything else was fetched.
        case "${p}" in "${_product}"/*) kind=local ;; *) kind=upstream ;; esac

        # -F0 unless version.env's _fuzzallow lists this patch.
        local fuzz=0
        case " ${_fuzzallow} " in
            *" ${p} "*) fuzz=2 ;;
        esac

        if ! patch -p1 --batch --forward -F"${fuzz}" --dry-run --quiet < "${f}"; then
            # A patch that will not apply may already be in the tree. A reverse
            # dry-run tells that from "no longer applies", and only the second is
            # a failure. A partly applied patch fails both directions, so it is
            # reported as a failure -- which is correct.
            if patch -p1 -R --batch -F0 --dry-run --quiet < "${f}"; then
                echo "::  already in the base (${kind}), skipped: ${p}"
                already+=("${p}")
                continue
            fi
            echo "::  FAILED (${kind}): ${p}"
            [ "${kind}" = local ] && failed_local+=("${p}") || failed_upstream+=("${p}")
            continue
        fi
        if [ "${fuzz}" = 0 ]; then
            patch -p1 --batch --forward -F0 --no-backup-if-mismatch --quiet < "${f}"
        else
            # Not --quiet: fuzz and offset lines reach the build log, so an
            # upstream rebase that moves a hunk is visible.
            local out
            out="$(patch -p1 --batch --forward -F"${fuzz}" --no-backup-if-mismatch < "${f}")"
            echo "::  applied with fuzz ${fuzz} (allowed): ${p}"
            echo "${out}" | grep -E 'with fuzz|offset' | sed 's/^/::    /' || true
        fi
        n=$((n + 1))
    done < "${repo}/patches/series.generated"

    if [ ${#failed_upstream[@]} -gt 0 ] || [ ${#failed_local[@]} -gt 0 ]; then
        echo
        if [ ${#failed_upstream[@]} -gt 0 ]; then
            echo ":: ${#failed_upstream[@]} UPSTREAM patch(es) no longer apply to ${_base}:"
            printf '::    %s\n' "${failed_upstream[@]}"
            echo "::  This is the expected shape of a base bump. Either the source has"
            echo "::  not rebased onto ${_base} yet -- pin BASE_VERSION in sources.env"
            echo "::  and wait -- or the patch landed upstream and should be dropped"
            echo "::  from its series file."
        fi
        if [ ${#failed_local[@]} -gt 0 ]; then
            echo ":: ${#failed_local[@]} LOCAL patch(es) no longer apply to ${_base}:"
            printf '::    %s\n' "${failed_local[@]}"
            echo "::  Nobody upstream rebases these for you. Refresh them against"
            echo "::  ${_base} and update docs/PATCHES.md."
        fi
        return 1
    fi
    if [ ${#already[@]} -gt 0 ]; then
        echo "::  ${#already[@]} patch(es) were already in ${_srcname} -- see the lines above."
        echo "::  On a cachyos base that is expected for the OGC scheduler block. If it"
        echo "::  covers the whole selection, narrow patches/ogc.select or set USE_OGC=no."
    fi
    echo "::  applied ${n} patches to ${_srcname}, ${#already[@]} already present"

    # ---- device trees ------------------------------------------------------
    # Boards not in mainline: vendored verbatim plus a delta patch, so the copy
    # has to precede the delta. A board whose .dts is already in the tree appears
    # in DTB and not in DTS.
    local dts dtsbase
    # shellcheck source=/dev/null
    DTS=(); DTS_DELTA=(); DTB=(); source "${repo}/products/${_product}.conf"

    install -d arch/arm64/boot/dts/qcom
    for dts in "${DTS[@]}"; do
        install -Dm644 "${repo}/dts/${dts}" "arch/arm64/boot/dts/qcom/${dts}"
    done
    for dts in "${DTS_DELTA[@]}"; do
        patch -p1 -F0 --no-backup-if-mismatch -s < "${repo}/dts/${dts}"
    done
    # Register vendored boards so `make dtbs` builds them; the grep skips the
    # ones the Makefile already lists.
    for dts in "${DTS[@]}"; do
        [[ "${dts}" == *.dts ]] || continue     # .dtsi are included, not built
        dtsbase="${dts%.dts}"
        grep -q "${dtsbase}.dtb" arch/arm64/boot/dts/qcom/Makefile \
            || echo "dtb-\$(CONFIG_ARCH_QCOM) += ${dtsbase}.dtb" >> arch/arm64/boot/dts/qcom/Makefile
    done
    echo "::  ${#DTS[@]} vendored device tree source(s), ${#DTB[@]} dtb(s) to ship"

    # ---- config ------------------------------------------------------------
    # A base, then fragments in filename order: identity first, hardware
    # enablement next, Arch userland last so it wins any collision.
    #
    # _configbase is `defconfig` or a committed full .config -- the latter for a
    # product replacing a distro kernel, since arm64 defconfig is thousands of
    # symbols short of one. olddefconfig resolves the symbols an older full
    # config does not mention yet; syncconfig, which `make prepare` runs, does not.
    if [ "${_configbase}" = defconfig ]; then
        make ARCH=arm64 defconfig > /dev/null
    else
        [ -f "${repo}/${_configbase}" ] \
            || { echo "::  _configbase names ${_configbase}, which does not exist"; return 1; }
        install -Dm644 "${repo}/${_configbase}" .config
        make ARCH=arm64 olddefconfig > /dev/null
        echo "::  base config: ${_configbase} ($(grep -c '^CONFIG_' .config) symbols after olddefconfig)"
    fi
    # Fragments come from the product's _configdirs, sorted by BASENAME across all
    # of them so the numeric prefix keeps deciding merge order. Glob order would
    # merge all of common/ before all of handheld/ and silently invert it.
    local -a frags=()
    local cdir frag
    for cdir in ${_configdirs}; do
        [ -d "${repo}/config/${cdir}" ] \
            || { echo "::  _configdirs names config/${cdir}, which does not exist"; return 1; }
    done
    while read -r frag; do frags+=("${frag}"); done < <(
        for cdir in ${_configdirs}; do
            for frag in "${repo}/config/${cdir}"/*.config; do
                printf '%s\t%s\n' "$(basename "${frag}")" "${frag}"
            done
        done | LC_ALL=C sort -k1,1 | cut -f2-
    )
    [ ${#frags[@]} -gt 0 ] \
        || { echo "::  no config fragments for _configdirs='${_configdirs}'"; return 1; }
    echo "::  ${#frags[@]} config fragment(s) from: ${_configdirs}"
    ARCH=arm64 bash scripts/kconfig/merge_config.sh -m .config "${frags[@]}"
    make ARCH=arm64 olddefconfig > /dev/null

    # Verify every requested symbol survived: merge_config.sh warns about
    # overrides but exits 0, and a dropped CONFIG_DRM_MSM=y is a black screen you
    # debug on the device instead of in CI. Each form goes missing differently:
    #
    #   =y            must be y
    #   =m            m or y -- something else may `select` it builtin
    #   ="str", =num  exact match, or LOCALVERSION="-el2" can be overridden and
    #                 still report success
    #   is not set    must not be set to anything
    local missing=0 line key want
    while read -r line; do
        case "${line}" in
            '# CONFIG_'*' is not set')
                key="${line#\# }"; key="${key%% is not set}"
                ! grep -qE "^${key}=" .config \
                    || { echo "::  STILL SET: ${key}=$(grep -E "^${key}=" .config | cut -d= -f2-)"; missing=1; }
                continue ;;
        esac
        key="${line%%=*}"
        want="${line#*=}"
        case "${want}" in
            y) grep -qx "${key}=y" .config \
                   || { echo "::  NOT SET: ${line}"; missing=1; } ;;
            m) grep -qE "^${key}=(y|m)$" .config \
                   || { echo "::  NOT SET: ${line} (neither =m nor =y)"; missing=1; } ;;
            *) grep -qxF "${line}" .config \
                   || { echo "::  NOT SET: ${line} (is: $(grep -E "^${key}=" .config || echo 'absent'))"; missing=1; } ;;
        esac
    done < <(cat "${frags[@]}" | grep -E '^(CONFIG_[A-Z0-9_]+=.+|# CONFIG_[A-Z0-9_]+ is not set)$')
    [ "${missing}" = 0 ] || { echo "::  config fragments did not fully apply"; return 1; }

    # No `make kernelrelease > version` here: setlocalversion reads the
    # localversion out of include/config/auto.conf, which syncconfig only writes
    # during the build. Right now it would report a bare "7.2.1" while modules go
    # on to install under "7.2.1-handheld". The package functions read
    # include/config/kernel.release, generated by the build, instead.
    echo "::  configured $(grep -c '^CONFIG_' .config) symbols"
}

build() {
    cd "${srcdir}/${_srcdir}"
    # Explicit targets rather than `all`: on arm64 `all` resolves to KBUILD_IMAGE
    # and does not necessarily build the device trees.
    make ARCH=arm64 "${_kernelimage}" dtbs modules
}

_package() {
    pkgdesc="${_pkgdesc} -- ${_srcname}"
    # NOT depends=('initramfs'): the Odin 3 builds its storage stack in and never
    # installs mkinitcpio.
    #
    # The preset below is written regardless, but that alone does not get an
    # initramfs built: mkinitcpio's install hook triggers on
    # `usr/lib/modules/*/vmlinuz`, not on `pkgbase`, so a package keeping its
    # image only in /boot never fires it. INSTALL_VMLINUZ picks:
    #
    #   no  (default)  run `mkinitcpio -p <pkgbase>` by hand
    #   yes            also install the image as usr/lib/modules/<kver>/vmlinuz so
    #                  the hook fires, at ~30 MiB per package
    depends=('coreutils' 'kmod')
    optdepends=('linux-firmware: firmware for most devices'
                'mkinitcpio: to generate an initramfs from the shipped preset'
                'scx-scheds: sched_ext schedulers, incl. the latency-tuned scx_lavd')
    provides=('KSMBD-MODULE' 'VIRTUALBOX-GUEST-MODULES' 'WIREGUARD-MODULE')

    # Whether to displace ALARM's stock kernel. The two halves do different jobs:
    #
    #   conflicts  pacman refuses to co-install the stock kernel. Without it, two
    #              kernels end up installed and an installer picking a module tree
    #              with `ls -d /usr/lib/modules/*/` chooses alphabetically.
    #   provides   anything depending on linux-aarch64 resolves to us instead of
    #              erroring out on the conflict.
    #
    # _replacestock=no coexists instead, which only works because its image, dtb
    # directory and initramfs paths are all distinct.
    if [ "${_replacestock}" = yes ]; then
        provides+=("linux-aarch64=${pkgver}" "linux=${pkgver}")
        conflicts=('linux-aarch64')
    fi

    cd "${srcdir}/${_srcdir}"
    local repo; repo="$(_repo)"
    local kver; kver="$(<include/config/kernel.release)"

    # The Odin 3 boot chain wants an uncompressed Image at /boot/Image -- its
    # image builder gzips it itself and appends the DTBs. Products booting through
    # UEFI or another loader set KERNEL_IMAGE/KERNEL_IMAGE_DEST instead.
    install -Dm644 "arch/arm64/boot/${_kernelimage}" "${pkgdir}${_kernelimagedest}"

    # /dev/ntsync is a misc device with no autoload path, so as a module nothing
    # opens it on demand and Proton just sees no node. Keyed off the built config,
    # so NTSYNC=y never leaves a stale loader behind for a built-in.
    if grep -qx 'CONFIG_NTSYNC=m' .config; then
        install -Dm644 /dev/stdin \
            "${pkgdir}/usr/lib/modules-load.d/${pkgbase}-ntsync.conf" <<< "ntsync"
        echo "::  NTSYNC=m -- shipping modules-load.d drop-in"
    fi

    if [ "${_installvmlinuz}" = yes ]; then
        install -Dm644 "arch/arm64/boot/${_kernelimage}" \
            "${pkgdir}/usr/lib/modules/${kver}/vmlinuz"
    fi

    # From the product conf, not version.env: the conf is where the list is
    # edited, and this is the only consumer that needs the array form.
    local dtb
    # shellcheck source=/dev/null
    DTB=(); source "${repo}/products/${_product}.conf"
    for dtb in "${DTB[@]}"; do
        install -Dm644 "arch/arm64/boot/dts/qcom/${dtb}" "${pkgdir}${_dtbdest}/${dtb}"
    done

    # DEPMOD=/doesnt/exist skips depmod at package time -- pacman's hook runs it
    # on the device instead. The loud "requires /doesnt/exist" warning is expected.
    make ARCH=arm64 INSTALL_MOD_PATH="${pkgdir}/usr" INSTALL_MOD_STRIP=1 \
         DEPMOD=/doesnt/exist modules_install
    rm -f "${pkgdir}/usr/lib/modules/${kver}"/{source,build}

    # The PKGBASE, not the kernel version: Arch's mkinitcpio hooks read this to
    # find which /etc/mkinitcpio.d/<pkgbase>.preset belongs to a module tree. A
    # version here looks plausible and silently generates no initramfs.
    echo "${pkgbase}" > "${pkgdir}/usr/lib/modules/${kver}/pkgbase"

    # ---- mkinitcpio preset -------------------------------------------------
    # ALL_kver is the literal version rather than a path to the image, the way
    # Arch's presets do it: mkinitcpio can extract a version from an x86 bzImage,
    # but not from a bare arm64 `Image`.
    install -d "${pkgdir}/etc/mkinitcpio.d"
    cat > "${pkgdir}/etc/mkinitcpio.d/${pkgbase}.preset" <<PRESET
# mkinitcpio preset for ${pkgbase}, generated by the PKGBUILD.
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="${kver}"

PRESETS=('default' 'fallback')

default_image="${_initramfs}"

fallback_image="${_initramfsfallback}"
fallback_options="-S autodetect"
PRESET
}

_package-headers() {
    pkgdesc="Headers and scripts for building modules against ${pkgbase}"
    depends=('pahole')
    if [ "${_replacestock}" = yes ]; then
        provides=("linux-aarch64-headers=${pkgver}" "linux-headers=${pkgver}")
        conflicts=('linux-aarch64-headers')
    fi

    cd "${srcdir}/${_srcdir}"
    local kver; kver="$(<include/config/kernel.release)"
    local builddir="${pkgdir}/usr/lib/modules/${kver}/build"

    # Modelled on Arch's own linux PKGBUILD. Module.symvers is the easy one to
    # miss: without it modpost cannot resolve a single exported symbol and every
    # out-of-tree or DKMS module fails to link.
    install -Dt "${builddir}" -m644 .config Makefile Module.symvers System.map vmlinux
    install -Dm644 include/config/kernel.release "${builddir}/version"
    install -Dt "${builddir}/kernel" -m644 kernel/Makefile
    install -Dt "${builddir}/arch/arm64" -m644 arch/arm64/Makefile
    cp -t "${builddir}" -a scripts

    # vmlinux is most of the package's size and is deliberate: full DEBUG_INFO is
    # on for DEBUG_INFO_BTF (SCHED_CLASS_EXT depends on it), DEBUG_INFO_BTF_MODULES
    # then defaults y, and resolve_btfids needs vmlinux's BTF to link any
    # out-of-tree module. If size ever matters more, the knob is
    # CONFIG_DEBUG_INFO_BTF_MODULES=n in a fragment -- not deleting vmlinux here.
    #
    # objtool and resolve_btfids are build artefacts, copied rather than rebuilt
    # on the device.
    [ -f tools/objtool/objtool ] && install -Dt "${builddir}/tools/objtool" tools/objtool/objtool
    [ -f tools/bpf/resolve_btfids/resolve_btfids ] \
        && install -Dt "${builddir}/tools/bpf/resolve_btfids" tools/bpf/resolve_btfids/resolve_btfids

    cp -t "${builddir}" -a include
    cp -t "${builddir}/arch/arm64" -a arch/arm64/include
    install -Dt "${builddir}/arch/arm64/kernel" -m644 arch/arm64/kernel/asm-offsets.s

    # Headers that live outside include/ but that real modules include anyway.
    install -Dt "${builddir}/drivers/md" -m644 drivers/md/*.h
    install -Dt "${builddir}/net/mac80211" -m644 net/mac80211/*.h
    install -Dt "${builddir}/drivers/iio/common/hid-sensors" -m644 drivers/iio/common/hid-sensors/*.h

    # Every Kconfig, so `make menuconfig` works against the installed tree.
    find . -name 'Kconfig*' -exec install -Dm644 {} "${builddir}/{}" \;

    # Drop the other architectures -- a surprising amount of dead weight here.
    local arch
    for arch in "${builddir}"/arch/*/; do
        [[ "${arch}" == */arm64/ ]] && continue
        rm -r "${arch}"
    done

    # Remove dangling symlinks and build leftovers.
    find -L "${builddir}" -type l -delete
    find "${builddir}" -type f -name '*.o' -delete

    # options=('!strip') is set for the kernel package's sake, so the host
    # binaries in scripts/ and tools/ are stripped explicitly here.
    local file
    while read -rd '' file; do
        case "$(file -Sib "${file}")" in
            application/x-sharedlib\;*)      strip -v $STRIP_SHARED "${file}" ;;
            application/x-archive\;*)        strip -v $STRIP_STATIC "${file}" ;;
            application/x-executable\;*)     strip -v $STRIP_BINARIES "${file}" ;;
            application/x-pie-executable\;*) strip -v $STRIP_SHARED "${file}" ;;
        esac
    done < <(find "${builddir}" -type f -perm -u+x ! -name vmlinux -print0)
}

# ---- split-package glue -----------------------------------------------------
# makepkg dispatches to package_<pkgname>() by name, and pkgname is not known
# until version.env is read -- so the builders above are defined under fixed
# names and bound to the real ones here. ${_p#$pkgbase} is the suffix: empty for
# the kernel package, "-headers" for the other.
for _p in "${pkgname[@]}"; do
    eval "package_${_p}() {
        $(declare -f "_package${_p#$pkgbase}")
        _package${_p#$pkgbase}
    }"
done
unset -v _p
