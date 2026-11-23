#!/usr/bin/env bash
# Test Sich the way a brand-new user meets it: on a clean macOS VM.
#
# Uses Tart (https://tart.run): a vanilla macOS image is pulled once, then every
# scenario boots a copy-on-write clone of it (seconds, ~no disk) and is thrown
# away afterwards — "docker run --rm" for macOS.
#
#   scripts/fresh-mac.sh base                 # one-time: pull the clean image (~24 GB)
#   scripts/fresh-mac.sh run bare             # nothing installed at all
#   scripts/fresh-mac.sh run claude           # Claude Code installed, not logged in
#   scripts/fresh-mac.sh run brew             # Homebrew + the README's `brew install --cask`
#   scripts/fresh-mac.sh run bare --dmg app/build/Sich-universal.dmg   # an unreleased build
#   scripts/fresh-mac.sh stop bare            # power off and delete that clone
#   scripts/fresh-mac.sh list
#
# Except in the brew scenario, the release DMG is downloaded INSIDE the VM and
# tagged with the quarantine flag a browser sets, so Gatekeeper, the drag to
# /Applications, and every first-launch prompt behave as they do for a real
# user. The VM window opens on your screen; the guest's login is admin/admin.
set -euo pipefail

TART="${TART:-tart}"
IMAGE="${FRESH_MAC_IMAGE:-ghcr.io/cirruslabs/macos-sequoia-vanilla:latest}"
BASE="sich-fresh-base"
REPO="roman-romanov-o/sich"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.artifacts/fresh-mac"

die() { echo "fresh-mac: $*" >&2; exit 1; }
vm_name() { echo "sich-fresh-$1"; }
# Vanilla images carry no Tart guest agent, so commands go over SSH with the
# image's stock admin/admin login (answered by SSH_ASKPASS, no extra tools).
guest() {
  local ip; ip="$("$TART" ip "$1")"
  SSH_ASKPASS="$WORK/askpass" SSH_ASKPASS_REQUIRE=force \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 "admin@$ip" "/bin/bash -lc $(printf %q "$2")"
}

wait_for_guest() {
  local vm="$1"
  for _ in $(seq 1 90); do
    guest "$vm" true >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "$vm did not come up (log: $WORK/$vm.log)"
}

cmd_base() {
  "$TART" list --quiet | grep -qx "$BASE" && { echo "$BASE already exists"; return; }
  "$TART" clone "$IMAGE" "$BASE"
  echo "base image ready: $BASE"
}

provision() {
  local vm="$1" scenario="$2"
  case "$scenario" in
    bare) ;;
    claude)
      guest "$vm" 'curl -fsSL https://claude.ai/install.sh | bash' ;;
    brew)
      guest "$vm" 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      guest "$vm" 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew install --cask '"$REPO"'' ;;
    *) die "unknown scenario '$scenario' (bare | claude | brew)" ;;
  esac
}

# Put the DMG in ~/Downloads exactly as a browser would leave it.
stage_dmg() {
  local vm="$1" dmg="$2"
  local quarantine='0081;$(printf %x $(date +%s));Safari;'
  if [ -n "$dmg" ]; then
    guest "$vm" "cp '/Volumes/My Shared Files/fresh-mac/$(basename "$dmg")' ~/Downloads/Sich.dmg"
  else
    guest "$vm" "curl -fsSL -o ~/Downloads/Sich.dmg https://github.com/$REPO/releases/latest/download/Sich-universal.dmg"
  fi
  guest "$vm" "xattr -w com.apple.quarantine \"$quarantine\" ~/Downloads/Sich.dmg && open ~/Downloads"
}

cmd_run() {
  local scenario="${1:-}" dmg=""
  [ -n "$scenario" ] || die "usage: run <bare|claude|brew> [--dmg path]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --dmg) dmg="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -z "$dmg" ] || [ -f "$dmg" ] || die "no such DMG: $dmg"
  "$TART" list --quiet | grep -qx "$BASE" || die "run '$0 base' first"

  local vm; vm="$(vm_name "$scenario")"
  "$TART" list --quiet | grep -qx "$vm" && die "$vm exists — '$0 stop $scenario' first"
  mkdir -p "$WORK/share"
  printf '#!/bin/sh\necho admin\n' >"$WORK/askpass" && chmod +x "$WORK/askpass"
  [ -z "$dmg" ] || cp "$dmg" "$WORK/share/"

  "$TART" clone "$BASE" "$vm"
  nohup "$TART" run --dir="fresh-mac:$WORK/share" "$vm" >"$WORK/$vm.log" 2>&1 &
  wait_for_guest "$vm"

  echo "provisioning '$scenario'…"
  provision "$vm" "$scenario"
  [ "$scenario" = brew ] || stage_dmg "$vm" "$dmg"

  cat <<EOF

$vm is up. In the VM window (login admin/admin):
  $( [ "$scenario" = brew ] && echo "Sich is in /Applications — open it from Launchpad." \
                               || echo "~/Downloads/Sich.dmg is quarantined like a browser download — open it and drag Sich to Applications." )
Note every prompt, dead end, and confusing screen. When done:  $0 stop $scenario
EOF
}

cmd_stop() {
  local vm; vm="$(vm_name "${1:?usage: stop <scenario>}")"
  "$TART" stop "$vm" 2>/dev/null || true
  "$TART" delete "$vm"
  echo "deleted $vm"
}

case "${1:-}" in
  base) cmd_base ;;
  run) shift; cmd_run "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  list) "$TART" list ;;
  *) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
