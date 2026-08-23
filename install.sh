#!/usr/bin/env bash
# Installs Mac CAD Preview: checks the machine can run it, gets the one
# dependency, builds from source, and puts the app in /Applications.
#
#   ./install.sh              install the most recent release
#   ./install.sh --ref main   install the latest development revision
#   ./install.sh --yes        do not ask before installing Homebrew
#
# It builds rather than downloading a finished app on purpose. There is no
# Apple Developer ID behind this project, so a downloaded app would be
# quarantined by macOS, and quarantined apps register their Quick Look
# extensions unreliably. Code compiled on the machine it runs on is never
# quarantined.
set -euo pipefail

REPO="https://github.com/jbrewlet/mac-cad-preview.git"
APP_NAME="Mac CAD Preview.app"
INSTALL_DIR="/Applications"
BUNDLE_ID="com.maccadpreview.quicklook"
MIN_MACOS_MAJOR=12

REF=""
ASSUME_YES=false
WORKDIR=""

usage() {
    cat <<'EOF'
Installs Mac CAD Preview: checks the machine can run it, gets the one
dependency, builds from source, and puts the app in /Applications.

  ./install.sh              install the most recent release
  ./install.sh --ref main   install the latest development revision
  ./install.sh --yes        do not ask before installing Homebrew
EOF
}

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Written as an if rather than a && chain: this runs on EXIT, and a trailing
# failed test would become the script's exit status.
cleanup() {
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

# Asking needs a terminal to read from. Piped into a shell with no tty, there
# is nothing to read, so the answer has to come from --yes instead.
confirm() {
    $ASSUME_YES && return 0
    [ -t 0 ] || return 1
    local reply
    printf '%s [y/N] ' "$1"
    read -r reply
    [[ "$reply" =~ ^[Yy] ]]
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --ref)
                [ $# -ge 2 ] || die "--ref needs a branch or tag"
                REF="$2"
                shift 2
                ;;
            --yes|-y)
                ASSUME_YES=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done
}

check_machine() {
    [ "$(uname -s)" = "Darwin" ] || die "this installs a macOS app, and this is not macOS"

    [ "$(uname -m)" = "arm64" ] || die \
        "Apple Silicon is required. Homebrew's OpenCASCADE is arm64 only, so there is nothing to build against on an Intel Mac."

    local version major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    [ "$major" -ge "$MIN_MACOS_MAJOR" ] || die \
        "macOS $MIN_MACOS_MAJOR or later is required, and this is macOS $version"

    # Running the whole thing as root would leave a root owned checkout and a
    # root owned Homebrew prefix behind.
    [ "$(id -u)" -ne 0 ] || die "do not run this with sudo; it will ask if it needs elevated rights"
}

# Command Line Tools, which supply git, clang and swiftc. Xcode is not needed.
check_command_line_tools() {
    local missing=()
    for tool in git clang++ swiftc; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [ ${#missing[@]} -eq 0 ] && return 0

    say "Command Line Tools are needed (missing: ${missing[*]})"
    if confirm "Open Apple's installer for them now?"; then
        xcode-select --install >/dev/null 2>&1 || true
        die "finish the Command Line Tools install, then run this again"
    fi
    die "install the Command Line Tools with: xcode-select --install"
}

ensure_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        # A default install puts brew here but only adds it to the PATH of new
        # login shells, so it can be present and still not on this PATH.
        if [ -x /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            say "Homebrew is needed to install OpenCASCADE, the one dependency"
            printf '    It is a package manager for macOS: https://brew.sh\n'
            confirm "Install Homebrew now?" || die \
                "install Homebrew from https://brew.sh, then run this again"
            /bin/bash -c \
                "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            [ -x /opt/homebrew/bin/brew ] || die "Homebrew install did not complete"
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
    fi

    if brew list --versions opencascade >/dev/null 2>&1; then
        say "OpenCASCADE is already installed"
    else
        say "Installing OpenCASCADE (this is a large download, give it a while)"
        brew install opencascade
    fi
}

fetch_source() {
    WORKDIR="$(mktemp -d)"
    say "Downloading the source"
    git clone --quiet "$REPO" "$WORKDIR/src"

    local target="$REF"
    if [ -z "$target" ]; then
        # Newest release tag, or main if the project has not tagged one yet.
        target="$(git -C "$WORKDIR/src" tag -l 'v*' --sort=-v:refname | head -n 1)"
        if [ -z "$target" ]; then
            warn "no release tag found, using the latest development revision"
            target="main"
        fi
    fi

    git -C "$WORKDIR/src" checkout --quiet "$target" ||
        die "no such branch or tag: $target"
    say "Building $target"
}

build_and_install() {
    ( cd "$WORKDIR/src" && ./build.sh )

    local built="$WORKDIR/src/build/$APP_NAME"
    [ -d "$built" ] || die "the build did not produce $APP_NAME"

    # /Applications is group writable by admins, so this usually needs no sudo.
    local sudo=""
    if [ ! -w "$INSTALL_DIR" ]; then
        say "$INSTALL_DIR needs elevated rights to write to"
        sudo="sudo"
    fi

    if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
        say "Replacing the copy already in $INSTALL_DIR"
        osascript -e "quit app \"${APP_NAME%.app}\"" >/dev/null 2>&1 || true
        $sudo rm -rf "$INSTALL_DIR/$APP_NAME"
    fi

    say "Installing to $INSTALL_DIR"
    $sudo mv "$built" "$INSTALL_DIR/"
}

# Launching the app once is what tells macOS the extension exists. The app has
# no other purpose, so it is closed again immediately.
register_extension() {
    say "Registering the Quick Look extension"
    open -a "$INSTALL_DIR/$APP_NAME"
    sleep 3
    osascript -e "quit app \"${APP_NAME%.app}\"" >/dev/null 2>&1 || true

    if pluginkit -m -i "$BUNDLE_ID" 2>/dev/null | grep -q .; then
        say "Registered"
    else
        warn "macOS is not reporting the extension yet. Open \"$APP_NAME\" from $INSTALL_DIR once by hand, then try a preview."
        warn "If that does not help, ./doctor.sh will say why."
    fi
}

main() {
    parse_args "$@"
    check_machine
    check_command_line_tools
    ensure_homebrew
    fetch_source
    build_and_install
    register_extension

    printf '\n'
    say "Done"
    printf 'Select a STEP, IGES, STL, 3MF, NC, TAP, Markdown, ZIP, RAR or 7z file in the Finder and press the spacebar.\n'
}

main "$@"
