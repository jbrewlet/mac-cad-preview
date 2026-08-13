#!/usr/bin/env bash
# Works out why the spacebar is not showing a CAD preview, and prints a report
# that can be pasted into a bug report.
#
#   ./doctor.sh                 check the install
#   ./doctor.sh part.step       check the install and that one file
#
# Read only: it inspects and reports, and never changes anything. Every problem
# it finds is printed with the command that fixes it, to run by hand.
set -euo pipefail

APP_NAME="Mac CAD Preview.app"
APP_BUNDLE_ID="com.maccadpreview"
EXT_BUNDLE_ID="com.maccadpreview.quicklook"
QL_EXTENSION_POINT="com.apple.quicklook.preview"
MIN_MACOS_MAJOR=12
SUPPORTED_EXTENSIONS="step stp stpz p21 iges igs stl 3mf"

APP=""            # the app bundle we are diagnosing, once found
APPEX=""
QL_TYPES=()       # content types the installed extension says it handles
PROBLEMS=()       # each entry: one line of what is wrong, then how to fix it

usage() {
    cat <<'EOF'
Works out why the spacebar is not showing a CAD preview.

  ./doctor.sh                 check the install
  ./doctor.sh part.step       check the install and that one file

It only reads; nothing is changed. Paste the output into a bug report at
https://github.com/jbrewlet/mac-cad-preview/issues
EOF
}

