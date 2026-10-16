#!/usr/bin/env bash
# =============================================================================
# build.sh
#
# Drives a full HAOS GPU/AI build. Intended to run INSIDE the HAOS builder
# container (see .github/workflows/build-and-track.yml) but also works on any
# host that satisfies Buildroot's prerequisites.
#
# Key mechanics:
#   * BR2_EXTERNAL chains BOTH trees (colon-separated): HAOS's own
#     buildroot-external first, then ours. This is the supported Buildroot way
#     to layer external trees and keeps the submodule pristine.
#   * ota_compatible is exported so HAOS's RAUC templates bake our custom
#     `compatible` string into both the running system and the bundle.
# =============================================================================
set -euo pipefail

EXT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # external/
ROOT="$(cd "$EXT/.." && pwd)"                            # repo root
UPSTREAM="${ROOT}/upstream"
BR="${UPSTREAM}/buildroot"
EXT_HAOS="${UPSTREAM}/buildroot-external"
O="${ROOT}/output"
DEFCONFIG="generic_x86_64_gpu_ai_defconfig"

[ -d "$BR" ]       || { echo "ERROR: buildroot submodule missing: $BR" >&2; exit 1; }
[ -d "$EXT_HAOS" ] || { echo "ERROR: HAOS external tree missing: $EXT_HAOS" >&2; exit 1; }

# Build profile: 'all' (default), 'nvidia-amd' (NVIDIA+AMD, no Xe), or
# 'intel-amd' (in-tree only, no NVIDIA - the pipeline-proof target).
PROFILE="${PROFILE:-all}"

# 0. Fast-fail gate: kernel<->driver compatibility + asset reachability, run
#    BEFORE the long build. STRICT=1 aborts on hard failures.
STRICT="${STRICT:-1}" "${EXT}/scripts/preflight-check.sh" "$PROFILE"

# 1. Generate the merged defconfig in our tree's configs/.
# --- system partition size override (see README/SETUP: HAOS hardcodes 256M) ----
# HAOS sets the generic-x86-64 system partition to 256M in its
# buildroot-external/scripts/hdd-image.sh with NO env/meta override. A full
# tri-vendor GPU rootfs (~294M) does not fit, so bump it to 512M at build time.
# This edits the submodule WORKING TREE only (its committed revision is
# unchanged); it is idempotent and re-applied every build, with the logic kept
# here in our tree rather than as a committed change to upstream.
HDD_IMAGE_SH="${UPSTREAM}/buildroot-external/scripts/hdd-image.sh"
if [ -f "$HDD_IMAGE_SH" ] && grep -q '^SYSTEM_SIZE=256M$' "$HDD_IMAGE_SH"; then
	sed -i 's/^SYSTEM_SIZE=256M$/SYSTEM_SIZE=512M/' "$HDD_IMAGE_SH"
	echo ">>> bumped system partition SYSTEM_SIZE 256M -> 512M (fits GPU rootfs)"
fi

# --- skip docker-in-docker image preload -------------------------------------
# HAOS's create-data-partition.sh PRELOADS Supervisor images into the data
# partition via a docker-in-docker container. That dind preload is unreliable in
# our builder and is only an OPTIMISATION: a network-connected HAOS pulls Core +
# Supervisor on first boot (hardware-proven), so we skip it.
#
# The 17.x patch commented the `container=$(docker run ...)` .. `docker exec`
# block by line range. HAOS 18.x restructured this script (see 18.3): besides
# that block it adds `trap 'docker rm -f ${container} ...' ERR EXIT` (top) and an
# explicit `docker rm -f "${container}"` teardown (bottom). With the run line
# commented, ${container} is empty and those teardown calls abort the build
# ("container name cannot be empty" / "docker rm requires at least 1 argument").
#
# So instead of a fragile line-range comment, define `docker` as a no-op for this
# ONE script: the run, exec, trap teardown and explicit teardown all become
# harmless, while the real data-partition work (mkfs, mount, the
# containerd-snapshotter marker, AppArmor, updater channel, umount) still runs.
# Robust across the 17.x/18.x layouts. Idempotent; submodule commit stays clean.
CDP_SH="${UPSTREAM}/buildroot-external/package/hassio/create-data-partition.sh"
if [ -f "$CDP_SH" ] && ! grep -q '#GPU_AI-SKIP' "$CDP_SH"; then
	sed -i '1a docker() { :; }  #GPU_AI-SKIP: neutralise dind image-preload (images pull on first boot)' "$CDP_SH"
	echo ">>> GPU_AI: patched create-data-partition.sh (neutralised dind preload via docker no-op)"
fi

"${EXT}/scripts/merge-defconfig.sh" "$PROFILE"

# 2. DELIVERABLE E (a): custom RAUC `compatible` string.
#    HARDWARE-PROVEN FACT: exporting ota_compatible does NOTHING - HAOS derives
#    the string via a shell function at every consumer (runtime system.conf AND
#    the bundle manifest), overwriting any env. HAOS 18.x renamed that function
#    hassos_rauc_compatible() -> haos_rauc_compatible() (the project-wide
#    HassOS->HAOS rename), so we match BOTH names. Append our suffix at every
#    CALL SITE in the upstream WORKING TREE (commit untouched, idempotent,
#    reapplied each build - same pattern as the SYSTEM_SIZE bump). Result:
#    system.conf and .raucb both carry haos-generic-x86-64-gpu-ai, and stock
#    bundles are rejected PRE-signature.
GPU_AI_COMPAT_SUFFIX="-gpu-ai"
for f in $(grep -rlE --include='*.sh' '(hassos|haos)_rauc_compatible' "${UPSTREAM}/buildroot-external" 2>/dev/null); do
	grep -qE '\$\((hassos|haos)_rauc_compatible\)' "$f" || continue      # callsites only, not the definition
	grep -qE "(hassos|haos)_rauc_compatible\)${GPU_AI_COMPAT_SUFFIX}" "$f" && continue   # idempotent
	sed -i -E "s#(\\\$\((hassos|haos)_rauc_compatible\))#\1${GPU_AI_COMPAT_SUFFIX}#g" "$f"
	echo ">>> E: compatible suffix ${GPU_AI_COMPAT_SUFFIX} applied in ${f#${ROOT}/}"
