#!/bin/bash
# Собирает Claude Limits.app вне рабочей копии (по умолчанию ~/.cache/claude-limits).
# С флагом --install копирует приложение в ~/Applications и запускает его.
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
out="${CLAUDE_LIMITS_BUILD_DIR:-$HOME/.cache/claude-limits}"
app="$out/Claude Limits.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$out/module-cache"
cp "$src/Resources/Info.plist" "$app/Contents/Info.plist"
swiftc -O -target "$(uname -m)-apple-macos13.0" "$src/Sources/main.swift" -o "$app/Contents/MacOS/ClaudeLimits" -framework Cocoa -module-cache-path "$out/module-cache"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/ClaudeLimits" --self-test
echo "Ready: $app"
if [ "${1:-}" = "--install" ]; then
    pkill -x ClaudeLimits || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Claude Limits.app"
    cp -R "$app" "$HOME/Applications/"
    open "$HOME/Applications/Claude Limits.app"
    echo "Installed: $HOME/Applications/Claude Limits.app"
fi