say()     { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()      { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad()     { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
note()    { printf '    %s\n' "$*"; }
problem() { PROBLEMS+=("$1"$'\n'"$2"); bad "$1"; }

# PlistBuddy is the only plist reader guaranteed to be on a stock macOS, and it
# exits non-zero for a missing key, which is a normal answer here rather than a
# failure.
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# The content types an extension bundle declares, one per line. PlistBuddy
# prints an array as indented lines wrapped in braces, so the wrapper lines and
# the indentation both have to go.
supported_types_of() {
    plist "$1/Contents/Info.plist" \
        'NSExtension:NSExtensionAttributes:QLSupportedContentTypes' |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
        grep -v -e '^$' -e '^Array' -e '^[{}]$'
}

# ---------------------------------------------------------------- the machine

check_machine() {
    say "This Mac"

    local product build arch major
    product="$(sw_vers -productVersion)"
    build="$(sw_vers -buildVersion)"
    arch="$(uname -m)"
    major="${product%%.*}"

    note "macOS $product ($build), $arch"

    if [ "$major" -lt "$MIN_MACOS_MAJOR" ]; then
        problem "macOS $MIN_MACOS_MAJOR or later is required, and this is macOS $product." \
            "Update macOS."
    fi

    # An arm64-only binary does not run on Intel at all: the app will not launch
    # and the extension can never load, which looks exactly like the spacebar
    # doing nothing.
    if [ "$arch" != "arm64" ]; then
        problem "This is an Intel Mac ($arch), which is not supported." \
            "There is no fix. Mac CAD Preview is built arm64 only, so it cannot run here."
    else
        ok "Apple Silicon, macOS $product"
    fi
}

# ------------------------------------------------------------------- the app

# Looks in /Applications first because that is where it belongs, then asks
# Spotlight, so a copy left in Downloads is found and named as the problem.
find_app() {
    say "The app"

    local candidate
    for candidate in "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"; do
        if [ -d "$candidate" ]; then
            APP="$candidate"
            break
        fi
    done

    if [ -z "$APP" ]; then
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            APP="$candidate"
            break
        done < <(mdfind "kMDItemCFBundleIdentifier == '$APP_BUNDLE_ID'" 2>/dev/null)
    fi

    if [ -z "$APP" ]; then
        problem "Mac CAD Preview is not installed anywhere this can find." \
            "Install it: https://github.com/jbrewlet/mac-cad-preview#install"
        return
    fi

    local version
    version="$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString)"
    note "$APP"
    note "version ${version:-unknown}"

    case "$APP" in
        /Applications/*|"$HOME"/Applications/*)
            ok "Installed in an Applications folder"
            ;;
        *)
            # macOS does not scan arbitrary folders for app extensions.
            problem "The app is not in an Applications folder, so macOS will not load its extension." \
                "Move it: mv \"$APP\" /Applications/"
            ;;
    esac

    APPEX="$APP/Contents/PlugIns/MacCADPreviewQL.appex"
    if [ -d "$APPEX" ]; then
        ok "Contains the Quick Look extension"
    else
        problem "The app bundle has no Quick Look extension inside it." \
            "The copy is damaged. Download it again, or build from source."
        APPEX=""
    fi
}

check_quarantine() {
    [ -n "$APP" ] || return 0
    say "Gatekeeper"

    # A quarantined app is not allowed to load its Quick Look extension, and
    # this is the single most common cause of a dead spacebar.
    if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
        problem "The app is still quarantined, so macOS will not load its extension." \
            "Approve it under System Settings → Privacy & Security → Open Anyway, or run:
  xattr -dr com.apple.quarantine \"$APP\" && open \"$APP\""
    else
        ok "Not quarantined"
    fi

    if codesign --verify --strict "$APP" >/dev/null 2>&1; then
        ok "Signature is intact"
    else
        problem "The app's signature does not verify, so macOS will refuse to load the extension." \
            "Something modified the bundle after it was built. Install it again."
    fi

    if [ -n "$APPEX" ]; then
        # PlugInKit silently refuses to register a Quick Look extension that is
        # not sandboxed, which is a re-signing accident rather than a user one.
        # plutil reads a dot as a key path separator, so the dots in the
        # entitlement's own name have to be escaped.
        if codesign -d --entitlements - --xml "$APPEX" 2>/dev/null |
                plutil -extract 'com\.apple\.security\.app-sandbox' raw - -o - 2>/dev/null |
                grep -q '^true$'; then
            ok "The extension is sandboxed, as macOS requires"
        else
            problem "The extension is missing the sandbox entitlement, so macOS will not register it." \
                "It was re-signed without its entitlements. Install it again."
        fi
    fi
}

# ------------------------------------------------------------- registration

check_registration() {
    say "Registration with macOS"

    local line state
    line="$(pluginkit -m -i "$EXT_BUNDLE_ID" 2>/dev/null | head -n 1)"

    if [ -z "$line" ]; then
        problem "macOS is not aware of the extension at all." \
            "Open the app once — that is what registers it:
  open \"${APP:-/Applications/$APP_NAME}\""
        return
    fi

    # Column one is the state: + enabled, - disabled, blank means neither, which
    # is the normal state for an extension nobody has touched, and it is used.
    state="${line:0:1}"
    case "$state" in
        -)
            problem "The extension is registered but switched off." \
                "Turn it on under System Settings → General → Login Items & Extensions → Quick Look, or run:
  pluginkit -e use -i $EXT_BUNDLE_ID"
            ;;
        +)
            ok "Registered and enabled"
            ;;
        *)
            ok "Registered"
            ;;
    esac

    # A registration pointing at a bundle that has moved is stale, and macOS
    # keeps reporting the old path until Launch Services is told otherwise.
    local registered_path
    registered_path="$(pluginkit -mvvv -i "$EXT_BUNDLE_ID" 2>/dev/null |
        awk -F' = ' '/Path = /{print $2; exit}')"
    note "registered at ${registered_path:-unknown}"

    if [ -n "$APPEX" ] && [ -n "$registered_path" ] && [ "$registered_path" != "$APPEX" ]; then
        problem "macOS has the extension registered at a path that is not where the app is now." \
            "Re-register it:
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f \"$APP\""
    fi
}

# The extension only ever gets asked about the content types it declares, so
# these are what every file has to match.
read_supported_types() {
    [ -n "$APPEX" ] || return 0

    local type
    while IFS= read -r type; do
        QL_TYPES+=("$type")
    done < <(supported_types_of "$APPEX")

    say "Types the extension handles"
    if [ ${#QL_TYPES[@]} -eq 0 ]; then
        problem "The extension declares no content types, so Quick Look will never call it." \
            "The copy is damaged. Install it again."
        return
    fi
    for type in "${QL_TYPES[@]}"; do
        note "$type"
    done
}

# ------------------------------------------------------------------- a file

# Quick Look routes on the file's content type, not its name. If macOS resolved
# a .step file to some other app's type, our extension is never asked, and the
# spacebar does nothing at all — no error, no blank panel.
check_file() {
    local file="$1"
    say "The file: $file"

    if [ ! -f "$file" ]; then
        bad "No such file"
        return
    fi

    note "$(du -h "$file" | cut -f1) — $(file -b "$file")"

    # Some CAD tools write gzip into a plain .step name. That is a known
    # limitation, and it fails with a message rather than silently.
    if file -b "$file" | grep -qi 'gzip compressed'; then
        problem "$file is gzip compressed, which is not supported yet." \
            "Re-export it uncompressed, or decompress it:
  gunzip -c \"$file\" > \"${file%.*}-plain.${file##*.}\""
    fi

    local resolved tree
    resolved="$(mdls -name kMDItemContentType -raw "$file" 2>/dev/null)"
    tree="$(mdls -name kMDItemContentTypeTree -raw "$file" 2>/dev/null |
        tr -d '(),"' | tr -s ' \n' '\n' | sed '/^$/d')"

    note "macOS calls this a: ${resolved:-unknown}"

    [ ${#QL_TYPES[@]} -gt 0 ] || return 0

    local matched="" candidate declared
    while IFS= read -r candidate; do
        for declared in "${QL_TYPES[@]}"; do
            if [ "$candidate" = "$declared" ]; then
                matched="$candidate"
                break 2
            fi
        done
    done <<< "$tree"

    if [ -n "$matched" ]; then
        ok "Matches the extension's type $matched"
        # Everything lines up, so anything still wrong is in the preview itself
        # rather than in the routing, and the log will say what.
        note "If the spacebar still does nothing, the reason will be in the log:"
        note "  /usr/bin/log show --last 5m --predicate 'subsystem == \"com.maccadpreview\"'"
        return
    fi

    local extension
    extension="$(printf '%s' "${file##*.}" | tr '[:upper:]' '[:lower:]')"

    if ! grep -qw "$extension" <<< "$SUPPORTED_EXTENSIONS"; then
        bad "A .$extension file is not a format Mac CAD Preview handles."
        note "supported: $SUPPORTED_EXTENSIONS"
        return
    fi

    case "$resolved" in
        dyn.*|"")
            # A dyn. type is macOS saying nothing on this Mac claims the
            # extension — including us, so our own type declarations, which the
            # app registers when it is opened, never took effect.
            problem "macOS does not recognise .$extension files at all, so Quick Look has nothing to route to the extension." \
                "The app registers the file types when it is opened, and that has not happened.
  Open it once:
    open \"${APP:-/Applications/$APP_NAME}\"
  If that does not help, re-register it:
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f \"${APP:-/Applications/$APP_NAME}\""
            ;;
        *)
            problem "macOS calls this file \"$resolved\", which the extension does not handle, so Quick Look never asks it." \
                "Another app has claimed .$extension on this Mac. Report the type above at
    https://github.com/jbrewlet/mac-cad-preview/issues — it has to be added to the extension."
            report_rival_previewers "$resolved"
            ;;
    esac
}

# Names whichever other extension claimed the type, since that is the thing to
# uninstall or report, and it cannot be guessed from the outside.
report_rival_previewers() {
    local resolved="$1"
    [ -n "$resolved" ] || return 0

    local path
    while IFS= read -r path; do
        [ -d "$path" ] || continue
        [ "$path" != "$APPEX" ] || continue
        if supported_types_of "$path" | grep -qxF "$resolved"; then
            note "claimed by: $path"
        fi
    done < <(pluginkit -mvvv -p "$QL_EXTENSION_POINT" 2>/dev/null |
        awk -F' = ' '/Path = /{print $2}')
}

# --------------------------------------------------------------------- logs

show_recent_log() {
    say "What the extension logged recently"

    local output
    # /usr/bin/log by path: log is also a zsh builtin.
    output="$(/usr/bin/log show --style compact --last 30m \
        --predicate 'subsystem == "com.maccadpreview"' 2>/dev/null |
        grep -v '^Timestamp' | tail -n 20 || true)"

    if [ -n "$output" ]; then
        printf '%s\n' "$output" | sed 's/^/    /'
    else
        note "nothing in the last 30 minutes"
        note "(the extension only logs when it actually runs, so silence here"
        note " means Quick Look never started it)"
    fi
}

# ------------------------------------------------------------------ verdict

summarise() {
    say "Verdict"

    if [ ${#PROBLEMS[@]} -eq 0 ]; then
        ok "Nothing wrong found."
        note "If previews still do not appear, restart Quick Look and the Finder:"
        note "  qlmanage -r && qlmanage -r cache && killall Finder"
        note "then open an issue with this report:"
        note "  https://github.com/jbrewlet/mac-cad-preview/issues"
        return
    fi

    printf '  %s to fix:\n' "$(
        [ ${#PROBLEMS[@]} -eq 1 ] && echo '1 thing' || echo "${#PROBLEMS[@]} things"
    )"

    local index=1 entry
    for entry in "${PROBLEMS[@]}"; do
        printf '\n  %d. %s\n' "$index" "${entry%%$'\n'*}"
        # The fix can run to several lines, so indent all of them, not just the
        # first, or the continuation reads as part of the next problem.
        printf '%s\n' "${entry#*$'\n'}" | sed 's/^/     /'
        index=$((index + 1))
    done
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac

    [ "$(uname -s)" = "Darwin" ] || {
        printf 'error: this checks a macOS app, and this is not macOS\n' >&2
        exit 1
    }

    printf '\033[1mMac CAD Preview — diagnostics\033[0m\n'

    check_machine
    find_app
    check_quarantine
    check_registration
    read_supported_types

    if [ $# -gt 0 ]; then
        local file
        for file in "$@"; do
            check_file "$file"
        done
    else
        say "No file given"
        note "Pass one to check how macOS classifies it, which is what decides"
        note "whether Quick Look asks this extension at all:"
        note "  ./doctor.sh yourpart.step"
    fi

    show_recent_log
    summarise
    printf '\n'
}

main "$@"
