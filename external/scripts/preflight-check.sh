#!/usr/bin/env bash
# =============================================================================
# preflight-check.sh
#
# Fast-fail gate run BEFORE the expensive HAOS build. Catches the failures that
# otherwise surface 40 minutes into a build (or after a full CI run):
#   * kernel <-> NVIDIA driver branch mismatch
#   * a typo'd / non-existent driver or toolkit version (asset unreachable)
#   * asking for the Xe profile on a kernel too old to have CONFIG_DRM_XE
#
# Usage:  preflight-check.sh [all|nvidia-amd]
# Env:    STRICT=1     hard-fail on any [FAIL] (default; CI uses this)
#         STRICT=0     report only, always exit 0
#         NV_STRICT=1  treat the NVIDIA kernel-ceiling heuristic as a hard fail
#                      (default: warn, because the matrix below is maintained by
#                      hand and is not authoritative NVIDIA data)
# =============================================================================
set -euo pipefail

EXT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # external/
ROOT="$(cd "$EXT/.." && pwd)"                            # repo root
PROFILE="${1:-all}"
STRICT="${STRICT:-1}"
NV_STRICT="${NV_STRICT:-0}"

fail_count=0
ok()   { echo "  [ ok ] $*"; }
warn() { echo "  [warn] $*"; }
note() { echo "  [note] $*"; }
bad()  { echo "  [FAIL] $*"; fail_count=$((fail_count + 1)); }

# Dotted-numeric compare: ver_le A B is true when A <= B.
ver_le()  { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }
kmajmin() { echo "$1" | awk -F. '{ print $1"."$2 }'; }

echo "== HAOS GPU-AI preflight (profile=${PROFILE}, STRICT=${STRICT}, NV_STRICT=${NV_STRICT}) =="

# --- 1. Resolve the target kernel version from the pristine submodule --------
KDEF="${ROOT}/upstream/buildroot-external/configs/generic_x86_64_defconfig"
KVER=""
if [ -f "$KDEF" ]; then
	KVER="$(sed -n 's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\(.*\)"/\1/p' "$KDEF" | head -n1)"
fi
if [ -z "$KVER" ] && [ -d "${ROOT}/upstream/buildroot-external" ]; then
	# Some HAOS versions set the kernel version in a shared fragment/board file.
	KVER="$(grep -rhos 'BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="[^"]*"' \
		"${ROOT}/upstream/buildroot-external/" 2>/dev/null \
		| sed -n 's/.*="\(.*\)"/\1/p' | head -n1)"
fi

if [ -n "$KVER" ]; then ok "target kernel: ${KVER}"; else
	warn "could not detect kernel version (submodule not checked out?) - kernel gates skipped"
fi
KMM="$(kmajmin "${KVER:-0.0}")"

# NVIDIA-specific gates (sections 2-3) only run for profiles that build NVIDIA.
if [ "$PROFILE" != "intel-amd" ]; then

# --- 2. NVIDIA driver <-> kernel ceiling (MAINTAIN THIS TABLE) ---------------
# Highest mainline kernel major.minor each driver BRANCH is known to build with
# using the OPEN modules. Conservative starting points - bump as you validate.
# These are maintainer heuristics, NOT authoritative NVIDIA data.
declare -A NV_MAX_KERNEL=(
	["535"]="6.5"
	["550"]="6.11"
	["560"]="6.12"
	["565"]="6.13"
	["570"]="6.14"
	["580"]="6.19"
	["595"]="6.20"
	["610"]="6.20"
)

NV_VER="$(sed -n 's/^[[:space:]]*default "\([0-9][0-9.]*\)".*/\1/p' \
	"${EXT}/package/haos-compute-nvidia/Config.in" | head -n1)"
if [ -n "$NV_VER" ]; then ok "pinned NVIDIA driver: ${NV_VER}"; else
	bad "could not read NVIDIA driver version from package Config.in"
fi

NV_BRANCH="${NV_VER%%.*}"
if [ -n "$KVER" ] && [ -n "${NV_MAX_KERNEL[$NV_BRANCH]:-}" ]; then
	maxk="${NV_MAX_KERNEL[$NV_BRANCH]}"
	if ver_le "$KMM" "$maxk"; then
		ok "kernel ${KMM} within NVIDIA ${NV_BRANCH} known-good ceiling (${maxk})"
	else
		msg="kernel ${KMM} EXCEEDS NVIDIA ${NV_BRANCH} ceiling (${maxk}) - bump the driver pin (e.g. 560/565) or the matrix"
		if [ "$NV_STRICT" = "1" ]; then bad "$msg"; else warn "$msg"; fi
	fi
elif [ -n "$KVER" ] && [ -n "$NV_BRANCH" ]; then
	warn "no matrix entry for NVIDIA branch ${NV_BRANCH}; add one to NV_MAX_KERNEL"
fi
note "open modules require a Turing (RTX 20xx / GTX 16xx) or newer GPU - not verifiable at build time"

# --- 3. Asset reachability (catch a typo'd version in seconds) ---------------
head_ok() { curl -fsIL --max-time 25 "$1" >/dev/null 2>&1; }

if [ -n "$NV_VER" ]; then
	NV_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NV_VER}/NVIDIA-Linux-x86_64-${NV_VER}.run"
	if head_ok "$NV_URL"; then ok "NVIDIA .run reachable"; else bad "NVIDIA .run NOT reachable: ${NV_URL}"; fi
fi

TK_VER="$(sed -n 's/^[[:space:]]*default "\([0-9][0-9.]*\)".*/\1/p' \
	"${EXT}/package/haos-nvidia-container-toolkit/Config.in" | head -n1)"
if [ -n "$TK_VER" ]; then
	# Asset name must match what the package actually fetches
	# (haos-nvidia-container-toolkit.mk): the amd64 tarball is the `_deb_amd64`
	# one; there is NO plain `_linux_amd64` asset (NVIDIA ships per-packaging
	# tarballs). Verified for v1.19.1: `_linux_amd64` 404s, `_deb_amd64` 200s.
	TK_URL="https://github.com/NVIDIA/nvidia-container-toolkit/releases/download/v${TK_VER}/nvidia-container-toolkit_${TK_VER}_deb_amd64.tar.gz"
	# Toolkit artifact naming has shifted between minors -> warn, don't hard-fail.
	if head_ok "$TK_URL"; then ok "container toolkit asset reachable"; else
		warn "toolkit asset NOT reachable (name/layout may differ for ${TK_VER}): ${TK_URL}"
	fi
fi

fi   # end NVIDIA-specific gates

# --- 4. Profile / Xe sanity --------------------------------------------------
case "$PROFILE" in
	all|intel-amd)
		# Both profiles enable the Intel Xe driver via the full kernel fragment.
		if [ -n "$KVER" ] && ! ver_le "6.8" "$KMM"; then
			bad "profile '${PROFILE}' needs CONFIG_DRM_XE but kernel ${KMM} predates Xe (~6.8) - drop Xe or use nvidia-amd"
		elif [ -n "$KVER" ]; then
			ok "kernel ${KMM} new enough for CONFIG_DRM_XE"
		fi ;;
	nvidia-amd)
		ok "profile 'nvidia-amd': Xe not required (smallest-surface target)" ;;
	*)
		bad "unknown profile '${PROFILE}' (use: all | nvidia-amd | intel-amd)" ;;
esac

echo "== preflight summary: ${fail_count} failure(s) =="
if [ "$fail_count" -gt 0 ] && [ "$STRICT" = "1" ]; then
	echo "Aborting before the expensive build. Override with STRICT=0 (not recommended)."
	exit 1
fi
exit 0
