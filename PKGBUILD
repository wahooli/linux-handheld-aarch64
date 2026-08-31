# Maintainer: Waltteri Hooli <1420194+wahooli@users.noreply.github.com>
#
# Mainline Linux + a handheld patch stack, packaged for Arch Linux ARM.
#
# Nothing here is self-contained on purpose. Run scripts/fetch-patches.sh first:
# it resolves the patch stack from the refs in sources.env and writes the two
# files this PKGBUILD reads.
#
#   version.env              which kernel, from where, with what checksum
#   patches/series.generated the single ordered list of patches to apply
#
# The old arch-arm64 package kept the kernel version in BASE.env *and* in the
# PKGBUILD's _srcver and asked humans to keep them in step. They drifted. There
# is now exactly one source of truth (sources.env -> version.env) and the
# PKGBUILD reads it.

# shellcheck source=/dev/null
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/version.env"

pkgbase=linux-handheld-aarch64
pkgname=('linux-handheld-aarch64' 'linux-handheld-aarch64-headers')
# pkgver / pkgrel come from version.env:
#   pkgver=7.2.1.ogc3   base version + OGC patchset revision
#   pkgrel              build counter, set by CI from what is already in R2
#
# vercmp orders this correctly across every transition we care about:
#   7.2.1.ogc3 < 7.2.1.ogc4 < 7.2.1.ogc10 < 7.2.2.ogc1
#   7.2.ogc9   < 7.2.1.ogc1
pkgdesc='Linux kernel for ARM handhelds (mainline + handheld patch stack)'
arch=('aarch64')
url='https://github.com/wahooli/linux-handheld-aarch64'
license=('GPL-2.0-only')
# pahole is not optional: DEBUG_INFO_BTF (and therefore SCHED_CLASS_EXT, which
# gamemode and the scx schedulers want) is silently dropped from .config if it
# is absent at build time.
makedepends=('bc' 'cpio' 'gettext' 'kmod' 'libelf' 'pahole' 'perl' 'python'
             'tar' 'xz' 'zstd' 'dtc' 'bison' 'flex' 'openssl')
options=('!strip' '!debug')

source=("${_srcurl}")
sha256sums=("${_srcsha256}")

_srcdir="${_srcname}"

# Where the fetched-but-uncommitted inputs live. startdir rather than the source
# array because the patch set is resolved at fetch time and cannot be enumerated
# statically here; the trade-off is that this PKGBUILD is not relocatable on its
# own -- it needs its sibling directories.
_repo() { printf '%s' "${startdir}"; }

