#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/Aagedal\ Data\ Revival.app" >&2
    exit 64
fi

app="$1"
helpers="$app/Contents/Helpers"
engine_artifacts="$app/Contents/Resources/RecoveryEngines"
info_plist="$app/Contents/Info.plist"
bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
main_executable="$app/Contents/MacOS/$bundle_executable"
required_tools=(photorec ddrescue)

display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist")"
application_category="$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$info_plist")"
icon_file="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")"
if [[ "$display_name" != "Aagedal Data Revival" ||
      "$application_category" != "public.app-category.utilities" ||
      -z "$icon_file" ||
      ! -f "$app/Contents/Resources/${icon_file%.icns}.icns" ]]; then
    echo "error: application name, category, or production icon metadata is incomplete" >&2
    exit 1
fi

if [[ ! -x "$main_executable" ]]; then
    echo "error: app executable is missing: $main_executable" >&2
    exit 1
fi

app_architectures="$(lipo -archs "$main_executable")"
if [[ "$app_architectures" != "arm64" ]]; then
    echo "error: the 1.0 app must be arm64-only, found: $app_architectures" >&2
    exit 1
fi

audit_architecture() {
    local binary="$1"
    local architectures
    architectures="$(lipo -archs "$binary")"
    if [[ "$architectures" != "arm64" ]]; then
        echo "error: bundled native code must be arm64-only: $binary ($architectures)" >&2
        exit 1
    fi
}

audit_dependencies() {
    local binary="$1"
    local dependency
    local rpath

    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@executable_path/*|@loader_path/*|@rpath/*)
                ;;
            *)
                echo "error: $binary links to an external dependency: $dependency" >&2
                exit 1
                ;;
        esac
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')

    while IFS= read -r rpath; do
        [[ -z "$rpath" ]] && continue
        case "$rpath" in
            /usr/lib/swift|@executable_path/*|@loader_path/*)
                ;;
            *)
                echo "error: $binary contains an external runtime search path: $rpath" >&2
                exit 1
                ;;
        esac
    done < <(otool -l "$binary" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { reading_rpath = 1; next }
        reading_rpath && $1 == "path" { print $2; reading_rpath = 0 }
    ')
}

audit_signature() {
    local binary="$1"
    local signature_details
    local entitlements
    local forbidden_entitlement

    codesign --verify --strict --verbose=2 "$binary"
    signature_details="$(codesign -dvv "$binary" 2>&1)"
    if ! grep -q '^Authority=Developer ID Application:' <<< "$signature_details"; then
        echo "error: distribution code is not signed with a Developer ID Application identity: $binary" >&2
        exit 1
    fi
    if ! grep -Eq 'flags=.*\([^)]*runtime[^)]*\)' <<< "$signature_details"; then
        echo "error: hardened runtime is not enabled: $binary" >&2
        exit 1
    fi

    entitlements="$(codesign -d --entitlements - "$binary" 2>&1)"
    for forbidden_entitlement in \
        com.apple.security.get-task-allow \
        com.apple.security.cs.allow-jit \
        com.apple.security.cs.allow-unsigned-executable-memory \
        com.apple.security.cs.disable-executable-page-protection \
        com.apple.security.cs.disable-library-validation
    do
        if grep -Fq "$forbidden_entitlement" <<< "$entitlements"; then
            echo "error: distribution code has forbidden entitlement $forbidden_entitlement: $binary" >&2
            exit 1
        fi
    done
}

if [[ -e "$app/Contents/MacOS/DataRevivalImagingHelper" ||
      -e "$app/Contents/Library/LaunchDaemons/com.aagedal.DataRevival.ImagingHelper.plist" ]]; then
    echo "error: obsolete privileged imaging-helper payload is present" >&2
    exit 1
fi

for tool in "${required_tools[@]}"; do
    binary="$helpers/$tool"
    if [[ ! -x "$binary" ]]; then
        echo "error: required bundled engine is missing or not executable: $binary" >&2
        exit 1
    fi

    audit_architecture "$binary"
    audit_dependencies "$binary"
    audit_signature "$binary"
done

if [[ ! -f "$engine_artifacts/RecoveryEngines.lock.json" || -L "$engine_artifacts/RecoveryEngines.lock.json" ]]; then
    echo "error: recovery-engine lockfile is missing from the app resources" >&2
    exit 1
fi

photorec_archive_name="$(/usr/bin/plutil -extract engines.photorec.sourceArchiveName raw -o - "$engine_artifacts/RecoveryEngines.lock.json")"
ddrescue_archive_name="$(/usr/bin/plutil -extract engines.ddrescue.sourceArchiveName raw -o - "$engine_artifacts/RecoveryEngines.lock.json")"
ddrescue_patch_name="$(/usr/bin/plutil -extract engines.ddrescue.patches.0.fileName raw -o - "$engine_artifacts/RecoveryEngines.lock.json")"
required_artifacts=(
    Licenses/PhotoRec-COPYING.txt
    Licenses/GNU-ddrescue-COPYING.txt
    Notices/PhotoRec-AUTHORS.txt
    Notices/GNU-ddrescue-AUTHORS.txt
    Notices/GNU-ddrescue-MODIFICATIONS.txt
    RecoveryEngines.lock.json
    SHA256SUMS
    "SourceArchives/$photorec_archive_name"
    "SourceArchives/$ddrescue_archive_name"
    SourceBuildScripts/build-recovery-engines.sh
    "SourcePatches/$ddrescue_patch_name"
)
for artifact in "${required_artifacts[@]}"; do
    if [[ ! -f "$engine_artifacts/$artifact" || -L "$engine_artifacts/$artifact" ]]; then
        echo "error: required recovery-engine distribution artifact is missing: $artifact" >&2
        exit 1
    fi
done

while read -r expected relative_path; do
    relative_path="${relative_path#\*}"
    case "$relative_path" in
        Helpers/*)
            # Signing adds a Mach-O code-signature load command, so the shipped
            # executable cannot retain its pre-sign reproducible-build digest.
            # The loop above verifies signed code; SHA256SUMS retains its
            # original build-product digest for provenance.
            continue
            ;;
        *)
            packaged_path="$engine_artifacts/$relative_path"
            ;;
    esac
    actual="$(/usr/bin/shasum -a 256 "$packaged_path" | /usr/bin/awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "error: packaged recovery-engine artifact checksum mismatch: $relative_path" >&2
        exit 1
    fi
done < "$engine_artifacts/SHA256SUMS"

while IFS= read -r candidate; do
    if [[ "$(file "$candidate")" == *Mach-O* ]]; then
        audit_architecture "$candidate"
        audit_dependencies "$candidate"
        audit_signature "$candidate"
    fi
done < <(find "$helpers" "$app/Contents/Frameworks" -type f 2>/dev/null || true)

codesign --verify --deep --strict --verbose=2 "$app"
audit_signature "$app"
echo "Bundle audit passed: hardened signed code, recovery engines, and checksum-verified distribution artifacts are complete."
