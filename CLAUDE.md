# CLAUDE.md — HAOS_GPU_AI project state & working rules

Guidance for any Claude Code session working in this repo. Sourced from the
project handoff (PROJECT-STATE) plus what's verified in this tree. **If a claim
here disagrees with a live device log, the device wins — fix this file first,
then act.**

---

## Project & goal

HAOS_GPU_AI is a production, tri-vendor GPU fork of Home Assistant OS: one
unified x86_64 image shipping **NVIDIA** (proprietary out-of-tree modules +
driver userspace), **Intel** (i915/Xe), and **AMD** (amdgpu + KFD) host stacks
together, with the right driver autoloaded at boot from the PCI bus.

**Core design rule (do not violate):** the OS provides the *host environment
only* — kernel drivers, firmware, device nodes, NVIDIA-only driver userspace,
udev, and the Docker engine hooks. Inference runtimes (CUDA runtime, ROCm,
oneAPI, Ollama, llama.cpp, vLLM) live in a **Home Assistant add-on container**
that reaches the hardware at bare-metal speed via the container runtime.
**Nothing like Ollama or llama.cpp is ever compiled into the read-only rootfs.**

- **Build method:** a `BR2_EXTERNAL` Buildroot overlay (`external/`) against a
  git submodule of `home-assistant/operating-system` (`upstream/`). **The
  submodule is never edited directly** — all changes go through the external
  tree, patches, overlays, and build-time working-tree patches in `build.sh`.
- **Upstream tracking + OTA:** a daily GitHub Actions job checks for new HAOS
  release tags; RAUC A/B with a custom keyring builds our own OTA bundles. A
  `-gpu-ai-universal` version suffix + custom `compatible` string + our keyring
  decouple the build so the Supervisor can't overwrite the GPU branch.
- **Target appliance:** Sam's gaming PC — i9-10850K, 64 GB RAM, RTX 4090.

**Two deliverables:**
1. The OS fork — *this* repo (`sam3gp8/haos-gpu-ai`).
2. Companion Ollama add-on — `github.com/sam3gp8/ha-addons`, slug
   `ollama_notimeout` (the reference consumer of the host stack; **v1.1.4,
   published & stable**). `addon-ollama/` here is a reference copy.

---

## Canonical tree & the two build machines

- **IdeaPad Slim 3** holds the canonical tree.
- **Gaming PC / RTX 4090** is the target appliance (and an earlier build host).
- The **GitHub repo is the tie-breaker** between machines: one fix, committed
  once, pulled everywhere.

Device-verified anchor paths used by the gates/rebuild:
`external/package/haos-compute-nvidia/haos-compute-nvidia.mk`,
`external/scripts/build.sh`, and the `output/` build tree.

> Note: the handoff's sketch names some paths approximately. In *this* tree the
> kernel fragment is `external/kernel/gpu-ai.config` (+ a `gpu-ai-nvidia-amd.config`
> for the no-Xe profile), not a single `external/kernel.config`. Trust the actual
> checkout over any layout sketch.

---

## Current verified device state (re-verify before relying on it)

| Area | State |
|------|-------|
| Running image | **HAOS 17.3-gpu-ai-universal**, Core 2026.7.1, on the 4090 PC — version-suffix decoupling working |
| Kernel | **6.12.85** (pinned to 17.3). **18.1 / kernel 6.18.37 currently 404s on the kernel.org CDN** — do not try to auto-build 18.1 until that clears |
| GPU host stack | NVIDIA **595.84** open modules, GSP firmware, autodetect, baked `default-runtime: nvidia`, toolkit **1.19** host-ldconfig injection — all validated live |
| Add-on in container | 4090 = CUDA compute 8.9, 23.5 GiB; flash attention on; `q8_0` KV cache; 31/31 layers offloaded |
| PTX-JIT | **restore validated live (2026-10-16)**: the `cuda_v13` runner completes gemma inference at ~93 tok/s, `POST /v1/chat/completions → 200`, **no `CUDA error 221`** — the handoff's remaining OS task is closed |

---

## PTX-JIT decision record (STATUS: applied in tree + validated live 2026-10-16)

**Decision (2026-07-09, approved): keep `libnvidia-ptxjitcompiler` installed.
Do not trim it again.**

- **Symptom it fixes:** model warmup aborts with `CUDA error 221: PTX JIT
  compiler library not found` (in `ggml_cuda_kernel_can_use_pdl` →
  `cudaFuncGetAttributes`), loading e.g. `gemma4:26b`.
- **Root cause:** Ollama 0.31+ selects the `cuda_v13` runner (driver reports
  13.2); that llama.cpp vintage probes PDL kernel attributes at warmup, forcing
  a PTX-JIT load **even on native-SASS sm_89 (Ada) hardware**. With the lib
  trimmed, libcuda hard-aborts.
