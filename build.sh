#!/bin/zsh
# Build UnSleep.app into ~/Applications and the unsleep CLI into ~/.local/bin.
set -euo pipefail

src_dir="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/UnSleep.app"
cli="$HOME/.local/bin/unsleep"

# -Onone is deliberate: Swift 6.2.3 miscompiles script-mode top-level code
# under -O (spurious index/unwrap traps at runtime). These are tiny IO-bound
# tools; optimization buys nothing.
mkdir -p "$app/Contents/MacOS" "$(dirname "$cli")"
xcrun swiftc -Onone -o "$app/Contents/MacOS/UnSleep" "$src_dir/main.swift"
cp "$src_dir/Info.plist" "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp "$src_dir/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
xcrun swiftc -Onone -o "$cli" "$src_dir/cli.swift"

echo "Built $app"
echo "Built $cli"
