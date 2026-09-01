# linux-handheld-aarch64

Kernel packages for **Arch Linux ARM (aarch64)**, published as a signed pacman
repository on Cloudflare R2.

One build produces two packages — `<pkgbase>` and `<pkgbase>-headers` — and
devices install them with `pacman -S`.

## Products

A **product** is one package family: one `pkgbase`, one kernel base, one config,
one patch series, one or more devices. Each is a file in `products/`, and
`PRODUCTS` in `sources.env` lists the ones that get built.

| product | pkgbase | base | device |
|---|---|---|---|
| `handheld` | `linux-handheld-aarch64` | CachyOS release tarball + armada's series | AYN Odin 3 (Qualcomm Dragonwing CQ8725S / SM8750) |
| `el2` | `linux-el2-aarch64` | CachyOS release tarball + a local EL2 series | Lenovo Yoga Slim 7x (X1E80100), booted at EL2 for KVM |

`el2` installs **beside** ALARM's stock kernel rather than replacing it
(`REPLACE_STOCK_KERNEL=no`), so its image, dtb directory and initramfs paths are
all distinct: `/boot/Image-el2`, `/boot/dtbs-el2/qcom/`,
`/boot/initramfs-linux-el2.img`. Its config starts from a snapshot of the running
kernel (`CONFIG_BASE=config/base/el2.config`) rather than `make defconfig`, so
every flag that machine boots with today survives.

Everything else in the repository — the PKGBUILD, the scripts, the workflows, the
signing and publishing path — is shared. Adding a product is a new
`products/<name>.conf`, a `config/<name>/` fragment directory, a `SERIES`, and
one word in `PRODUCTS`.

**One kernel per product, not per device.** A product names its boards' device
trees and dtbs in its conf, and one package ships all of them. Patches for a
board the running device is not are unreachable code, so there is nothing to gain
from splitting the package — and a device-specific build would multiply the
matrix, the ccache and the retention window for it.

## Patch series

`SERIES` in a product conf is either the literal **`armada`** — take
[armada-packages](https://github.com/armada-os/armada-packages)' own
`kernel/patches/series` at `ARMADA_REF`, whole — or a path to a local series file
for a product whose patches have no upstream manifest.

`handheld` takes armada's, all 135 entries. It used to curate a 50-entry subset;
that bought nothing, because the ~85 extra are drivers and panels for hardware
this kernel will never see and their Kconfig symbols are off. What it costs is
that those 85 can now *fail to apply* and break a build for a board nobody here
owns — `SERIES_DENY` in the product conf is the lever for that, and it is meant
to be used and then emptied, not to grow back into a curated list.
`SERIES_EXTRA` covers the reverse case: armada's `patches/` directory holds one
patch their series omits (`0900`, their own USB-adapter-type diagnostic), and it
is named there explicitly rather than lost.

Taking the series whole immediately retired a local patch: `patches/local/` is
now empty, because armada's `0049-drm-msm-dpu-panel-opt-in-8bpc-dither.patch`
does what the local Odin 3 dither patch did, via an `armada,dpu-8bpc-dither` DT
property that the Odin 3 DTS delta already sets.

## Kernel base

`KERNEL_SOURCE` in a product conf selects one of two bases:

- **`cachyos`** — a [CachyOS/linux](https://github.com/CachyOS/linux) release
  tarball: mainline stable with CachyOS's own branches already merged (`cachy`,
  `gaming-sched`, `bbr3`, `ksm`, `preempt-ipi`, `amd-pstate`, …). One signed
  asset, tracking stable within days.
- **`kernel.org`** — pristine mainline, PGP-verified against the release signers.

`handheld` is on `cachyos`. The reason is not only the patch set: 32 of the 34
patches this repo took from OpenGamingCollective were `sched/` work headed by
Zijlstra's *"sched/eevdf: Move to a single runqueue"*, and CachyOS merges that
same mailing-list series via `7.2/gaming-sched`. Basing on CachyOS removes the
whole OGC layer rather than carrying the work twice, so `USE_OGC=no`.

The `kernel.org` path is kept as the answer to *"is it the base?"*:

```sh
CACHY_SCHED_OVERRIDE= KERNEL_SOURCE_OVERRIDE=kernel.org KERNEL_REF_OVERRIDE=7.2.2 \
  NOBUILD=1 FETCH=1 ./scripts/build.sh
```

`CACHY_SCHED_OVERRIDE=` is not optional there: the BORE patch is rebased onto
CachyOS's tree, so a kernel.org base has to drop it. `lp_load` refuses the
combination rather than building something the patch was never tested against.

Verified 2026-09-01: the 51-patch stack applies at `-F0` with no rejects to both
`cachyos-7.2.2-1` and `linux-7.2.2`, with identical config warnings; the CachyOS
tree resolves 5105 config symbols against mainline's 5097.

## CachyOS tuning and BORE

The release tarball carries CachyOS's *code*; their PKGBUILD's `scripts/config`
calls carry the tuning, and those do not travel with it. `config/cachy/` is the
arch-neutral subset — `CACHY=y`, `HZ_1000`, `PREEMPT_LAZY`, `NO_HZ_IDLE`, `-O3` —
with the ones we decline (`NO_HZ_FULL`, `TCP_CONG_BBR3`, THP pinning) listed and
argued in the file. Both products merge it.

BORE is the one patch their `-bore` package adds on top of the tarball, so
`CACHY_SCHED=bore` fetches it from `CachyOS/kernel-patches` at a pinned commit,
and `config/bore/` asserts `CONFIG_SCHED_BORE` — the two fail together if either
is missing.

One wrinkle, documented in full at the top of `patches/cachy/0001-bore-cachy.patch`:
upstream's 7.2 BORE patch predates their own `preempt-ipi` merge and does **not**
apply to `cachyos-7.2.2-1` at zero fuzz. It applies with GNU patch's default fuzz
2 (11 lines lower, which is inert for that hunk) — which is how CachyOS's own
builds succeed. This repo applies at `-F0`, so the patch is committed here
mechanically rebased (`git diff` of a fuzz-applied tree; identical 14 files and
+727/−21 lines as the original). Delete that file to go back to upstream's copy;
the dry-run says immediately whether it works.

## Build

```sh
./scripts/fetch-patches.sh         # resolve base + patch stack -> version.env
./scripts/build.sh                 # makepkg in the ALARM builder container
NOBUILD=1 ./scripts/build.sh       # prepare() only: patches + config, no compile
PRODUCT=handheld ./scripts/build.sh
```

`PRODUCT` may be omitted while `PRODUCTS` names exactly one. `version.env`
records which product it was resolved for, and the build refuses to package one
product against another's resolved stack.

## Versioning

`pkgver` is the base plus the source's own revision — `7.2.2.cachy1` for
`cachyos-7.2.2-1`, a bare `7.2.2` for plain mainline (which therefore sorts
*below* any patched variant of the same kernel, on purpose).

`pkgrel` is allocated by `scripts/next-pkgrel.sh` as one above the highest ever
published for that `pkgbase`-`pkgver`, taking the floor from **both** the R2
listing and the git tags. The tags are the part that matters: packages are served
`Cache-Control: immutable`, so reusing a filename leaves Cloudflare's edge
handing devices old bytes against a new signature — which reads on the device as
`signature is invalid / package is corrupted` and cannot be cleared there. R2
gets pruned; tags do not. `scripts/publish-r2.sh` refuses to overwrite a
published filename as a backstop.

CI must therefore check out with `fetch-tags: true`.
