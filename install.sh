#!/usr/bin/env bash
#
# UnSleep installer: checks dependencies (offering to install any that are
# missing), downloads the source for a ref into a temporary directory, builds
# the app and CLI locally, and launches the menu bar app. No git or lasting
# checkout is needed.
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

INSTALL_REF="${UNSLEEP_INSTALL_REF:-main}"
TARBALL_URL="https://github.com/patsissons/unsleep/archive/${INSTALL_REF}.tar.gz"
MIN_MACOS_MAJOR=12
CLT_WAIT_SECS=3600

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }
ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
miss() { printf '    \033[1;31m✗\033[0m %s\n' "$*"; }

# Prompt through the terminal because stdin contains this script when invoked
# through the one-liner. Non-interactive runs decline prompts.
INTERACTIVE=0
if (exec < /dev/tty) 2>/dev/null; then INTERACTIVE=1; fi
confirm() {
    [ "${INTERACTIVE}" = "1" ] || return 1
    local reply=""
    printf '\033[1;35m??\033[0m  %s [y/N] ' "$1" > /dev/tty
    read -r reply < /dev/tty || reply=""
    case "${reply}" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# A file-backed invocation beside the sources builds the current checkout.
# Piped input has no script file and therefore downloads the source tarball.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
MODE="remote"
if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/main.swift" ] && [ -f "${SCRIPT_DIR}/build.sh" ]; then
    MODE="local"
fi

# --- Dependencies -----------------------------------------------------------
# macOS, curl and tar ship with the OS; only the Xcode Command Line Tools
# (swiftc) can be missing or broken on a stock Mac, so only they get offered.

# Sets CLT to ok, missing, devdir (developer dir is unusable) or license (Xcode
# license not accepted), and CLT_ERROR to xcrun's output. xcrun only runs once a
# developer dir exists so a missing toolchain can't pop up the macOS install
# dialog unasked.
CLT=""
CLT_ERROR=""
clt_state() {
    local dir
    CLT_ERROR=""
    if ! dir="$(xcode-select -p 2>/dev/null)"; then CLT="missing"; return; fi
    if [ ! -d "${dir}" ]; then CLT="devdir"; return; fi
    if CLT_ERROR="$(xcrun swiftc --version 2>&1)"; then CLT="ok"; return; fi
    case "${CLT_ERROR}" in *[Ll]icense*) CLT="license" ;; *) CLT="devdir" ;; esac
}

wait_for_clt() {
    local start="${SECONDS}" elapsed
    while clt_state; [ "${CLT}" != "ok" ]; do
        elapsed=$((SECONDS - start))
        if [ "${elapsed}" -ge "${CLT_WAIT_SECS}" ]; then
            printf '\n' > /dev/tty
            die "Timed out waiting for the Command Line Tools; re-run this installer once they finish."
        fi
        printf '\r    waiting for the Command Line Tools... %dm%02ds (Ctrl-C to abort)' \
            $((elapsed / 60)) $((elapsed % 60)) > /dev/tty
        sleep 5
    done
    printf '\n' > /dev/tty
}

install_clt() {
    warn "The Xcode Command Line Tools provide the Swift compiler UnSleep builds with."
    warn "They're a ~1-2 GB download; installing usually takes 5-20 minutes (longer on"
    warn "slow connections). macOS shows its own installer dialog."
    confirm "Install the Command Line Tools now?" \
        || die "Install them with 'xcode-select --install', then re-run this installer."
    xcode-select --install >/dev/null 2>&1 || true
    say "Follow the macOS installer dialog; this script continues once it finishes."
    wait_for_clt
}

fix_devdir() {
    warn "The active developer directory ($(xcode-select -p 2>/dev/null)) can't run swiftc."
    warn "Resetting it to the default takes a few seconds and asks for your password."
    confirm "Run 'sudo xcode-select --reset' now?" \
        || die "Run 'sudo xcode-select --reset' (or reinstall the Command Line Tools), then re-run this installer."
    sudo xcode-select --reset
}

accept_license() {
    warn "Xcode is the active developer directory, but its license hasn't been accepted."
    warn "Accepting it takes a few seconds and asks for your password."
    confirm "Run 'sudo xcodebuild -license accept' now?" \
        || die "Run 'sudo xcodebuild -license accept', then re-run this installer."
    sudo xcodebuild -license accept
}

