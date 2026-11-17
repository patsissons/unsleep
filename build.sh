#!/bin/zsh
# Build UnSleep.app into $APPDIR (default ~/Applications), with the unsleep CLI
# inside it at Contents/Helpers/unsleep, and symlink the CLI into $BINDIR
# (default ~/.local/bin). Set BINDIR= (empty) to skip the symlink, as the
# release workflow does; the Homebrew cask links the CLI itself.
set -euo pipefail

src_dir="$(cd "$(dirname "$0")" && pwd)"
app="${APPDIR:-$HOME/Applications}/UnSleep.app"
bindir="${BINDIR-$HOME/.local/bin}"
# Helpers/, not MacOS/: "unsleep" and "UnSleep" collide on case-insensitive
# volumes, and Helpers/ is where bundles keep command-line tools.
cli="$app/Contents/Helpers/unsleep"

# -Onone is deliberate: Swift 6.2.3 miscompiles script-mode top-level code
# under -O (spurious index/unwrap traps at runtime). These are tiny IO-bound
# tools; optimization buys nothing.
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
xcrun swiftc -Onone -o "$app/Contents/MacOS/UnSleep" "$src_dir/main.swift"
xcrun swiftc -Onone -o "$cli" "$src_dir/cli.swift"
cp "$src_dir/Info.plist" "$app/Contents/Info.plist"
cp "$src_dir/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
echo "Built $app"

if [[ -n "$bindir" ]]; then
  mkdir -p "$bindir"
  # -n replaces an existing link (or the regular file older versions installed).
  ln -sfn "$cli" "$bindir/unsleep"
  echo "Linked $bindir/unsleep -> $cli"
fi
