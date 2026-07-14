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
# Boundaries (still need a restart): adding a stored property or new type,
# changing class layout, or editing the C targets (libghostty, CPtySupport).
set -euo pipefail
cd "$(dirname "$0")"
exec swift run -Xlinker -interposable ghostling "$@"
