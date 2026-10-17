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
| Kernel | Running: **6.12.85** (HAOS 17.3). Repo **targets HAOS 18.3 / kernel 6.18.52** (`TRACK_LINE`=`18.`); **built green — 18.3 Release published** (run 39005255151), **not yet flashed** (and bundle-signature provenance unverified) — see "18.x bump status" |
| GPU host stack | NVIDIA **595.84** open modules, GSP firmware, autodetect, baked `default-runtime: nvidia`, toolkit **1.19** host-ldconfig injection — all validated live |
| Add-on in container | 4090 = CUDA compute 8.9, 23.5 GiB; flash attention on; `q8_0` KV cache; 31/31 layers offloaded |
| PTX-JIT | **restore validated live (2026-10-16)**: the `cuda_v13` runner completes gemma inference at ~93 tok/s, `POST /v1/chat/completions → 200`, **no `CUDA error 221`** — the handoff's remaining OS task is closed |

---

## 18.x bump status (2026-10-16 — applied in-tree, NOT yet device-verified)

Bumping 17.3 → **18.3 (kernel 6.18.52)**. This was the gated "deliberate,
re-validated major bump." What the re-validation found and what was done:

- **HassOS → HAOS rename** is the real work of this bump. HAOS 18.x renamed
  things our overlay/patches keyed off. Fixed, matching BOTH names so a forced
  17.x build still works:
  - `build.sh` compatible patch: `hassos_rauc_compatible` → also `haos_rauc_compatible`
    (verified it rewrites 18.3's `rauc.sh` + `hdd-image.sh` call sites; skips the
    `name.sh` definition).
  - `build.sh` keyring patch: `BR2_EXTERNAL_HASSOS_PATH` → also `BR2_EXTERNAL_HAOS_PATH`.
  - `seed-local-addons.service`: ordered after/before `hassos-*` → also `haos-data`
    / `haos-supervisor` units.
- **Unchanged anchor:** `SYSTEM_SIZE=256M` in `hdd-image.sh` (still bumped to 512M).
- **18.x Buildroot is stricter:** `BR2_GLOBAL_PATCH_DIR` pointing at a *missing*
  dir is now a hard error (`pkg-generic.mk: contains nonexistent directory`),
  where 17.x tolerated it. `external/patches/` (referenced by `merge-defconfig.sh`)
  was never created — now committed (empty, with a README). First 18.3 CI build
  (run 38849780169) died here.
- **`create-data-partition.sh` dind-preload skip rewritten.** 18.x restructured
  this script: besides the `container=$(docker run …)` + `docker exec` preload it
  adds a `trap 'docker rm -f ${container} …' ERR EXIT` and an explicit
  `docker rm -f "${container}"` teardown. The old 17.x line-range comment left
  those teardown calls running with an empty `${container}`, aborting the build
  ("container name cannot be empty" / "docker rm requires at least 1 argument").
  Second 18.3 CI build (run 38850285368) died here. Fix: `build.sh` now defines
  `docker` as a **no-op for that one script** (run/exec/trap/teardown all harmless;
  mkfs, mount, containerd marker, AppArmor, channel, umount still run). Robust
  across 17.x/18.x.
- **RAUC signing requires real secrets on 18.x (empty is fatal).** Third CI build
  (run 38866652727, with the create-data-partition fix) reached `target-finalize`
  and died in upstream `post-build.sh` → `install_rauc_certs`:
  `Could not find certificate from /build/cert.pem`. Cause: the
  `RAUC_SIGNING_CERT`/`KEY` Actions secrets are **unset/empty**; the CI step still
  writes empty `cert.pem`/`key.pem`, `build.sh` staged them (its check was `-f`),
  and 18.x's `prepare_rauc_signing` only self-signs when `/build/key.pem` is
  *missing* (not empty) — so it skipped self-sign and `openssl x509` aborted on the
  empty cert. (17.x degraded quietly; 18.x hard-fails.) Fix: `build.sh` now stages
  the CA only when the files are **non-empty** (`-s`), so empty secrets fall back
  to HAOS self-signing and the build completes; and the strict keyring-harden only
  runs when a real CA is staged. **A publishable, flashable 18.3 image still needs
  the real RAUC secrets set** (`generate-ca.sh ./pki` → `gh secret set …`).
- **Submodule** `upstream` gitlink bumped to 18.3 (`0502381a`); `TRACK_LINE` → `18.`.
- **Driver:** 595.84 is kept — it covers the 6.18 line (preflight matrix ceiling 6.20).

**Validated green end-to-end by CI run 39005255151 (2026-10-17, `nvidia-amd`):**
1. ✅ **Kernel 6.18.52 + 595.84 `.run` reachability** — preflight passed (0 failures),
   build fetched + compiled the kernel.
2. ✅ **595.84 open-module compile against 6.18.52** — the biggest risk; cleared.
3. ✅ **Image assembly + GPU-artifact verify** — the "Verify GPU artifacts" step
   (greps the rootfs for nvidia/amdgpu/i915 `.ko`) passed.
4. ✅ **Build published a Release tagged `18.3`** — `haos_generic-x86-64-18.3.img.xz`
   (~420 MB), `.raucb` (~448 MB), `version-gpu-ai.json`. The whole pipeline works
   on 6.18.52.

