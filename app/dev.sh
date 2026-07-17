#!/usr/bin/env bash
# Dev runner for Ghostling with InjectionIII hot code swapping.
#
# `-Xlinker -interposable` lets InjectionIII swap pure-Swift (static-dispatch)
# method bodies live, not just @objc/dynamic ones. The app loads the injection
# bundle at launch (DevHotReload.enable(), DEBUG-only), so once this is running:
#
#   1. Launch InjectionIII.app (App Store or github.com/johnno1962/InjectionIII).
#   2. In it, "Select Directory" -> this `app/` folder.
#   3. Save any .swift file — its methods swap into the running process; the
#      live terminals / sessions / quota state survive the edit.
#
# If InjectionIII.app is not in /Applications or ~/Applications, set:
#
#   GHOSTLING_INJECTION_BUNDLE=/path/to/macOSInjection.bundle ./dev.sh
#
# Boundaries (still need a restart): adding a stored property or new type,
# changing class layout, or editing the C targets (libghostty, CPtySupport).
set -euo pipefail
cd "$(dirname "$0")"
export INJECTION_DIRECTORIES="${INJECTION_DIRECTORIES:-$PWD/Sources}"

if [ -z "${GHOSTLING_INJECTION_BUNDLE:-}" ]; then
  for app in "/Applications/InjectionIII.app" "$HOME/Applications/InjectionIII.app"; do
    if [ -d "$app" ]; then
      open -g "$app"
      break
    fi
  done
fi

for _ in 1 2 3 4 5; do
  [ -S /tmp/InjectionIII-control.sock ] && break
  sleep 0.2
done
if [ -S /tmp/InjectionIII-control.sock ]; then
  printf '{"action":"watch_project","path":"%s"}\n' "$PWD" | nc -U /tmp/InjectionIII-control.sock >/dev/null 2>&1 || true
fi

exec swift run -Xlinker -interposable ghostling "$@"
