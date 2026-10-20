# Maintainer: Waltteri Hooli <1420194+wahooli@users.noreply.github.com>
#
# Same for every product. Reads version.env + patches/series.generated from scripts/fetch-patches.sh.
# https://github.com/wahooli/linux-handheld-aarch64/wiki/Building-and-Publishing#pkgbuild-flow

# shellcheck source=/dev/null
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/version.env"

pkgbase="${_pkgbase}"
pkgname=("${_pkgbase}" "${_pkgbase}-headers")
pkgdesc="${_pkgdesc}"
arch=('aarch64')
url='https://github.com/wahooli/linux-handheld-aarch64'
license=('GPL-2.0-only')
# pahole is required: without it DEBUG_INFO_BTF, and with it SCHED_CLASS_EXT, silently drop out.
makedepends=('bc' 'cpio' 'gettext' 'kmod' 'libelf' 'pahole' 'perl' 'python'
             'tar' 'xz' 'zstd' 'dtc' 'bison' 'flex' 'openssl')
options=('!strip' '!debug')

source=("${_srcurl}")
sha256sums=("${_srcsha256}")

_srcdir="${_srcname}"

# Fetched inputs live beside the PKGBUILD: the patch set is only known at fetch time.
_repo() { printf '%s' "${startdir}"; }

prepare() {
    cd "${srcdir}/${_srcdir}"
    local repo; repo="$(_repo)"

    # ---- patch stack -------------------------------------------------------
    # Dry-run first: GNU patch can exit 0 after applying only the first hunk.
    local p f n=0 kind
    local -a failed_upstream=() failed_local=() already=()

    while read -r p; do
        p="${p%%#*}"; p="${p//[[:space:]]/}"
        [ -n "${p}" ] || continue
        f="${repo}/patches/${p}"
        [ -f "${f}" ] || { echo "::  missing patch: ${p} (run scripts/fetch-patches.sh)"; return 1; }

        # patches/<product>/ holds ours; anything else was fetched.
        case "${p}" in "${_product}"/*|shared/*) kind=local ;; *) kind=upstream ;; esac

        # -F0 unless version.env's _fuzzallow lists this patch.
        local fuzz=0
        case " ${_fuzzallow} " in
            *" ${p} "*) fuzz=2 ;;
        esac

        if ! patch -p1 --batch --forward -F"${fuzz}" --dry-run --quiet < "${f}"; then
            # Reverse dry-run: already in the tree is skipped; a partly applied patch fails both ways.
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
            # Not --quiet: fuzz and offset lines reach the log, so a moved hunk is visible.
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
    # Copy before the delta that patches it; boards already in the tree are only in DTB.
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
    # Register vendored boards with `make dtbs` unless the Makefile already lists them.
    for dts in "${DTS[@]}"; do
        [[ "${dts}" == *.dts ]] || continue     # .dtsi are included, not built
        dtsbase="${dts%.dts}"
        grep -q "${dtsbase}.dtb" arch/arm64/boot/dts/qcom/Makefile \
            || echo "dtb-\$(CONFIG_ARCH_QCOM) += ${dtsbase}.dtb" >> arch/arm64/boot/dts/qcom/Makefile
    done
    echo "::  ${#DTS[@]} vendored device tree source(s), ${#DTB[@]} dtb(s) to ship"

    # ---- config ------------------------------------------------------------
    # olddefconfig, not syncconfig: it resolves symbols an older full base config does not mention.
    if [ "${_configbase}" = defconfig ]; then
        make ARCH=arm64 defconfig > /dev/null
    else
        [ -f "${repo}/${_configbase}" ] \
            || { echo "::  _configbase names ${_configbase}, which does not exist"; return 1; }
        install -Dm644 "${repo}/${_configbase}" .config
        make ARCH=arm64 olddefconfig > /dev/null
        echo "::  base config: ${_configbase} ($(grep -c '^CONFIG_' .config) symbols after olddefconfig)"
    fi
    # Sort by basename across dirs so the numeric prefix, not the directory, decides order.
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

    # merge_config.sh only warns on overrides: check each symbol's last request survived.
    # =y exact, =m also accepts y (selected builtin), strings/numbers exact, 'is not set' must be absent.
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
    done < <(awk '
        /^CONFIG_[A-Z0-9_]+=.+$/ {
            key = $0; sub(/=.*/, "", key); requested[key] = $0
        }
        /^# CONFIG_[A-Z0-9_]+ is not set$/ {
            requested[$2] = $0
        }
        END { for (key in requested) print requested[key] }
    ' "${frags[@]}")
    [ "${missing}" = 0 ] || { echo "::  config fragments did not fully apply"; return 1; }

    # No `make kernelrelease` here: auto.conf is not written yet, so it would omit LOCALVERSION.
    echo "::  configured $(grep -c '^CONFIG_' .config) symbols"
}

