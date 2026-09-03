# syntax=docker/dockerfile:1
#
# Build environment for the kernel packages -- pacman, base-devel and the
# kernel's build dependencies.
#
# An Arch Linux ARM rootfs rather than a stock archlinux image, because the
# packages built here are installed on ALARM: a gcc/glibc skew between builder
# and target produces a module that loads everywhere except the device you care
# about. Native aarch64, so no qemu-user and no binfmt.

# ---- stage 1: fetch and slim the ALARM generic aarch64 rootfs ----------------
FROM alpine:3 AS fetch
ARG ALARM_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
RUN apk add --no-cache curl tar zstd

RUN mkdir -p /alarm \
 && curl --retry 3 --retry-delay 2 -fsSL "$ALARM_URL" -o /tmp/alarm.tar.gz \
 && tar -xpf /tmp/alarm.tar.gz -C /alarm \
 && rm /tmp/alarm.tar.gz \
 # The tarball is a full bootable system: a kernel plus linux-firmware, ~1.3 GB a
 # container that never boots cannot use. Must happen in the fetch stage -- a
 # `pacman -Rns` in the builder stage only adds a layer, and COPY --from would
 # still carry every byte.
 #
 # Nothing depends on them (both are only optional-for), and dropping the
 # matching /var/lib/pacman/local entries keeps the package database coherent.
 && rm -rf /alarm/usr/lib/firmware /alarm/boot/* /alarm/usr/lib/modules \
 && rm -rf /alarm/var/lib/pacman/local/linux-aarch64-* \
           /alarm/var/lib/pacman/local/linux-firmware-*

# ---- stage 2: the builder ---------------------------------------------------
FROM scratch
COPY --from=fetch /alarm/ /

# pacman 7 sandboxes downloads with Landlock and drops to an 'alpm' user, neither
# of which works under Docker's default seccomp profile ("restricting filesystem
# access failed ... Operation not permitted"). Safe to turn off here because this
# container is itself the sandbox: disposable, unprivileged, holding no secrets.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

# ALARM ships an expired-by-default keyring on old tarballs; initialise before
# the first sync or every package fails signature verification.
RUN pacman-key --init \
 && pacman-key --populate archlinuxarm \
 && pacman -Syu --noconfirm \
 && pacman -S --noconfirm --needed \
      base-devel ccache git rsync \
      bc cpio gettext kmod libelf pahole perl python tar xz zstd \
      dtc bison flex openssl inetutils \
 && pacman -Scc --noconfirm

# makepkg refuses to run as root, and building as root is a bad habit besides.
RUN useradd -m -s /bin/bash build \
 && echo 'build ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/build

# ccache turns a 40-minute rebuild into a 10-minute one when only the patch stack
# moved. The cache directory is bind-mounted in.
RUN sed -i 's/^BUILDENV=.*/BUILDENV=(!distcc color ccache check !sign)/' /etc/makepkg.conf \
 && sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf \
 && sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 -19 -)/' /etc/makepkg.conf \
 # ALARM still defaults PKGEXT to .pkg.tar.xz. zstd -19 compresses about as well
 # and decompresses several times faster, which is the half that happens on the
 # handheld. The publish scripts glob for .pkg.tar.zst.
 && sed -i "s/^PKGEXT=.*/PKGEXT='.pkg.tar.zst'/" /etc/makepkg.conf

USER build
WORKDIR /work
