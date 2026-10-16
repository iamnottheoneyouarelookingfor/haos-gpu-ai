<div align="center">

# 🏠🤖 HAOS GPU-AI Universal

**A from-scratch, tri-vendor GPU-accelerated fork of Home Assistant OS — run local LLMs on bare-metal GPU speed, inside a Home Assistant add-on.**

[![Platform](https://img.shields.io/badge/platform-x86__64%20bare--metal-blue)](#)
[![HAOS](https://img.shields.io/badge/HAOS-18.3%20target%20(kernel%206.18)-41BDF5)](#)
[![GPUs](https://img.shields.io/badge/GPU-NVIDIA%20%2B%20Intel%20%2B%20AMD-76B900)](#)
[![OTA](https://img.shields.io/badge/OTA-CA--signed%20%2F%20decoupled-success)](#)
[![Status](https://img.shields.io/badge/status-hardware--proven-brightgreen)](#)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

<a href="https://www.buymeacoffee.com/sam3gp8" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="46" width="163"></a>

</div>

---

A Buildroot **external-tree** overlay that turns Home Assistant OS into a
bare-metal, tri-vendor GPU host for local LLM/AI add-ons. A single unified
x86-64 image ships driver support for **NVIDIA + Intel + AMD**; the correct
stack is activated at boot from the PCI bus. Upstream HAOS releases can be
tracked and rebuilt into **signed, decoupled OTA bundles** that the Supervisor
cannot overwrite.

The submodule under `upstream/` is **never modified** — everything is injected
through this external tree, the rootfs overlay, build-time patches, and a merged
defconfig.

> ### ✅ Proven end-to-end on real hardware
> This isn't theoretical. On an RTX 4090 the built image was validated all the way through:
> - Host `nvidia-smi` → driver **595.84**, CUDA **13.2**, 24 GB VRAM
> - A stock `ubuntu` container running `nvidia-smi` → the 4090 injected into the container namespace
> - The bundled **Ollama add-on** loading a **26B-parameter model** into VRAM (`llama-server` holding ~18.5 GB) and answering as the smart-home's Assist conversation agent
> - A **stock HAOS OTA bundle rejected** by RAUC (compatible-string + keyring mismatch) — the update-lock demonstrated live

> **New here? Follow [`SETUP.md`](SETUP.md)** for the exact step-by-step build,
> including the real-world gotchas (kernel/driver pre-seeding, builder network,
> and the `FORCE_UNSAFE_CONFIGURE` / dind notes for a fresh machine).

---

## The core architecture decision (read this first)

This preserves HAOS's read-only, atomic appliance model by putting the right
things in the right layer:

| Layer | Responsibility |
|-------|----------------|
| **Host OS (this repo)** | Kernel drivers, firmware, `/dev` nodes, and — for NVIDIA only — the driver's user-space libs + the Container Toolkit injection layer |
| **Add-on container** | The heavy compute *runtime*: CUDA runtime, ROCm/HIP, oneAPI/Level-Zero/NEO |

That split is what makes a universal image feasible. Compiling CUDA, ROCm, and
Intel's NEO/IGC into an immutable OS is impractical (much of it won't
cross-compile in Buildroot) and would defeat the appliance model you're
preserving. So:

- **NVIDIA** is the one vendor needing host user space: its proprietary driver
  libs (`libcuda`, `libnvidia-ml`, `libnvidia-ptxjitcompiler`) plus the NVIDIA
  Container Toolkit, which *injects* those host libs into containers at runtime.
- **Intel & AMD** use open kernel drivers and standard kernel interfaces
  (`/dev/dri`, `/dev/kfd`). Their packages are deliberately kernel + firmware +
  udev coordinators. The runtime (ROCm image, oneAPI image) lives in the add-on.

---

## Design corrections vs. a literal reading of the spec

Several details in the original brief would break the build or the
universal-image goal. What this repo actually does, and why:

1. **`CONFIG_STAGING` is not the mechanism for out-of-tree modules.** It only
   enables the in-tree `drivers/staging` subsystem. Out-of-tree NVIDIA modules
   need `CONFIG_MODULES` + a configured kernel tree. The real *unified-memory*
   kernel dependencies are `HMM_MIRROR` / `ZONE_DEVICE` / `DEVICE_PRIVATE`
   (+ `HSA_AMD_SVM` for AMD) — all set in `external/kernel/gpu-ai.config`.

2. **`libnvrtc`/`libcudart` are CUDA *toolkit* libraries, not driver libraries.**
   They are not in the driver `.run`; they ship in the container. The host
   installs only what the driver payload provides.

3. **`default-runtime: nvidia` is baked in — and safe on non-NVIDIA hosts.**
   `/etc/docker` is part of the read-only rootfs, so `daemon.json` can't be
   rewritten at boot; a runtime switch is structurally impossible. The naive
   worry is that a baked `nvidia` default breaks Intel/AMD boxes, but the nvidia
   runtime is a `runc` shim whose hook **no-ops unless a container sets
   `NVIDIA_VISIBLE_DEVICES`** — so Supervisor, Core, and every ordinary add-on
   run untouched on any vendor. `gpu-autodetect` therefore only loads the right
   kernel modules; it does **not** (and can't) edit `daemon.json`.

4. **The version suffix is cosmetic.** `-gpu-ai-universal` only discourages the
   frontend from offering a stock update. The *hard* guards against a stock
   image overwriting this branch are the custom RAUC **`compatible` string**
   (`haos-generic-x86-64-gpu-ai`, rejected pre-signature) **and our own
   keyring**. Both are configured.

5. **HA add-ons can't request `--gpus`/`--runtime`.** The working patterns are
   (a) NVIDIA via the conditional default-runtime, and (b) Intel/AMD via device
   mapping. For a *universal* add-on, naming `/dev/nvidia0` in `devices:` would
   fail to start on Intel/AMD, so the sample add-on uses `full_access: true`
   (trade-off documented in `addon-ollama/config.yaml`).

6. **NVIDIA *open* kernel modules** are used (vendor-recommended for Turing+ and
   the only variant that builds on recent kernels). RTX 40-series is fully
   supported.

---

## Repository layout

```
haos-gpu-ai/
├── upstream/                         # submodule: home-assistant/operating-system (PRISTINE)
├── external/                         # our BR2_EXTERNAL tree (name: HAOS_GPU_AI)
│   ├── external.desc                 # -> $(BR2_EXTERNAL_HAOS_GPU_AI_PATH)
│   ├── external.mk                   # wildcard-includes package/*/*.mk
│   ├── Config.in                     # BR2_PACKAGE_HAOS_GPU_AI_ALL selects all 3 vendors
│   ├── configs/
│   │   └── gpu_ai.fragment           # additive defconfig symbols
│   ├── kernel/
│   │   └── gpu-ai.config             # unified kernel fragment (DRM/i915/xe/amdgpu/HMM…)
│   ├── package/
│   │   ├── haos-compute-nvidia/      # open kernel modules + driver libs
│   │   ├── haos-nvidia-container-toolkit/  # runtime hook
│   │   ├── haos-compute-intel/       # kernel+firmware contract (+NOTES.md)
│   │   └── haos-compute-amd/         # kernel+firmware contract (+NOTES.md)
│   ├── rootfs-overlay/
│   │   └── etc/{modprobe.d,udev,docker,rauc}/…  + usr/bin + systemd units
│   ├── patches/                      # BR2_GLOBAL_PATCH_DIR
│   └── scripts/                      # merge-defconfig, build, post-build, generate-ca
├── ota/version-gpu-ai.json           # custom OTA channel manifest
├── addon-ollama/                     # sample GPU-accelerated add-on
└── .github/workflows/build-and-track.yml
```

---

## How the pieces fit

- **`external/Config.in`** — `BR2_PACKAGE_HAOS_GPU_AI_ALL=y` force-`select`s the
  three vendor packages so one image contains all stacks.
- **`scripts/merge-defconfig.sh`** — copies the upstream `generic_x86_64_defconfig`
  into *our* tree's `configs/` and **appends in place** to the space-separated
  multi-value vars (`BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`, `BR2_ROOTFS_OVERLAY`,
  `BR2_GLOBAL_PATCH_DIR`, `BR2_ROOTFS_POST_BUILD_SCRIPT`) so upstream values are
  preserved, then adds the additive fragment.
- **`scripts/build.sh`** — chains both external trees
  (`BR2_EXTERNAL=<upstream>/buildroot-external:<ours>`), exports
  `ota_compatible`, and runs Buildroot.
- **`gpu-autodetect.service`** (before `docker.service`) — loads the matching
  vendor modules and writes the conditional `daemon.json`.
- **`haos-gpu-updater.timer`** — daily, pulls our signed `.raucb` from our
  GitHub Releases and `rauc install`s it, bypassing the Supervisor updater.

---

## Build

```bash
git clone --recurse-submodules https://github.com/sam3gp8/haos-gpu-ai.git
cd haos-gpu-ai

# one-time: create the signing CA
./external/scripts/generate-ca.sh ./pki      # cert.pem public, key.pem secret

# build (inside the HAOS builder container; see the workflow for the CI form)
cp pki/cert.pem cert.pem && cp pki/key.pem key.pem
./external/scripts/build.sh
# -> output/images/*.raucb  and  output/images/haos_*.img.xz
```

## Getting to a green build

Out-of-tree GPU drivers rarely build clean on the first try, so converge in two
stages using the build profile and the preflight gate.

**Stage 1 - NVIDIA + AMD, smallest surface:**

```bash
PROFILE=nvidia-amd ./external/scripts/build.sh
```

This drops the Intel package and, critically, the `CONFIG_DRM_XE` kernel symbol
(the most kernel-version-fragile part of the fragment). What's left is the
proprietary NVIDIA out-of-tree build plus in-tree `amdgpu`/`i915` - the pieces
most likely to succeed. Since you've already boot-verified an NVIDIA-only
branch, the NVIDIA package here should be close to known-good.

**The preflight gate runs first and fails fast** (seconds, not minutes) on:
- kernel vs. NVIDIA driver-branch mismatch (bump the pin or the matrix in
  `preflight-check.sh` - e.g. a 6.12 HAOS kernel wants driver branch 560/565,
  not 550);
- a typo'd driver/toolkit version (asset unreachable);
- asking for Xe on a kernel too old to have it.

```bash
# run the gate on its own without building
./external/scripts/preflight-check.sh nvidia-amd
```

**Stage 2 - add Intel + Xe once Stage 1 is green:**

```bash
PROFILE=all ./external/scripts/build.sh      # (this is the default)
```

If the Xe build errors that `CONFIG_DRM_XE` is unknown for your pinned kernel,
either stay on `nvidia-amd` or delete the two `DRM_XE` lines from
`external/kernel/gpu-ai.config` - i915 still provides `/dev/dri` for Intel.

In CI, choose the profile from the **Run workflow** dropdown; the scheduled
nightly build always uses `all`. The gate runs there too (`STRICT=1`) so a bad
pin fails the job before the builder container is even pulled.

## Flash a fresh install

```bash
xz -dc output/images/haos_generic-x86-64-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

## Update an existing GPU-AI install

- **Automatic:** the daily timer installs new releases from this fork.
- **Manual:** `rauc install haos_generic-x86-64-<ver>.raucb && reboot`

## GPU-accelerated add-on

Copy `addon-ollama/` into a local add-on repo, install it from the HA add-on
store, start it, and check the log for the detected GPU. It serves the Ollama
API on `:11434`.

---

## Status & caveats

This has been **built and hardware-validated end to end** (see the callout at
the top). The following were the hard problems along the way — all resolved in
this repo, but worth knowing if you re-pin to a different HAOS/kernel version,
because they're where version drift bites:

- **NVIDIA driver ↔ kernel pairing** — **595.84** (open modules, Turing+/Ada;
  covers the RTX 4090). Fully proven on kernel **6.12.85** (HAOS 17.3); the repo
  now **targets HAOS 18.3 / kernel 6.18.52**, which 595.84 also covers — but the
  18.3 open-module build is pending its first green build + flash. A newer kernel
  line needs its driver pairing re-validated.
- **GSP firmware path** — the open modules require `gsp_ga10x.bin` under
  `/usr/lib/firmware/nvidia/<ver>/` (merged-usr path — *not* `/lib/firmware`).
- **NVIDIA Container Toolkit** ships as a `.deb` (extracted via `dpkg-deb`); its
  `config.toml` must point `ldconfig` at a **host** binary (toolkit ≥1.17
  bind-mounts the host ldconfig into containers), which HAOS doesn't ship by
  default — so the image installs one.
- **Docker storage** — HAOS preloads its data partition in **containerd-snapshotter**
  format; the shipped `daemon.json` must match stock (no pinned `storage-driver`)
  or dockerd rejects the store and the Supervisor never starts.
- **`/etc/docker` is read-only** on HAOS, so `"default-runtime": "nvidia"` is
  **baked into `daemon.json`** at build time (it's a no-op on non-NVIDIA hosts —
  the runtime hook only fires when a container sets `NVIDIA_VISIBLE_DEVICES`).
- **A/B boot-good** — a `rauc-mark-good` service resets the grub try-counter each
  boot so a networkless/slow first boot can't strand the box in the rescue shell.
- **OTA decoupling** — the custom `compatible` string is applied at every
  `haos_rauc_compatible` call site (HAOS 18.x renamed it from
  `hassos_rauc_compatible`; `build.sh` matches both), and the RAUC keyring is
  baked from **your** CA so stock bundles are rejected before install.
- **`CONFIG_DRM_XE`** depends on the pinned kernel; drop the two `DRM_XE` lines
  from `external/kernel/gpu-ai.config` if a build reports it unknown (i915 still
  provides `/dev/dri`).

The structure, the layering, the RAUC/OTA safety model, and the host/container
split are the durable parts; the vendor package versions are where you'll iterate.

---

## 💛 Support

If this saved you a week of Buildroot archaeology, you can buy me a coffee:

<a href="https://www.buymeacoffee.com/sam3gp8" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="46" width="163"></a>

→ **https://www.buymeacoffee.com/sam3gp8**

## License

Released under the [MIT License](LICENSE). Home Assistant OS and Buildroot are
the property of their respective projects; this repo is an external overlay and
does not redistribute their source (the `upstream/` submodule points at the
official Home Assistant OS repository).

