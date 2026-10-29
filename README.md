# linux-handheld-aarch64

Kernel packages for **Arch Linux ARM (aarch64)**, published as a signed pacman
repository on Cloudflare R2. Every build produces `<pkgbase>` and
`<pkgbase>-headers`.

No fetched patch content is committed here: the repository holds the manifests
(pinned upstream refs, patch series, config fragments), and
`scripts/fetch-patches.sh` resolves them into the stack the PKGBUILD applies.

## Products

| product | package | base | patches | device |
|---|---|---|---|---|
| `handheld` | `linux-handheld-aarch64` | CachyOS release + BORE | local series in `patches/series.d/`; entries without a copy in `patches/handheld/` come from [armada](https://github.com/armada-os/armada) (`packages/kernel/`) | AYN Odin 3 (Qualcomm CQ8725S / SM8750) |
| `el2` | `linux-el2-aarch64` | CachyOS release + BORE | local series in `patches/el2/` | Lenovo Yoga Slim 7x (X1E80100), booted at EL2 for KVM |

Patches both products carry live once, in `patches/shared/`, and each series lists them as `shared/<name>`.

`handheld` replaces ALARM's `linux-aarch64`; `el2` installs beside it
(`/boot/Image-el2`, `/boot/dtbs-el2/qcom/`).

## Build

Needs an aarch64 host with docker.

```sh
./scripts/fetch-patches.sh               # resolve base + patch stack -> version.env
./scripts/build.sh                       # makepkg in the ALARM builder container -> out/
NOBUILD=1 FETCH=1 ./scripts/build.sh     # patches + config only, no compile
PRODUCT=el2 FETCH=1 ./scripts/build.sh   # pick a product
```

CI (`.github/workflows/`) polls the upstreams, builds every product on push,
signs and publishes to R2, and tags each release `<TAG_PREFIX><pkgver>-<pkgrel>`.

## Install

Trust the repository key, add the repository, install:

```sh
curl -fsSL <repo-url>/handheld.gpg -o /tmp/handheld.gpg
sudo pacman-key --add /tmp/handheld.gpg
sudo pacman-key --lsign-key "$(gpg --with-colons --show-keys /tmp/handheld.gpg | awk -F: '/^fpr:/{print $10; exit}')"
printf '\n[handheld]\nSigLevel = Required DatabaseOptional\nServer = <repo-url>/aarch64\n' | sudo tee -a /etc/pacman.conf
sudo pacman -Syu linux-handheld-aarch64 linux-handheld-aarch64-headers   # or linux-el2-aarch64{,-headers}
```

Rollback, the el2 initramfs step and the rest are in the wiki.

## Documentation

- [Building and publishing](https://github.com/wahooli/linux-handheld-aarch64/wiki/Building-and-Publishing): products, refs and polling, the build container, ccache, PKGBUILD flow, CI, signing, R2, tags, installing
- [Kernel configuration](https://github.com/wahooli/linux-handheld-aarch64/wiki/Kernel-Configuration): base configs, fragments and per-symbol reasons, trim rules
- [EL2 patch reference](https://github.com/wahooli/linux-handheld-aarch64/wiki/EL2-Patch-Reference): every patch in the el2 series
- [Handheld patch reference](https://github.com/wahooli/linux-handheld-aarch64/wiki/Handheld-Patch-Reference): the handheld series taken over from armada, what changed on 7.3, and the shared set
- [Hibernation at EL2](https://github.com/wahooli/linux-handheld-aarch64/wiki/Hibernation-at-EL2), [ADSP and remoteprocs at EL2](https://github.com/wahooli/linux-handheld-aarch64/wiki/ADSP-and-Remoteprocs-at-EL2), [Suspend-to-idle power](https://github.com/wahooli/linux-handheld-aarch64/wiki/Suspend-to-Idle-Power), [Display](https://github.com/wahooli/linux-handheld-aarch64/wiki/Display)
- [Open issues](https://github.com/wahooli/linux-handheld-aarch64/wiki/Open-Issues)