- **Why the old trim existed:** the tri-vendor rootfs (~294 MiB) overflowed the
  hard-coded 256 MiB `SYSTEM_SIZE`. Two fixes shipped together: (a) trim the
  lib; (b) bump `SYSTEM_SIZE` 256M→512M. The size bump alone was the real fix,
  so the trim is now pure downside (~15–18 MiB compressed inside ~235 MiB
  headroom, one crash).
- **In this tree today:** the restore is **present** — see the guarded JIT loop
  in `haos-compute-nvidia.mk` (Tier-1 `libnvidia-ptxjitcompiler` + Tier-2
  `nvvm`/`gpucomp`/`allocator`, each glob-guarded so a missing name can't break
  the build), and `SYSTEM_SIZE=512M` in `build.sh`. If a *different* checkout
  shows `grep -c ptxjitcompiler …mk` = 0, it predates this fix — re-apply.
- **Validated live (2026-10-16):** the Ollama GPU-AI Universal add-on log shows
  the 4090 bound as `library=CUDA compute=8.9 … libdirs=ollama,cuda_v13
  driver=13.2`, and a full chat completion ran to `200` at ~93 tok/s with slots
  returning idle — i.e. the `cuda_v13` runner that used to throw error 221 now
  completes. Diagnosis confirmed, falsifier not triggered; this decision is
  closed, not open.
- **Falsifier:** if gate V1 shows `ptxjitcompiler` already present on a
  *running* image that still crashes, the diagnosis is wrong — stop and reopen.

---

## Verification gates — run before any rebuild (all zero-cost)

- **V1 — falsifier (HAOS console):** `ls /usr/lib/ | grep -i nvidia`. Expect
  `libcuda` + `libnvidia-ml`; if `ptxjitcompiler` is absent on a crashing image,
  diagnosis confirmed. If present on a crashing image → **STOP, reopen.**
- **V2 — runner-dependence + interim bridge (add-on config):** set
  `extra_env` → `{"OLLAMA_LLM_LIBRARY": "cuda_v12"}`, reload the model. If it
  loads where v13 aborted, runner dependence is proven; keep as a bridge and
  remove after the rebuild.
- **V3 — flash-path readiness (HAOS console):** `cat /etc/rauc/system.conf` and
  `rauc status`. `compatible=` must contain `-gpu-ai` and the keyring must point
  at the custom CA → the next image installs via `rauc install`. If compatible
  is stock → flag before flashing.
- **V4 — which tree survived:** the prior full-disk `dd` may have destroyed the
  gaming-PC tree. External/second disk → survived & canonical; main-SSD
  partition → destroyed, IdeaPad tree is canonical. Resolve with a live USB +
  `lsblk -f` before trusting either tree.
- **V5 — tree-state markers (on the canonical tree):**
  ```
  grep -c ptxjitcompiler external/package/haos-compute-nvidia/haos-compute-nvidia.mk
  grep -n 'SYSTEM_SIZE'   external/scripts/build.sh          # 512M bump present
  grep -rn 'ota_compatible\|gpu-ai' external/scripts/build.sh | head -5
  ls output/build/haos-compute-nvidia-595.84/payload/ | grep -E 'ptxjit|nvvm|gpucomp|allocator'
  ```

---

## Build & flash

**Rebuild (canonical tree; removing the stamp forces the changed package to reinstall):**
```
docker run --rm --privileged -v "$PWD:/workspace" -w /workspace -e BR2_DL_DIR=/workspace/dl \
  haos-gpu-builder bash -c '
    rm -f output/build/haos-compute-nvidia-595.84/.stamp_target_installed
    PROFILE=all ./external/scripts/build.sh > /tmp/b.log 2>&1; echo "BUILD EXIT=$?"
    ls output/target/usr/lib | grep -E "ptxjit|nvvm|gpucomp|allocator"
    ls -lh output/images/rootfs.erofs output/images/*.raucb output/images/*.img.xz'
```
Pre-flash gates: `BUILD EXIT=0`; `ptxjitcompiler` present in
`output/target/usr/lib`; `rootfs.erofs` under 536870912 bytes (512M).

**Build profiles** scope the tri-vendor combo: `all` (default), `nvidia-amd`
(no Xe), `intel-amd` (in-tree only, pipeline proof). Converge `intel-amd` →
`nvidia-amd` → `all`. The preflight gate (`external/scripts/preflight-check.sh`)
fail-fasts on kernel↔driver mismatch, unreachable assets, and Xe-on-old-kernel.

**Flash (decided by V3):**
- V3 pass (expected): copy the `.raucb` to the box → `rauc install
  /mnt/data/<bundle>.raucb` → reboot. Data partition untouched; boot-good
  service marks the slot or GRUB falls back. **Do NOT full-disk `dd`** — the box
  carries real state.
- V3 fail: report `system.conf` before writing anything; author a system-slot-
  only `dd` against the actual slot layout.

