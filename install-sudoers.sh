#!/bin/zsh
# One-time setup: allow UnSleep to run its three exact pmset commands without
# a password. Run as:  sudo ./install-sudoers.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

user="${SUDO_USER:?could not determine invoking user}"
target=/etc/sudoers.d/unsleep
tmp="$(mktemp)"

cat > "$tmp" <<EOF
$user ALL=(root) NOPASSWD: /usr/bin/pmset -b sleep 0, /usr/bin/pmset -b disablesleep 1, /usr/bin/pmset -b disablesleep 0
EOF
chmod 440 "$tmp"
visudo -cf "$tmp"
mv "$tmp" "$target"

echo "Installed $target for user '$user'."
echo "UnSleep toggles are now password-free. Remove anytime: sudo rm $target"
