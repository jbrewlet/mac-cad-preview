#!/usr/bin/env bash
# Works out why the spacebar is not showing a CAD preview, and prints a report
# that can be pasted into a bug report.
#
#   ./doctor.sh                 check the install
#   ./doctor.sh part.step       check the file too
#
# Read-only. It does not change associations, quarantine, or the install.
set -euo pipefail

APP_NAME="Mac CAD Preview.app"
BUNDLE_ID="com.maccadpreview.quicklook"
QL_EXTENSION_POINT="com.apple.quicklook.preview"
SUPPORTED_EXTS="step stp stpz p21 iges igs stl 3mf nc tap md markdown"

APP=""
APPEX=""
PROBLEMS=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# The content types an extension bundle declares, one per line. PlistBuddy
# prints an array as indented lines wrapped in braces, so the wrapper lines
# and the indentation both have to go.
supported_types_of() {
    plist "$1/Contents/Info.plist" \
        'NSExtension:NSExtensionAttributes:QLSupportedContentTypes' |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
        grep -v -e '^$' -e '^Array' -e '^[{}]$' || true
}

usage() {
    cat <<'EOF'
Works out why the spacebar is not showing a CAD preview.

  ./doctor.sh                 check the install
  ./doctor.sh part.step       check the file too
EOF
}

find_app() {
    if [ -d "/Applications/$APP_NAME" ]; then
        APP="/Applications/$APP_NAME"
        return
    fi
    local found
    found="$(mdfind "kMDItemCFBundleIdentifier == 'com.maccadpreview'" 2>/dev/null | head -n 1 || true)"
    if [ -n "$found" ] && [ -d "$found" ]; then
        APP="$found"
        return
    fi
    bad "Mac CAD Preview is not in /Applications."
    note "Install from https://github.com/jbrewlet/mac-cad-preview/releases/latest"
}

check_machine() {
    say "Machine"
    local arch macos
    arch="$(uname -m)"
    macos="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    note "macOS $macos, $arch"
    if [ "$arch" != "arm64" ]; then
        bad "Apple Silicon only. Intel is not supported."
    else
        ok "Apple Silicon"
    fi
}

check_app() {
    say "Install"
    if [ -z "$APP" ]; then
        return
    fi
    APPEX="$APP/Contents/PlugIns/MacCADPreviewQL.appex"
    local version
    version="$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString || echo unknown)"
    ok "$APP ($version)"

    if [ ! -d "$APPEX" ]; then
        bad "Quick Look extension missing at $APPEX"
        return
    fi
    ok "Extension present"

    if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1 ||
       xattr -p com.apple.quarantine "$APPEX" >/dev/null 2>&1; then
        bad "Quarantined. macOS will not load the extension."
        note "xattr -dr com.apple.quarantine \"$APP\""
        note "open \"$APP\""
        note "Or System Settings → Privacy & Security → Open Anyway."
    else
        ok "Not quarantined"
    fi

    if codesign -d --entitlements - --xml "$APPEX" 2>/dev/null |
            plutil -extract 'com\\.apple\\.security\\.app-sandbox' raw - -o - 2>/dev/null |
            grep -q '^true$'; then
        ok "Extension is sandboxed"
    else
        bad "Extension is not sandboxed. PlugInKit will refuse it."
    fi
}

check_registration() {
    say "Registration"
    if [ -z "$APPEX" ]; then
        return
    fi
    local listing
    listing="$(pluginkit -m -i "$BUNDLE_ID" 2>/dev/null || true)"
    if [ -z "$listing" ]; then
        bad "pluginkit does not see the extension."
        note "open \"$APP\""
        note "Then System Settings → General → Login Items & Extensions → Quick Look"
        note "and enable Mac CAD Preview if it is listed and off."
        return
    fi
    ok "Registered"
    note "$listing"
    note "A leading + means enabled. A blank first column can still be registered."
}

check_types() {
    say "Types the extension handles"
    if [ -z "$APPEX" ]; then
        return
    fi
    local type
    while IFS= read -r type; do
        [ -n "$type" ] || continue
        note "$type"
    done < <(supported_types_of "$APPEX")
}