**Post-flash proof:** `ls /usr/lib | grep -i ptxjit` (host) and
`docker exec addon_local_ollama_notimeout ls /usr/lib/x86_64-linux-gnu | grep -i ptxjit`
(container), then load `gemma4:26b` (remove any V2 `cuda_v12` override) → warmup
completes.

---

## Architecture learnings & regression guards (do not re-break)

- **Host/container split:** host = kernel drivers, firmware, device nodes,
  NVIDIA-only driver userspace. CUDA runtime / ROCm / oneAPI belong in the
  container. Never compile a runtime into the rootfs.
- **Unified-memory kernel deps:** `CONFIG_STAGING` is irrelevant for out-of-tree
  modules — the real deps are `HMM_MIRROR` / `ZONE_DEVICE` / `DEVICE_PRIVATE` /
  `HSA_AMD_SVM` (set in `external/kernel/gpu-ai.config`).
- **`daemon.json` is static** (rootfs is read-only, so `default-runtime: nvidia`
  is **baked in**, not set at runtime). Correct config includes
  `"data-root": "/mnt/data/docker"` and `"bip": "172.30.232.1/23"` with **no
  `storage-driver` key** — pinning `overlay2` makes Docker refuse HAOS's
  containerd-snapshotter store (a prior boot-loop). The nvidia runtime hook
  no-ops unless a container sets `NVIDIA_VISIBLE_DEVICES`, so it's safe on
  Intel/AMD-only hosts. `gpu-autodetect` only loads modules; it cannot edit
  `daemon.json`.
- **GSP firmware path:** open modules require `gsp_ga10x.bin` at
  `/usr/lib/firmware/nvidia/<ver>/` (merged-usr path, **not** `/lib/firmware`).
- **ldconfig:** nvidia-container-toolkit 1.19 always bind-mounts the *host's*
  ldconfig (container-side mode removed as a CVE fix). HAOS/Buildroot ships none,
  so `BR2_PACKAGE_GLIBC_UTILS=y` + the `post-build.sh` fallback is required.
- **GRUB A/B slot counter** increments every boot and is reset only by marking
  the slot good; without a boot-success service it climbs to 3 and GRUB drops to
  rescue (a prior rescue-loop). `rauc-mark-good` handles this.
- **Add-on engineering:** Ollama's official Linux binaries are glibc-linked →
  Debian `bookworm-slim` base, **Alpine/musl impossible**. NVIDIA injection
  needs **both** `NVIDIA_VISIBLE_DEVICES=all` and
  `NVIDIA_DRIVER_CAPABILITIES=compute,utility`. `kv_cache_type` needs a
  post-`extra_env` guard forcing flash attention on when a quantized KV type is
  set (llama.cpp hard-fails on quantized KV without FA). **HA add-on option type
  changes are always key renames, never in-place retypes** — the Supervisor
  validates stored options against the new schema before updating.

---

## Key pinned versions

| Component | Version | Notes |
|-----------|---------|-------|
| HAOS | 17.3 | kernel 6.12.85; 18.1 (6.18.37) currently 404s on the kernel.org CDN |
| HA Core | 2026.7.1 | running image |
| NVIDIA driver | 595.84 | open modules; Turing+/Ada; covers 6.12→6.18/6.19 |
| nvidia-container-toolkit | 1.19 | host-ldconfig bind-mount injection |
| Ollama | 0.31.1 | selects `cuda_v13` runner (driver reports 13.2) |
| s6-overlay | v3 | add-on init |
| Add-on base | Debian bookworm-slim | glibc (Alpine impossible) |
| SYSTEM_SIZE | 512M | up from 256M; trim constraint retired |
| Add-on `ollama_notimeout` | v1.1.4 | published, stable |

---

## Process rules (carry these over)

1. **Device evidence wins.** If two sources disagree, the claim citing device
   logs wins; update the losing doc *first*, then execute.
2. **Commit direction to the repo root** (this `CLAUDE.md` / PROJECT-STATE); the
   GitHub repo is the cross-machine tie-breaker — one fix, committed once.
3. **Working standard:** concise, no sycophancy or speculation; source-grounded
   diagnosis before any architectural decision; an explicit falsifier with every
   reversal; iterative debugging driven by real device logs; **`rauc install`,
   never `dd`**; build profiles to scope tri-vendor combinations.

---

## Getting this repo to a published build (CI)

Code is buildable on the 17.3 line as-is. To publish signed OTA releases:
1. **RAUC secrets** in Actions — `RAUC_SIGNING_CERT` / `RAUC_SIGNING_KEY`
   (generate with `external/scripts/generate-ca.sh ./pki`). Without them CI signs
   with a throwaway key and the OTA lock degrades silently.
2. **First run is manual + smallest surface:** run `build-and-track.yml` with
   `profile=nvidia-amd` and `force_tag=<HAOS_TAG>`; iterate to green, then `all`.
3. **Runner size:** a full HAOS build is disk/time heavy — prefer a larger or
   self-hosted runner.
4. **Don't auto-build 18.1** until its kernel tarball stops 404ing.
