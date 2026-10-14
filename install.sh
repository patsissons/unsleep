#!/usr/bin/env bash
#
# UnSleep source installer: clones (or updates) the repo, builds the app and
# CLI locally, and launches the menu bar app.
#
# Install or update:
#   curl -fsSL https://raw.githubusercontent.com/patsissons/unsleep/main/install.sh | bash
#
# Install from a local checkout:
#   ./install.sh
#
# Pin or roll back to a tag/branch/sha:
#   ... | UNSLEEP_INSTALL_REF=<ref> bash
set -euo pipefail

REPO_URL="https://github.com/patsissons/unsleep.git"
INSTALL_REF="${UNSLEEP_INSTALL_REF:-main}"
CHECKOUT="${UNSLEEP_HOME:-$HOME/src/github.com/patsissons/unsleep}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# Prompt through the terminal because stdin contains this script when invoked
# through the one-liner. Non-interactive runs decline prompts.
INTERACTIVE=0
[ -e /dev/tty ] && INTERACTIVE=1
confirm() {
    [ "${INTERACTIVE}" = "1" ] || return 1
    local reply=""
    printf '\033[1;35m??\033[0m  %s [y/N] ' "$1" > /dev/tty
    read -r reply < /dev/tty || reply=""
    case "${reply}" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# A file-backed invocation beside the sources builds the current checkout.
# Piped input has no script file and therefore clones (or updates) the repo.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
MODE="clone"
if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/main.swift" ] && [ -f "${SCRIPT_DIR}/build.sh" ]; then
    MODE="local"
fi

say "Checking prerequisites..."
[ "$(uname -s)" = "Darwin" ] || die "UnSleep is macOS only (found $(uname -s))."
if ! xcrun --find swiftc >/dev/null 2>&1; then
    warn "The Swift toolchain (Xcode Command Line Tools) is missing."
    if confirm "Run 'xcode-select --install' now?"; then
        xcode-select --install || true
        die "Re-run this installer once the Command Line Tools finish installing."
    fi
    die "Install the Command Line Tools (xcode-select --install), then re-run."
fi
if [ "${MODE}" = "clone" ]; then
    command -v git >/dev/null 2>&1 || die "git is required."
fi
say "Prerequisites OK."

if [ "${MODE}" = "local" ]; then
    CHECKOUT="${SCRIPT_DIR}"
    say "Using local checkout: ${CHECKOUT}"
elif [ -d "${CHECKOUT}/.git" ]; then
    say "Updating ${CHECKOUT} (${INSTALL_REF})..."
    [ -z "$(git -C "${CHECKOUT}" status --porcelain)" ] \
        || die "Checkout has local changes; commit/stash them or remove ${CHECKOUT}."
    git -C "${CHECKOUT}" fetch -q origin "${INSTALL_REF}"
    git -C "${CHECKOUT}" checkout -q --detach FETCH_HEAD
else
    say "Cloning ${REPO_URL} to ${CHECKOUT}..."
    mkdir -p "$(dirname "${CHECKOUT}")"
    git clone --quiet "${REPO_URL}" "${CHECKOUT}"
    if [ "${INSTALL_REF}" != "main" ]; then
        git -C "${CHECKOUT}" fetch -q origin "${INSTALL_REF}"
        git -C "${CHECKOUT}" checkout -q --detach FETCH_HEAD
    fi
fi

# Don't silently kill an active keep-awake session mid-update.
RELAUNCH=1
if pgrep -f "UnSleep.app/Contents/MacOS" >/dev/null 2>&1; then
    STATUS="$("${HOME}/.local/bin/unsleep" status 2>/dev/null || echo off)"
    case "${STATUS}" in
        on*)
            warn "UnSleep is currently keeping your Mac awake (${STATUS})."
            if confirm "Restart it to finish updating (this restores sleep settings)?"; then
                osascript -e 'quit app "UnSleep"' >/dev/null 2>&1 || true
                sleep 1
            else
                warn "Skipping restart; the previous version keeps running until you restart it:"
                warn "  osascript -e 'quit app \"UnSleep\"'; open -g ~/Applications/UnSleep.app"
                RELAUNCH=0
            fi
            ;;
        *)
            osascript -e 'quit app "UnSleep"' >/dev/null 2>&1 || true
            sleep 1
            ;;
    esac
fi

say "Building..."
"${CHECKOUT}/build.sh"

if [ "${RELAUNCH}" = "1" ]; then
    say "Launching UnSleep..."
    open -g "${HOME}/Applications/UnSleep.app"
fi

case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *)
        warn "~/.local/bin isn't on your PATH; the unsleep CLI won't resolve. Add:"
        warn '  export PATH="$HOME/.local/bin:$PATH"'
        ;;
esac

say "Done — look for the 🌙 icon in the menu bar (near the clock)."
say "Password-free mode is optional; enable it from the app menu or with sudo ${CHECKOUT}/install-sudoers.sh."
say "Smoke test: unsleep status"
