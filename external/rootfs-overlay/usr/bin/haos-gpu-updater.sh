#!/usr/bin/env bash
# =============================================================================
# haos-gpu-updater.sh
#
# Decoupled OTA path. Instead of trusting the HAOS Supervisor updater (which
# points at the official version server and would try to hand us a stock
# bundle), we pull OUR OWN signed .raucb from OUR GitHub Releases and install it
# with rauc. RAUC still enforces the custom `compatible` string and our keyring,
# so even if this script somehow fetched the wrong artifact it would be rejected.
#
# Portable on the HAOS host: uses only busybox-safe sed/awk (no `grep -P`, no
# assumption that jq/python exist). Runs from a daily systemd timer.
# =============================================================================
set -euo pipefail

REPO="${HAOS_GPU_UPDATE_REPO:-sam3gp8/haos-gpu-ai}"
RELEASES_API="https://api.github.com/repos/${REPO}/releases?per_page=100"

log() { echo "[haos-gpu-updater] $*"; }

# --- Running version + line pin -----------------------------------------------
# os-release VERSION looks like "17.3-gpu-ai-universal"; strip our suffix to the
# bare upstream version ("17.3") and take its MAJOR line ("17"). OTA is
# LINE-PINNED: a 17.x box only ever considers 17.x releases, an 18.x box only
# 18.x. This is what stops a running 17.3 box from installing an 18.x bundle
# just because it is the newest release - both lines share one GitHub Releases
# feed AND an identical RAUC `compatible` string, so without this pin the old
# `releases/latest` logic (and the `compatible` gate) would happily hand 18.x to
# a 17.x box. Stripping the suffix also fixes the up-to-date check: the release
# tag is "17.3", not "17.3-gpu-ai-universal", so the bare version must be
# compared or the box re-downloads its own running version every day.
running_raw="$(. /etc/os-release; echo "${VERSION:-unknown}")"
running_ver="${running_raw%%-*}"          # 17.3-gpu-ai-universal -> 17.3
running_major="${running_ver%%.*}"        # 17.3 -> 17
compat="$(sed -n 's/^compatible=\(.*\)$/\1/p' /etc/rauc/system.conf | tr -d '"' | head -n1)"
log "running version=${running_raw} (line ${running_major}.x) compatible=${compat}"

case "$running_major" in
	''|*[!0-9]*)
		log "cannot parse a numeric major line from '${running_raw}' - skipping"; exit 0 ;;
esac

# --- Pick the newest same-line, non-draft, non-prerelease release -------------
# Pull the whole releases feed (newest first) rather than /releases/latest,
# which ignores the line. Busybox-safe: `tr ',' '\n'` puts each JSON field on
# its own line, document order (newest first) preserved.
list="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$RELEASES_API")" || {
	log "release query failed - skipping"; exit 0; }

all_tags="$(printf '%s\n' "$list" | tr ',' '\n' \
	| sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "$all_tags" ] || { log "no releases found - skipping"; exit 0; }

cand=""; url=""
for t in $all_tags; do
	[ "${t%%.*}" = "$running_major" ] || continue      # line pin: same major only
	# Fetch this single release (one object parses exactly) and skip drafts /
	# prereleases, so marking a release prerelease still hides it from OTA.
	rel="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/${REPO}/releases/tags/${t}")" || continue
	printf '%s' "$rel" | grep -q '"draft"[[:space:]]*:[[:space:]]*true' && continue
	printf '%s' "$rel" | grep -q '"prerelease"[[:space:]]*:[[:space:]]*true' && continue
	url="$(printf '%s\n' "$rel" \
		| tr ',' '\n' \
		| sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\.raucb\)".*/\1/p' \
		| head -n1)"
	[ -n "$url" ] || continue
	cand="$t"; break
done

[ -n "$cand" ] || { log "no ${running_major}.x release with a .raucb asset - skipping"; exit 0; }

if [ "$cand" = "$running_ver" ]; then
	log "already up to date (${cand})"; exit 0
fi

log "update available on line ${running_major}.x: ${running_ver} -> ${cand}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log "downloading ${url}"
curl -fsSL -o "$tmp/update.raucb" "$url"

# Verify the bundle's compatible matches before installing.
if rauc info "$tmp/update.raucb" 2>/dev/null | grep -q "$compat"; then
	log "compatible verified; installing to inactive slot"
	rauc install "$tmp/update.raucb"
	log "install complete - reboot to activate the new slot"
else
	log "ERROR: bundle compatible mismatch or unreadable; refusing"
	exit 1
fi
