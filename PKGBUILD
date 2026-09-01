# Maintainer: Waltteri Hooli <1420194+wahooli@users.noreply.github.com>
#
# One kernel PRODUCT, packaged for Arch Linux ARM. Which product -- pkgbase,
# kernel source, config fragments, devices, patch stack -- is decided by
# products/<name>.conf, not here; this file is the same for every product.
#
# Nothing here is self-contained on purpose. Run scripts/fetch-patches.sh first:
# it resolves the base and the patch stack from sources.env plus the product conf
# and writes the two files this PKGBUILD reads.
#
#   version.env              which product, which kernel, from where, checksum
#   patches/series.generated the single ordered list of patches to apply
#
# The old arch-arm64 package kept the kernel version in BASE.env *and* in the
# PKGBUILD's _srcver and asked humans to keep them in step. They drifted. There
# is now exactly one source of truth (sources.env -> version.env) and the
# PKGBUILD reads it.

# shellcheck source=/dev/null
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/version.env"

# From version.env, which got it from the product conf: every product builds from
# this one file.
pkgbase="${_pkgbase}"
pkgname=("${_pkgbase}" "${_pkgbase}-headers")
# pkgver / pkgrel come from version.env:
#   pkgver=7.2.1.ogc3   base version + OGC patchset revision
#   pkgrel              build counter, set by CI from what is already in R2
#
# vercmp orders this correctly across every transition we care about:
#   7.2.1.ogc3 < 7.2.1.ogc4 < 7.2.1.ogc10 < 7.2.2.ogc1
#   7.2.ogc9   < 7.2.1.ogc1
pkgdesc="${_pkgdesc}"
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
    local -a failed_upstream=() failed_local=() already=()

    while read -r p; do
        p="${p%%#*}"; p="${p//[[:space:]]/}"
        [ -n "${p}" ] || continue
        f="${repo}/patches/${p}"
        [ -f "${f}" ] || { echo "::  missing patch: ${p} (run scripts/fetch-patches.sh)"; return 1; }

        # Committed patches live in patches/<product>/ and are OURS: nobody
        # upstream rebases them, so they are reported separately and the advice
        # differs. Anything else was fetched.
        case "${p}" in "${_product}"/*) kind=local ;; *) kind=upstream ;; esac

        # -F0 for everything except the entries version.env names. See the
        # comment fetch-patches.sh writes next to _fuzzallow.
        local fuzz=0
        case " ${_fuzzallow} " in
            *" ${p} "*) fuzz=2 ;;
        esac

        if ! patch -p1 --batch --forward -F"${fuzz}" --dry-run --quiet < "${f}"; then
            # Three outcomes, not two: a patch that will not apply may already BE
            # in the tree. A reverse dry-run tells "already there" from "no longer
            # applies", and only the second is a failure. Reported and counted per
            # patch -- a patch that vanishes silently is how a kernel loses a fix.
            # One that is only PARTLY applied fails both directions and is
            # reported as a failure, which is correct.
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
            # Not --quiet: every hunk patch had to place by fuzz or offset is
            # printed, so an upstream rebase that moves it somewhere new shows up
            # in the build log instead of passing as "applied".
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
    # Board DTS that are not in mainline: armada vendors them verbatim plus a
    # delta patch. Copied in after the series, because the copy has to precede
    # the delta. Lists come from the product conf; a board whose .dts is already
    # in the tree appears in DTB and not in DTS.
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
    # Register the vendored boards so `make dtbs` builds them. Anything already
    # in the tree is already in this Makefile, which is what the grep guards.
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
    # _configbase is `defconfig` or a full .config committed in the repo. The
    # second is for a product replacing a distro kernel: arm64 defconfig is
    # thousands of symbols short of one, and olddefconfig is what resolves the
    # symbols a full config from an older kernel does not mention yet
    # (syncconfig, which `make prepare` would run, does not).
    if [ "${_configbase}" = defconfig ]; then
        make ARCH=arm64 defconfig > /dev/null
    else
        [ -f "${repo}/${_configbase}" ] \
            || { echo "::  _configbase names ${_configbase}, which does not exist"; return 1; }
        install -Dm644 "${repo}/${_configbase}" .config
        make ARCH=arm64 olddefconfig > /dev/null
        echo "::  base config: ${_configbase} ($(grep -c '^CONFIG_' .config) symbols after olddefconfig)"
    fi
    # Fragments come from the product's CONFIG_DIRS (via _configdirs), sorted by
    # BASENAME across all of them -- so the numeric prefix keeps deciding merge
    # order now that the files live in config/common/ and config/<product>/.
    #
    # Sorted explicitly rather than trusting the shell's glob order, which would
    # merge all of common/ before all of handheld/ and silently invert the
    # convention that 20-arch-userland gets the last word over 10-qcom-platform.
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

    # Verify every explicitly requested symbol actually survived.
    # merge_config.sh warns about overrides but exits 0, and a silently dropped
    # CONFIG_DRM_MSM=y is a black screen you debug on the device instead of in CI.
    #
    # Every FORM a fragment can request, because each one has its own way of
    # going missing:
    #
    #   =y            must be y
    #   =m            m or y -- something else may `select` it builtin, and
    #                 "enabled either way" is the intent
    #   ="str", =num  must match exactly. Not checking these is how an identity
    #                 fragment asking for LOCALVERSION="-el2" can be overridden
    #                 and still report success
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
    # and does not necessarily build the device trees. Which image target is the
    # product's choice (_kernelimage, default Image).
    make ARCH=arm64 "${_kernelimage}" dtbs modules
}

_package() {
    pkgdesc="${_pkgdesc} -- ${_srcname}"
    # NOT depends=('initramfs'). Arch's own linux package requires it, but the
    # Odin 3 builds its storage stack in and never installs mkinitcpio; forcing
    # it would drag a generator onto a device that has nothing to generate.
    #
    # The preset below is written regardless -- but writing it is NOT enough to
    # get an initramfs built automatically. mkinitcpio's install hook triggers on
    # `usr/lib/modules/*/vmlinuz` (see 90-mkinitcpio-install.hook), not on
    # `pkgbase`, so a package that keeps its image only in /boot never fires it.
    # ALARM's own linux-aarch64 does the same and its hook has never fired
    # either. Two ways out, and INSTALL_VMLINUZ picks:
    #
    #   no  (default)  run it by hand: `mkinitcpio -p <pkgbase>`. The preset is
    #                  what makes that one argument enough.
    #   yes            also install the image as usr/lib/modules/<kver>/vmlinuz,
    #                  the way Arch's linux package does, and the hook fires on
    #                  every install. Costs a second copy of the image -- 53 MiB
    #                  uncompressed for el2, roughly +30 MiB per package.
    depends=('coreutils' 'kmod')
    optdepends=('linux-firmware: firmware for most devices'
                'mkinitcpio: to generate an initramfs from the shipped preset'
                'scx-scheds: sched_ext schedulers, incl. the latency-tuned scx_lavd')
    provides=('KSMBD-MODULE' 'VIRTUALBOX-GUEST-MODULES' 'WIREGUARD-MODULE')

    # Whether to displace ALARM's stock kernel, and the two halves do different
    # jobs:
    #
    #   conflicts  pacman refuses to co-install the stock kernel. Without it a
    #              `pacman -Syu` that pulls linux-aarch64 in as somebody's
    #              dependency leaves TWO kernels installed, and any installer
    #              that picks a module tree with `ls -d /usr/lib/modules/*/`
    #              then chooses alphabetically -- a coin flip.
    #   provides   anything that does depend on linux-aarch64 resolves to us
    #              instead of erroring out on the conflict.
    #
    # A product with _replacestock=no coexists with it instead -- which only
    # works because its image, dtb directory and initramfs paths are all
    # distinct; pacman refuses the install on any shared file.
    if [ "${_replacestock}" = yes ]; then
        provides+=("linux-aarch64=${pkgver}" "linux=${pkgver}")
        conflicts=('linux-aarch64')
    fi

    cd "${srcdir}/${_srcdir}"
    local repo; repo="$(_repo)"
    local kver; kver="$(<include/config/kernel.release)"

    # Which image and where it lands are the product's choice. The Odin 3 boot
    # chain wants an UNCOMPRESSED Image at /boot/Image, because its image builder
    # gzips it itself and appends the DTBs; a product booting through UEFI or a
    # different loader sets KERNEL_IMAGE/KERNEL_IMAGE_DEST instead.
    install -Dm644 "arch/arm64/boot/${_kernelimage}" "${pkgdir}${_kernelimagedest}"

    # The hook's trigger path, when this product asked for it.
    if [ "${_installvmlinuz}" = yes ]; then
        install -Dm644 "arch/arm64/boot/${_kernelimage}" \
            "${pkgdir}/usr/lib/modules/${kver}/vmlinuz"
    fi

    # DTB comes from the product conf, not from version.env: version.env records
    # what was resolved, the conf is where the list is edited, and this is the
    # only consumer that needs the array form.
    local dtb
    # shellcheck source=/dev/null
    DTB=(); source "${repo}/products/${_product}.conf"
    for dtb in "${DTB[@]}"; do
        install -Dm644 "arch/arm64/boot/dts/qcom/${dtb}" "${pkgdir}${_dtbdest}/${dtb}"
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

# ---- split-package glue -----------------------------------------------------
# makepkg dispatches to package_<pkgname>() BY NAME, and pkgname is not known
# until version.env is read -- so the builders above are defined under fixed
# names (_package, _package-headers) and bound to the real ones here. Same idiom
# as Arch's own multi-flavour kernel PKGBUILDs.
#
# ${_p#$pkgbase} is the suffix: empty for the kernel package, "-headers" for the
# other, which is why the helpers are named for the suffix.
for _p in "${pkgname[@]}"; do
    eval "package_${_p}() {
        $(declare -f "_package${_p#$pkgbase}")
        _package${_p#$pkgbase}
    }"
done
unset -v _p