done

# 2b. DELIVERABLE E (b): sign with YOUR CA, not a throwaway.
#     HARDWARE-PROVEN FACT: the genimage rauc block hardcodes key=/build/key.pem
#     cert=/build/cert.pem; when absent, HAOS self-signs with a FRESH throwaway
#     pair every run (that cert also becomes the baked /etc/rauc/keyring.pem).
#     Stage the user's CA there so the bundle signature AND the on-device
#     keyring are yours - stock (HA-signed) bundles then fail verification too.
#
#     Use -s (exists AND non-empty), not -f: the CI "Write RAUC signing material"
#     step ALWAYS writes cert.pem/key.pem, writing EMPTY files when the
#     RAUC_SIGNING_CERT/KEY secrets are unset. On 18.x, staging an empty cert is
#     fatal: HAOS's prepare_rauc_signing only self-signs when /build/key.pem is
#     MISSING (not empty), so an empty key skips the self-sign and a later
#     `openssl x509 -in /build/cert.pem` aborts target-finalize
#     ("Could not find certificate from /build/cert.pem"). Treating empty as
#     absent lets HAOS self-sign a throwaway and the build completes (with the
#     loud warning below) - matching the documented "no secrets -> throwaway".
GPU_AI_CA_STAGED=0
for d in "${ROOT}/pki" "${ROOT}"; do
	if [ -s "${d}/cert.pem" ] && [ -s "${d}/key.pem" ]; then
		mkdir -p /build 2>/dev/null || true
		cp "${d}/cert.pem" /build/cert.pem
		cp "${d}/key.pem"  /build/key.pem
		chmod 600 /build/key.pem
		echo ">>> E: RAUC signing with YOUR CA from ${d#${ROOT}/}/ (bundle + baked keyring)"
		GPU_AI_CA_STAGED=1
		break
	fi
done
# 2c. DELIVERABLE E (strict): keyring trusts ONLY your CA (not HAOS dev/rel).
#     Stock HAOS keeps its dev-ca/rel-ca in the keyring AND appends yours, so the
#     device would trust HAOS-signed bundles too (the compatible-string mismatch
#     still blocks stock updates, so this is belt-and-suspenders). For a hard
#     lock, rewrite rauc.sh's keyring copy to emit YOUR cert as the sole trust
#     anchor. To keep HAOS's default behaviour instead, delete this block.
# Only harden when a REAL CA was staged. Without one (self-signed throwaway),
# leave HAOS's default dev keyring so a validation build still completes and we
# don't bake a throwaway cert as the sole on-device trust anchor.
RAUC_SH="${UPSTREAM}/buildroot-external/scripts/rauc.sh"
if [ "${GPU_AI_CA_STAGED}" -eq 1 ] && [ -f "$RAUC_SH" ] && ! grep -q 'GPU_AI: keyring = your CA only' "$RAUC_SH"; then
	# HAOS 18.x renamed BR2_EXTERNAL_HASSOS_PATH -> BR2_EXTERNAL_HAOS_PATH; the
	# optional \(SS\)\{0,1\} matches the dev-/rel-ca cp line on both 17.x and 18.x.
	sed -i \
		-e 's|cp "${BR2_EXTERNAL_HA\(SS\)\{0,1\}OS_PATH}/ota/dev-ca.pem" "${TARGET_DIR}/etc/rauc/keyring.pem"|openssl x509 -in /build/cert.pem -text > "${TARGET_DIR}/etc/rauc/keyring.pem"  # GPU_AI: keyring = your CA only|' \
		-e 's|cp "${BR2_EXTERNAL_HA\(SS\)\{0,1\}OS_PATH}/ota/rel-ca.pem" "${TARGET_DIR}/etc/rauc/keyring.pem"|openssl x509 -in /build/cert.pem -text > "${TARGET_DIR}/etc/rauc/keyring.pem"  # GPU_AI: keyring = your CA only|' \
		"$RAUC_SH"
	echo ">>> E: keyring hardened to YOUR CA only (strict decoupling)"
fi

if [ "${GPU_AI_CA_STAGED}" -ne 1 ]; then
	echo ">>> E WARNING: no pki/{cert,key}.pem found - a THROWAWAY self-signed key"
	echo ">>>            will be used and OTA decoupling is NOT secured."
	echo ">>>            Run: ./external/scripts/generate-ca.sh ./pki"
fi

# 3. Chain both external trees.
export BR2_EXTERNAL="${EXT_HAOS}:${EXT}"

mkdir -p "$O"

echo ">>> defconfig"
make -C "$BR" O="$O" BR2_EXTERNAL="$BR2_EXTERNAL" "$DEFCONFIG"

echo ">>> build (this is long: kernel + three GPU stacks + image assembly)"
make -C "$BR" O="$O" BR2_EXTERNAL="$BR2_EXTERNAL"

echo ">>> artifacts"
ls -lh "$O/images" || true