prepare() {
    cd "${srcdir}/${_srcdir}"
    local repo; repo="$(_repo)"

    # ---- patch stack -------------------------------------------------------
    # Dry-run before applying, always. GNU patch can exit 0 after consuming only
    # the first hunk and calling the remainder "trailing garbage", so a
    # half-applied patch is a real failure mode and it is much worse than a
    # clean refusal -- it fails later, during compile, pointing at nothing.
    #
    # Local patches are reported separately from upstream ones because the fix
    # differs: an upstream patch that stopped applying means waiting for armada
    # or OGC to rebase, a local one means rebasing it yourself.
    local p f n=0 kind
    local -a failed_upstream=() failed_local=()

    while read -r p; do
        p="${p%%#*}"; p="${p//[[:space:]]/}"
        [ -n "${p}" ] || continue
        f="${repo}/patches/${p}"
        [ -f "${f}" ] || { echo "::  missing patch: ${p} (run scripts/fetch-patches.sh)"; return 1; }

        case "${p}" in local/*) kind=local ;; *) kind=upstream ;; esac

        if ! patch -p1 --batch --forward -F0 --dry-run --quiet < "${f}"; then
            echo "::  FAILED (${kind}): ${p}"
            [ "${kind}" = local ] && failed_local+=("${p}") || failed_upstream+=("${p}")
            continue
        fi
        patch -p1 --batch --forward -F0 --no-backup-if-mismatch --quiet < "${f}"
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
    echo "::  applied ${n} patches to ${_base}"

    # ---- device trees ------------------------------------------------------
    # Board DTS do not exist in mainline, so armada vendors them verbatim and
    # ships a delta patch alongside. They are copied in after the series rather
    # than being part of it, because the copy has to happen before the delta.
    local dev dts dtsbase
    install -d arch/arm64/boot/dts/qcom
    for dev in ${_devices}; do
        DTS=(); DTS_DELTA=(); DTB=()
        # shellcheck source=/dev/null
        source "${repo}/devices/${dev}.conf"

        for dts in "${DTS[@]}"; do
            install -Dm644 "${repo}/dts/${dts}" "arch/arm64/boot/dts/qcom/${dts}"
        done
        for dts in "${DTS_DELTA[@]}"; do
            patch -p1 -F0 --no-backup-if-mismatch -s < "${repo}/dts/${dts}"
        done
        # Register the boards so `make dtbs` builds them.
        for dts in "${DTS[@]}"; do
            [[ "${dts}" == *.dts ]] || continue     # .dtsi are included, not built
            dtsbase="${dts%.dts}"
            grep -q "${dtsbase}.dtb" arch/arm64/boot/dts/qcom/Makefile \
                || echo "dtb-\$(CONFIG_ARCH_QCOM) += ${dtsbase}.dtb" >> arch/arm64/boot/dts/qcom/Makefile
        done
        echo "::  ${dev}: ${#DTS[@]} device tree source(s), ${#DTB[@]} dtb(s)"
    done

    # ---- config ------------------------------------------------------------
    # defconfig, then fragments in filename order: identity first, hardware
    # enablement next, Arch userland last so it wins any collision.
    make ARCH=arm64 defconfig > /dev/null
    local frags=("${repo}"/config/*.config)
    ARCH=arm64 bash scripts/kconfig/merge_config.sh -m .config "${frags[@]}"
    make ARCH=arm64 olddefconfig > /dev/null

    # Verify every explicitly requested symbol actually survived.
    # merge_config.sh warns about overrides but exits 0, and a silently dropped
    # CONFIG_DRM_MSM=y is a black screen you debug on the device instead of in
    # CI. =m is checked as well as =y: an earlier version of this loop matched
    # only '=y', so every module request went unverified and a fragment full of
    # misspelled symbols could ship a handheld with no gamepad support and a
    # clean build log. A =m request is satisfied by =y too -- something else may
    # `select` it builtin, and "enabled, one way or the other" is the intent.
    local missing=0 sym key want
    while read -r sym; do
        key="${sym%%=*}"
        want="${sym#*=}"
        case "${want}" in
            y) grep -qx "${key}=y" .config \
                   || { echo "::  NOT SET: ${sym}"; missing=1; } ;;
            m) grep -qE "^${key}=(y|m)$" .config \
                   || { echo "::  NOT SET: ${sym} (neither =m nor =y)"; missing=1; } ;;
        esac
    done < <(cat "${frags[@]}" | grep -E '^CONFIG_[A-Z0-9_]+=(y|m)$')
    [ "${missing}" = 0 ] || { echo "::  config fragments did not fully apply"; return 1; }

    # NOT `make kernelrelease > version` here, which is what Arch's own linux
    # PKGBUILD does and what this package did until it started setting
    # CONFIG_LOCALVERSION. scripts/setlocalversion reads the localversion out of
    # include/config/auto.conf, and auto.conf does not exist yet -- olddefconfig
    # writes .config, but auto.conf is generated by syncconfig during the build.
    # So at this point kernelrelease silently reports a bare "7.2.1" while the
    # build will go on to install modules under "7.2.1-handheld", and every
    # package() step that trusted it would write to a path that does not exist.
    #
    # include/config/kernel.release is generated by the build and is the
    # authority; the package functions read it. Nothing is written here.
    echo "::  configured $(grep -c '^CONFIG_' .config) symbols"
}

build() {
    cd "${srcdir}/${_srcdir}"
    # Explicit targets rather than `all`: on arm64 `all` resolves to KBUILD_IMAGE
    # (Image.gz) and does not necessarily build the device trees, and the boot
    # chain here wants an uncompressed Image anyway.
    make ARCH=arm64 Image dtbs modules
}

package_linux-handheld-aarch64() {
    pkgdesc="The Linux kernel for ARM handhelds (mainline ${_base} + handheld patch stack)"
    # NOT depends=('initramfs'). Arch's own linux package requires it, but the
    # Odin 3 builds its storage stack in and never installs mkinitcpio; forcing
    # it would drag a generator onto a device that has nothing to generate. The
    # preset below is written regardless, so a profile that DOES want an
    # initramfs (qemu-virt, where virtio-blk may be modular) gets one by
    # installing mkinitcpio and nothing else.
    depends=('coreutils' 'kmod')
    optdepends=('linux-firmware: firmware for most devices'
                'mkinitcpio: to generate an initramfs from the shipped preset'
                'scx-scheds: sched_ext schedulers, incl. the latency-tuned scx_lavd')
    # `provides` + `conflicts` on linux-aarch64 is what actually keeps ALARM's
    # stock kernel out, and the two do different jobs:
    #
    #   conflicts  pacman refuses to co-install the stock kernel. Without it a
    #              `pacman -Syu` that pulls linux-aarch64 in as somebody's
    #              dependency leaves TWO kernels installed, and any installer
    #              that picks a module tree with `ls -d /usr/lib/modules/*/`
    #              then chooses alphabetically -- a coin flip.
    #   provides   anything that does depend on linux-aarch64 resolves to us
    #              instead of erroring out on the conflict.
    provides=('KSMBD-MODULE' 'VIRTUALBOX-GUEST-MODULES' 'WIREGUARD-MODULE'
              "linux-aarch64=${pkgver}" "linux=${pkgver}")
    conflicts=('linux-aarch64')

    cd "${srcdir}/${_srcdir}"
    local repo; repo="$(_repo)"
    local kver; kver="$(<include/config/kernel.release)"

    # The Odin 3 boot chain wants an UNCOMPRESSED Image at /boot/Image: the
    # image builder gzips it itself and appends the DTBs, because that is what
    # the ABL expects.
    install -Dm644 arch/arm64/boot/Image "${pkgdir}/boot/Image"

    local dev dtb
    for dev in ${_devices}; do
        DTB=()
        # shellcheck source=/dev/null
        source "${repo}/devices/${dev}.conf"
        for dtb in "${DTB[@]}"; do
            install -Dm644 "arch/arm64/boot/dts/qcom/${dtb}" "${pkgdir}/boot/dtb/qcom/${dtb}"
        done
    done

    # DEPMOD=/doesnt/exist skips running depmod at package time, which would
    # only produce modules.dep files for a module tree that is not installed
    # yet. Arch's own linux PKGBUILD does the same; pacman's depmod hook runs it
    # on the device at install time. It prints a loud
    #     Warning: 'make modules_install' requires /doesnt/exist
    # which is expected and not a problem.
    make ARCH=arm64 INSTALL_MOD_PATH="${pkgdir}/usr" INSTALL_MOD_STRIP=1 \
         DEPMOD=/doesnt/exist modules_install
    rm -f "${pkgdir}/usr/lib/modules/${kver}"/{source,build}

    # This file holds the PKGBASE, not the kernel version. It used to contain
    # ${kver}, which looks plausible and is wrong: Arch's mkinitcpio hooks read
    # it to work out which /etc/mkinitcpio.d/<pkgbase>.preset belongs to a
    # freshly installed module tree. With a version in there the lookup finds
    # nothing, no initramfs is generated, and an image build that needs one dies
    # much later with nothing pointing back here.
    echo "${pkgbase}" > "${pkgdir}/usr/lib/modules/${kver}/pkgbase"

    # ---- mkinitcpio preset -------------------------------------------------
    # ALL_kver is the literal version rather than a path to the image, which is
    # what Arch's own presets use (ALL_kver="/boot/vmlinuz-linux"). mkinitcpio
    # can extract a version from an x86 bzImage; asking it to do the same for a
    # bare arm64 `Image` is not something to depend on, and the exact version is
    # known here at package time anyway.
    install -d "${pkgdir}/etc/mkinitcpio.d"
    cat > "${pkgdir}/etc/mkinitcpio.d/${pkgbase}.preset" <<PRESET
# mkinitcpio preset for ${pkgbase}, generated by the PKGBUILD.
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="${kver}"

PRESETS=('default' 'fallback')

default_image="/boot/initramfs-${pkgbase}.img"

fallback_image="/boot/initramfs-${pkgbase}-fallback.img"
fallback_options="-S autodetect"
PRESET
}

package_linux-handheld-aarch64-headers() {
    pkgdesc="Headers and scripts for building modules against ${pkgbase}"
    depends=('pahole')
    provides=("linux-aarch64-headers=${pkgver}" "linux-headers=${pkgver}")
    conflicts=('linux-aarch64-headers')

    cd "${srcdir}/${_srcdir}"
    local kver; kver="$(<include/config/kernel.release)"
    local builddir="${pkgdir}/usr/lib/modules/${kver}/build"

    # Modelled on Arch's own linux PKGBUILD _package-headers(). The previous
    # arch-arm64 version installed Makefile/.config/scripts/include and stopped
    # there, which leaves out Module.symvers -- without it modpost cannot
    # resolve a single exported symbol and every out-of-tree or DKMS module
    # fails to link. Headers that cannot build a module are not headers.
    install -Dt "${builddir}" -m644 .config Makefile Module.symvers System.map vmlinux
    install -Dm644 include/config/kernel.release "${builddir}/version"
    install -Dt "${builddir}/kernel" -m644 kernel/Makefile
    install -Dt "${builddir}/arch/arm64" -m644 arch/arm64/Makefile
    cp -t "${builddir}" -a scripts

    # vmlinux is in that list on purpose and it is most of the package's size.
    # config/20-arch-userland.config turns on full (non-reduced) DEBUG_INFO to
    # get DEBUG_INFO_BTF, which SCHED_CLASS_EXT depends on; DEBUG_INFO_BTF_MODULES
    # then defaults y, and resolve_btfids needs vmlinux's BTF to link any
    # out-of-tree module. Drop vmlinux and DKMS builds fail at the BTF step.
    # Arch's own linux-headers ships it for the same reason.
    #
    # If the size ever matters more than module BTF, the knob is
    # CONFIG_DEBUG_INFO_BTF_MODULES=n in a fragment -- not deleting vmlinux here.
    #
    # objtool is needed when the kernel was built with stack validation, and
    # resolve_btfids when it was built with DEBUG_INFO_BTF_MODULES. Both are
    # built artefacts, so they are copied rather than rebuilt on the device.
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

    # Drop the other architectures: on a headers package for one arch they are
    # dead weight, and a surprising amount of it.
    local arch
    for arch in "${builddir}"/arch/*/; do
        [[ "${arch}" == */arm64/ ]] && continue
        rm -r "${arch}"
    done

    # Remove dangling symlinks and build leftovers.
    find -L "${builddir}" -type l -delete
    find "${builddir}" -type f -name '*.o' -delete

    # Strip the host binaries in scripts/ and tools/. options=('!strip') is set
    # for the kernel package's sake, so do it explicitly here.
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