build() {
    cd "${srcdir}/${_srcdir}"
    # Explicit targets: arm64 `all` resolves to KBUILD_IMAGE and may skip the dtbs.
    make ARCH=arm64 "${_kernelimage}" dtbs modules
}

_package() {
    pkgdesc="${_pkgdesc} -- ${_srcname}"
    # No depends=('initramfs'): the Odin 3 never installs mkinitcpio. Its install hook fires only on
    # usr/lib/modules/*/vmlinuz, hence INSTALL_VMLINUZ.
    depends=('coreutils' 'kmod')
    optdepends=('linux-firmware: firmware for most devices'
                'mkinitcpio: to generate an initramfs from the shipped preset'
                'scx-scheds: sched_ext schedulers, incl. the latency-tuned scx_lavd')
    provides=('KSMBD-MODULE' 'VIRTUALBOX-GUEST-MODULES' 'WIREGUARD-MODULE')

    # conflicts keeps the stock kernel out; provides lets its dependents resolve to this one.
    if [ "${_replacestock}" = yes ]; then
        provides+=("linux-aarch64=${pkgver}" "linux=${pkgver}")
        conflicts=('linux-aarch64')
    fi

    cd "${srcdir}/${_srcdir}"
    local repo; repo="$(_repo)"
    local kver; kver="$(<include/config/kernel.release)"

    install -Dm644 "arch/arm64/boot/${_kernelimage}" "${pkgdir}${_kernelimagedest}"

    # /dev/ntsync has no autoload path; keyed off the built config so =y leaves no stale loader.
    if grep -qx 'CONFIG_NTSYNC=m' .config; then
        install -Dm644 /dev/stdin \
            "${pkgdir}/usr/lib/modules-load.d/${pkgbase}-ntsync.conf" <<< "ntsync"
        echo "::  NTSYNC=m -- shipping modules-load.d drop-in"
    fi

    if [ "${_installvmlinuz}" = yes ]; then
        install -Dm644 "arch/arm64/boot/${_kernelimage}" \
            "${pkgdir}/usr/lib/modules/${kver}/vmlinuz"
    fi

    local dtb
    # shellcheck source=/dev/null
    DTB=(); source "${repo}/products/${_product}.conf"
    for dtb in "${DTB[@]}"; do
        install -Dm644 "arch/arm64/boot/dts/qcom/${dtb}" "${pkgdir}${_dtbdest}/${dtb}"
    done

    # DEPMOD=/doesnt/exist: pacman's hook runs depmod on the device; the warning is expected.
    make ARCH=arm64 INSTALL_MOD_PATH="${pkgdir}/usr" INSTALL_MOD_STRIP=1 \
         DEPMOD=/doesnt/exist modules_install
    rm -f "${pkgdir}/usr/lib/modules/${kver}"/{source,build}

    # The pkgbase, not the version: mkinitcpio's hooks map it to /etc/mkinitcpio.d/<pkgbase>.preset.
    echo "${pkgbase}" > "${pkgdir}/usr/lib/modules/${kver}/pkgbase"

    # ---- mkinitcpio preset -------------------------------------------------
    # Literal ALL_kver: mkinitcpio cannot read a version out of an arm64 Image.
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

    # Fires mkinitcpio's pacman hook (usr/lib/initcpio/*); named by kver so it cannot collide.
    install -Dm644 /dev/stdin "${pkgdir}/usr/lib/initcpio/${kver}" \
        <<< "dummy file to trigger mkinitcpio to run (${pkgbase})"
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

    # Modelled on Arch's linux PKGBUILD. Without Module.symvers no out-of-tree module links.
    install -Dt "${builddir}" -m644 .config Makefile Module.symvers System.map vmlinux
    install -Dm644 include/config/kernel.release "${builddir}/version"
    install -Dt "${builddir}/kernel" -m644 kernel/Makefile
    install -Dt "${builddir}/arch/arm64" -m644 arch/arm64/Makefile
    cp -t "${builddir}" -a scripts

    # vmlinux is deliberate: resolve_btfids needs its BTF for out-of-tree modules. To shrink,
    # set DEBUG_INFO_BTF_MODULES=n in a fragment rather than dropping vmlinux.
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

    local arch
    for arch in "${builddir}"/arch/*/; do
        [[ "${arch}" == */arm64/ ]] && continue
        rm -r "${arch}"
    done

    find -L "${builddir}" -type l -delete
    find "${builddir}" -type f -name '*.o' -delete

    # !strip is for the kernel package; strip the host tools here.
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
# package_<pkgname>() names are only known once version.env is read, so bind them here.
for _p in "${pkgname[@]}"; do
    eval "package_${_p}() {
        $(declare -f "_package${_p#$pkgbase}")
        _package${_p#$pkgbase}
    }"
done
unset -v _p