# Walk installed apps for exported UTIs tagged with our extensions, and flag
# any label the extension does not handle.
check_rival_claims() {
    say "Who claims the CAD extensions"
    if [ -z "$APPEX" ]; then
        return
    fi
    local handled
    handled="$(supported_types_of "$APPEX")"

    local plist_path id desc exts ext app_name
    while IFS= read -r plist_path; do
        [ -f "$plist_path" ] || continue
        local i=0
        while true; do
            id="$(plist "$plist_path" "UTExportedTypeDeclarations:$i:UTTypeIdentifier" || true)"
            [ -n "$id" ] || break
            exts="$(plist "$plist_path" "UTExportedTypeDeclarations:$i:UTTypeTagSpecification:public.filename-extension" 2>/dev/null || true)"
            app_name="$(plist "$plist_path" CFBundleName 2>/dev/null || basename "${plist_path%/Contents/Info.plist}")"
            for ext in $SUPPORTED_EXTS; do
                if printf '%s\n' "$exts" | grep -qiE "(^|[[:space:]])${ext}($|[[:space:]])" ||
                   printf '%s\n' "$exts" | grep -qiE "^[[:space:]]*${ext}[[:space:]]*$"; then
                    if printf '%s\n' "$handled" | grep -qxF "$id"; then
                        ok ".$ext    $id    $app_name"
                    else
                        bad ".$ext    $id    $app_name   — not handled"
                        note "Quick Look routes on this type, so spacebar never reaches us."
                    fi
                fi
            done
            i=$((i + 1))
        done
    done < <(find /Applications -maxdepth 3 -path '*.app/Contents/Info.plist' 2>/dev/null)
}

check_file() {
    local path="$1"
    say "File $path"
    if [ ! -f "$path" ]; then
        bad "File does not exist."
        return
    fi
    local size kind resolved ext
    size="$(stat -f '%z' "$path" 2>/dev/null || echo 0)"
    kind="$(file -b "$path" 2>/dev/null || echo unknown)"
    resolved="$(mdls -name kMDItemContentType -raw "$path" 2>/dev/null || true)"
    ext="${path##*.}"
    ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    note "$size bytes, $kind"
    note "macOS type: ${resolved:-unknown}"

    case "$kind" in
        *gzip*)
            bad "gzip compressed STEP is not handled."
            note "gunzip -c \"$path\" > uncompressed.step"
            ;;
    esac

    if [ -z "$APPEX" ]; then
        return
    fi
    local handled
    handled="$(supported_types_of "$APPEX")"
    if printf '%s\n' "$handled" | grep -qxF "$resolved"; then
        ok "Type $resolved is one the extension handles."
        note "If the spacebar still does nothing, the reason is in the log:"
        note "/usr/bin/log show --last 5m --predicate 'subsystem == \"com.maccadpreview\"'"
        return
    fi

    case " $SUPPORTED_EXTS " in
        *" $ext "*)
            if [[ "$resolved" == dyn.* ]]; then
                bad "macOS has not registered our type for .$ext (got $resolved)."
                note "open \"$APP\""
                note "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f \"$APP\""
            else
                bad "macOS calls this file \"$resolved\", which the extension does not handle."
                note "Another app has claimed this type. Open an issue with that line."
                report_rival_previewers "$resolved"
            fi
            ;;
        *)
            bad ".$ext is not a supported extension."
            note "Supported: $SUPPORTED_EXTS"
            ;;
    esac
}

report_rival_previewers() {
    local resolved="$1"
    local path
    while IFS= read -r path; do
        [ -d "$path" ] || continue
        [ "$path" != "$APPEX" ] || continue
        if supported_types_of "$path" | grep -qxF "$resolved"; then
            note "claimed by: $path"
        fi
    done < <(pluginkit -mvvv -p "$QL_EXTENSION_POINT" 2>/dev/null |
        awk '/path *=/ { print $NF }' || true)
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi

    printf 'Mac CAD Preview doctor\n\n'
    check_machine
    find_app
    check_app
    check_registration
    check_types
    check_rival_claims
    if [ $# -ge 1 ]; then
        check_file "$1"
    fi

    printf '\n'
    if [ "$PROBLEMS" -eq 0 ]; then
        say "No problems found."
        if [ $# -eq 0 ]; then
            note "Pass a file to check how macOS classifies it: ./doctor.sh part.step"
        fi
    else
        say "$PROBLEMS problem(s). Fixes are next to each ✗ above."
    fi
}

main "$@"