5. ✅ **Bundle signature = Sam's CA (VALIDATED 2026-10-17).** The signed build —
   CI run **39018751010** (`nvidia-amd`, real `RAUC_SIGNING_CERT`/`KEY` set to the
   HAOS-GPU-AI Release CA) — published a green 18.3 release. The published
   `.raucb` was downloaded and its CMS signature extracted and checked off-box:
   - **Signer = your CA.** The CMS `SignerInfo` issuerAndSerialNumber is
     `O=HAOS-GPU-AI, CN=HAOS-GPU-AI Release CA` serial
     `0x1A2FDEC7905DC8C67354CCAAE7B388D2B1EE3C72` — byte-for-byte your cert
     (sha256 `61:CD:8A:06:20:8A:6D:DD:…:1E:F7:AF`), not a throwaway.
   - **Cryptographically verifies against your CA alone.**
     `openssl cms -verify -CAfile <your-cert> …` → "CMS Verification successful";
     the signed manifest reads `compatible=haos-generic-x86-64-gpu-ai`,
     `version=18.3`, `format=verity`.
   - **Note:** the CMS cert bag *also* carries HAOS's stock "Home Assistant OS
     Provisioning CA Release" cert. It is NOT the signer and is NOT in any chain
     to your keyring — HAOS always embeds it; benign. On-box, confirm with
     `rauc info haos_generic-x86-64-18.3.raucb` (signer = your CA).
6. **Boot + gemma inference on the flashed 18.3 image** — the only remaining proof;
   it is Sam's on-hardware step (V3 → `rauc install` → reboot → gemma warmup).

Converge `intel-amd` → `nvidia-amd` → `all`. Until a green build + flash, the
running device stays 17.3; signature is now proven, boot is the last gate.

> ⚠️ **OTA cross-line hazard — fixed in-tree 2026-10-17; running box NOT yet
> protected.** Both lines share one GitHub Releases feed and an identical RAUC
> `compatible` string, so the old `haos-gpu-updater` (query `releases/latest`,
> guard `[ "$tag" = "$running_ver" ]`) would hand 18.x to a 17.x box: the guard
> can't match (`running_ver` was the suffixed `17.3-gpu-ai-universal`, tag is
> `18.3`) and the shared `compatible` string passes, and now that 18.3 is signed
> by the same CA the 17.3 box trusts the keyring no longer blocks it either.
> **Fix (committed):** `haos-gpu-updater.sh` is now **line-pinned** — it derives
> the device major line from the bare os-release version (`17.3-gpu-ai-universal`
> → `17.3` → `17`), lists `releases` instead of `releases/latest`, and installs
> only the newest non-draft/non-prerelease release **on that same major line**
> (and compares the bare version, fixing the self-redownload). A 17.x box with
> only an 18.x release published now simply skips.
> **CAVEAT:** this lives in the rootfs, so a box only gets it once it is FLASHED
> with an image built from this tree. **Sam's currently-running 17.3 box still
> carries the OLD updater** and is still exposed until it is reflashed — so until
> then protect it directly: `systemctl disable --now haos-gpu-updater.timer` on
> the box, or keep 18.3 marked `prerelease`.

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
| HAOS | 18.3 (target) | kernel 6.18.52; building, not yet device-verified. Last fully proven: 17.3 (kernel 6.12.85) |
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
4. **Now tracking the 18.x line** (`TRACK_LINE="18."`, target 18.3 / kernel
   6.18.52). First 18.3 build should be a manual `force_tag=18.3`, profile
   `nvidia-amd` first, then `all`. The next guarded boundary is 18.x → 19.x.
5. **Building an older line on demand (e.g. 17.3, the proven-stable one).** A
   manual `force_tag=17.3` bypasses the `TRACK_LINE` guard, and every build-time
   patch matches both the 17.x (`hassos_*`) and 18.x (`haos_*`) layouts, so the
   overlay is fine (17.3 preflight passes: kernel 6.12.85, 595.84). The catch is
   the **builder image**: 17.x's `upstream/Dockerfile` is `FROM debian:bullseye`,
   whose aging apt pool 404s on the `docker-ce` block's deps (python-apt). The
   "Determine builder image" step now **strips that `# Docker` block** (nodind —
   the builder never needs docker; `build.sh` no-ops the only dind use), so old
   tags build. The bullseye *build-tools* apt block then rotted too (runs
   39019376966 / 39019974733, 2026-10-17): the base `main` index still resolves
   but the **security pool** (`debian-security/pool/updates/…`) 404s on the final
   `deb11uN` builds of libxml2/qemu-utils/sudo/vim/python3-pil/… Fix (same step):
   when the base is `debian:bullseye`, inject a RUN right after `FROM` that
   repoints apt at **archive.debian.org** (base + its final security pool) and
   sets `Acquire::Check-Valid-Until "false"` (archive Release files are expired).
   Trixie-based (current) tags are detected out and untouched. If archive ever
   rots too, pin a published HAOS builder via the `BUILDER_IMAGE` env instead.
   NOTE: OTA is now **line-pinned** (2026-10-17) — `haos-gpu-updater.sh` filters
   `releases` to the device's own major line and installs only the newest
   non-prerelease release there, so 17.x and 18.x can coexist in one Releases
   feed without a box jumping lines. This takes effect per box only once it is
   flashed with an image carrying the updated script; a box still running an
   older image uses its baked-in (pre-pin) updater.