say "Checking dependencies..."
[ "$(uname -s)" = "Darwin" ] || die "UnSleep is macOS only (found $(uname -s))."

FATAL=0
MACOS_VERSION="$(sw_vers -productVersion)"
if [ "${MACOS_VERSION%%.*}" -ge "${MIN_MACOS_MAJOR}" ]; then
    ok "macOS ${MACOS_VERSION} (needs ${MIN_MACOS_MAJOR}+)"
else
    miss "macOS ${MACOS_VERSION} (needs ${MIN_MACOS_MAJOR}+)"
    FATAL=1
fi
if [ "${MODE}" = "remote" ]; then
    if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
        ok "curl, tar"
    else
        miss "curl, tar (normally part of macOS)"
        FATAL=1
    fi
fi
clt_state
case "${CLT}" in
    ok)      ok "Xcode Command Line Tools (swiftc)" ;;
    missing) miss "Xcode Command Line Tools (not installed)" ;;
    devdir)  miss "Xcode Command Line Tools (developer directory can't run swiftc)" ;;
    license) miss "Xcode Command Line Tools (Xcode license not accepted)" ;;
esac
[ "${FATAL}" = "0" ] || die "UnSleep needs macOS ${MIN_MACOS_MAJOR} or later with curl and tar."

# Each fix can surface the next problem (e.g. resetting a stale Xcode path
# reveals that no tools are installed), so re-check after every step.
ATTEMPTS=0
while [ "${CLT}" != "ok" ]; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "${ATTEMPTS}" -le 3 ] || die "swiftc still doesn't work: ${CLT_ERROR:-unknown error}"
    case "${CLT}" in
        missing) install_clt ;;
        devdir)  fix_devdir ;;
        license) accept_license ;;
    esac
    clt_state
done
say "Dependencies OK."

# --- Source -----------------------------------------------------------------

if [ "${MODE}" = "local" ]; then
    SRC="${SCRIPT_DIR}"
    say "Using local checkout: ${SRC}"
else
    SRC="$(mktemp -d -t unsleep)"
    trap 'rm -rf "${SRC}"' EXIT
    say "Downloading UnSleep (${INSTALL_REF})..."
    curl -fsSL "${TARBALL_URL}" | tar -xz -C "${SRC}" --strip-components=1 \
        || die "Couldn't download ${TARBALL_URL}; check the ref and your connection."
    [ -f "${SRC}/main.swift" ] && [ -f "${SRC}/build.sh" ] \
        || die "The download for '${INSTALL_REF}' doesn't contain the UnSleep sources."
fi

# --- Install ----------------------------------------------------------------

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
"${SRC}/build.sh"

if [ "${RELAUNCH}" = "1" ]; then
    say "Launching UnSleep..."
    open -g "${HOME}/Applications/UnSleep.app"
fi

case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *)
        warn "~/.local/bin isn't on your PATH, so the unsleep command won't resolve yet."
        case "${SHELL:-}" in
            */bash) PROFILE="${HOME}/.bash_profile" ;;
            *)      PROFILE="${HOME}/.zprofile" ;;
        esac
        PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
        if grep -qsF "${PATH_LINE}" "${PROFILE}"; then
            warn "${PROFILE} already adds it; open a new terminal to pick it up."
        elif confirm "Add it to ${PROFILE} (takes effect in new terminals)?"; then
            printf '\n# Added by the UnSleep installer\n%s\n' "${PATH_LINE}" >> "${PROFILE}"
            say "Added to ${PROFILE}; open a new terminal or run: source ${PROFILE}"
        else
            warn "Add this to your shell profile:"
            warn "  ${PATH_LINE}"
        fi
        ;;
esac

say "Done — look for the ☀️ icon in the menu bar (near the clock)."
if [ "${MODE}" = "local" ]; then
    say "Password-free mode is optional; enable it from the app menu or with sudo ${SRC}/install-sudoers.sh."
else
    say "Password-free mode is optional; enable it from the app menu (Set Up Password-Free Mode…)."
fi
say "Smoke test: unsleep status"
