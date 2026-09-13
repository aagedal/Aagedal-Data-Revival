#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: DATA_REVIVAL_BUILD_NUMBER=N DATA_REVIVAL_NOTARY_PROFILE=PROFILE $0 OUTPUT_DIRECTORY" >&2
    exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="$1"
release_version="${DATA_REVIVAL_RELEASE_VERSION:-1.0.0}"
marketing_version="${DATA_REVIVAL_MARKETING_VERSION:-1.0}"
build_number="${DATA_REVIVAL_BUILD_NUMBER:-}"
notary_profile="${DATA_REVIVAL_NOTARY_PROFILE:-}"
team_id="${DATA_REVIVAL_TEAM_ID:-3R5QGG9DW6}"
signing_identity="${DATA_REVIVAL_SIGNING_IDENTITY:-Developer ID Application}"
artifact_name="Aagedal-Data-Revival-${release_version}-macOS-arm64.zip"

if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: DATA_REVIVAL_RELEASE_VERSION must be a three-component semantic version" >&2
    exit 64
fi
if [[ ! "$marketing_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "error: DATA_REVIVAL_MARKETING_VERSION must be a two-component version" >&2
    exit 64
fi
if [[ "$release_version" != "$marketing_version".* ]]; then
    echo "error: release version $release_version does not match marketing version $marketing_version" >&2
    exit 64
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: DATA_REVIVAL_BUILD_NUMBER must be an explicit positive integer" >&2
    exit 64
fi
if [[ -z "$notary_profile" ]]; then
    echo "error: DATA_REVIVAL_NOTARY_PROFILE must name notarytool credentials stored in the keychain" >&2
    exit 64
fi
if [[ -n "$(/usr/bin/git -C "$repo_root" status --porcelain)" ]]; then
    echo "error: create a release candidate only from a clean checkout" >&2
    exit 1
fi
valid_identities="$(/usr/bin/security find-identity -v -p codesigning)"
if ! /usr/bin/grep -Fq "$signing_identity" <<< "$valid_identities"; then
    echo "error: no valid code-signing identity matches: $signing_identity" >&2
    exit 1
fi

configured_marketing_version="$(
    /usr/bin/xcodebuild \
        -project "$repo_root/Aagedal Data Revival.xcodeproj" \
        -scheme "Aagedal Data Revival" \
        -configuration Release \
        -showBuildSettings 2>/dev/null |
        /usr/bin/awk '/^[[:space:]]*MARKETING_VERSION = / { print $3; exit }'
)"
if [[ "$configured_marketing_version" != "$marketing_version" ]]; then
    echo "error: Release MARKETING_VERSION is $configured_marketing_version, expected $marketing_version" >&2
    exit 1
fi

/bin/mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
artifact="$output_directory/$artifact_name"
checksum="$artifact.sha256"
if [[ -e "$artifact" || -e "$checksum" ]]; then
    echo "error: refusing to overwrite an existing release artifact or checksum" >&2
    exit 1
fi

temporary_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/DataRevivalRelease.XXXXXX")"
cleanup() {
    local status=$?
    if [[ "${KEEP_RELEASE_WORK:-0}" == "1" ]]; then
        echo "preserved release work at $temporary_root"
    else
        /bin/rm -rf "$temporary_root"
    fi
    return "$status"
}
trap cleanup EXIT

engine_products="$temporary_root/RecoveryEngines"
archive_path="$temporary_root/Aagedal Data Revival.xcarchive"
export_directory="$temporary_root/Export"
export_options="$temporary_root/ExportOptions.plist"
submission_zip="$temporary_root/notarization-submission.zip"

"$repo_root/Scripts/build-recovery-engines.sh" "$engine_products"

/usr/bin/xcodebuild \
    -project "$repo_root/Aagedal Data Revival.xcodeproj" \
    -scheme "Aagedal Data Revival" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive_path" \
    RECOVERY_ENGINE_PRODUCTS_DIR="$engine_products" \
    CURRENT_PROJECT_VERSION="$build_number" \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$signing_identity" \
    archive

/usr/bin/plutil -create xml1 "$export_options"
/usr/bin/plutil -insert method -string developer-id "$export_options"
/usr/bin/plutil -insert signingStyle -string manual "$export_options"
/usr/bin/plutil -insert signingCertificate -string "$signing_identity" "$export_options"
/usr/bin/plutil -insert teamID -string "$team_id" "$export_options"

/usr/bin/xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_directory" \
    -exportOptionsPlist "$export_options"

app="$export_directory/Aagedal Data Revival.app"
if [[ ! -d "$app" ]]; then
    echo "error: exported application is missing: $app" >&2
    exit 1
fi
exported_marketing_version="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist"
)"
exported_build_number="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist"
)"
if [[ "$exported_marketing_version" != "$marketing_version" ||
      "$exported_build_number" != "$build_number" ]]; then
    echo "error: exported version is $exported_marketing_version ($exported_build_number), expected $marketing_version ($build_number)" >&2
    exit 1
fi

"$repo_root/Scripts/audit-app-bundle.sh" "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$submission_zip"
/usr/bin/xcrun notarytool submit "$submission_zip" \
    --keychain-profile "$notary_profile" \
    --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
"$repo_root/Scripts/audit-app-bundle.sh" "$app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app"

/usr/bin/ditto -c -k --keepParent "$app" "$artifact"
(
    cd "$output_directory"
    /usr/bin/shasum -a 256 "$artifact_name" > "$artifact_name.sha256"
)

echo "Release candidate created:"
echo "  $artifact"
echo "  $checksum"
echo "Record commit $(/usr/bin/git -C "$repo_root" rev-parse HEAD), build $build_number, and the command output in the release record."
