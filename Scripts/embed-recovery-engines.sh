#!/bin/bash

set -euo pipefail

required_environment=(
    SRCROOT
    TARGET_BUILD_DIR
    CONTENTS_FOLDER_PATH
    CONFIGURATION
)

for name in "${required_environment[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        echo "error: $name is required; run this script from the Xcode build phase" >&2
        exit 64
    fi
done

app_legal_destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/Legal"
/bin/mkdir -p "$app_legal_destination"
/usr/bin/install -m 0644 "$SRCROOT/LICENSE" \
    "$app_legal_destination/Aagedal-Data-Revival-LICENSE.txt"
/usr/bin/install -m 0644 "$SRCROOT/NOTICE" \
    "$app_legal_destination/Aagedal-Data-Revival-NOTICE.txt"

products_root="${RECOVERY_ENGINE_PRODUCTS_DIR:-$SRCROOT/Build/RecoveryEngines}"
source_helpers="$products_root/Helpers"
destination_helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
source_artifacts=(
    Licenses/PhotoRec-COPYING.txt
    Licenses/GNU-ddrescue-COPYING.txt
    Notices/PhotoRec-AUTHORS.txt
    Notices/GNU-ddrescue-AUTHORS.txt
    Notices/GNU-ddrescue-MODIFICATIONS.txt
    RecoveryEngines.lock.json
    SHA256SUMS
)
destination_artifacts="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/RecoveryEngines"
required_tools=(photorec ddrescue)

missing_tools=()
for tool in "${required_tools[@]}"; do
    if [[ ! -f "$source_helpers/$tool" || -L "$source_helpers/$tool" || ! -x "$source_helpers/$tool" ]]; then
        missing_tools+=("$tool")
    fi
done

photorec_archive_name="$(/usr/bin/plutil -extract engines.photorec.sourceArchiveName raw -o - "$SRCROOT/Configuration/RecoveryEngines.lock.json")"
ddrescue_archive_name="$(/usr/bin/plutil -extract engines.ddrescue.sourceArchiveName raw -o - "$SRCROOT/Configuration/RecoveryEngines.lock.json")"
ddrescue_patch_name="$(/usr/bin/plutil -extract engines.ddrescue.patches.0.fileName raw -o - "$SRCROOT/Configuration/RecoveryEngines.lock.json")"
source_artifacts+=(
    "SourceArchives/$photorec_archive_name"
    "SourceArchives/$ddrescue_archive_name"
    SourceBuildScripts/build-recovery-engines.sh
    "SourcePatches/$ddrescue_patch_name"
)

missing_artifacts=()
for artifact in "${source_artifacts[@]}"; do
    if [[ ! -f "$products_root/$artifact" || -L "$products_root/$artifact" ]]; then
        missing_artifacts+=("$artifact")
    fi
done

if (( ${#missing_tools[@]} > 0 || ${#missing_artifacts[@]} > 0 )); then
    if [[ "$CONFIGURATION" != "Release" ]]; then
        echo "warning: complete recovery-engine products are not built; Debug will use a development install when available"
        exit 0
    fi

    echo "error: Release requires complete pinned recovery-engine products at $products_root" >&2
    if (( ${#missing_tools[@]} > 0 )); then
        echo "error: missing regular executable(s): ${missing_tools[*]}" >&2
    fi
    if (( ${#missing_artifacts[@]} > 0 )); then
        echo "error: missing license/source artifact(s): ${missing_artifacts[*]}" >&2
    fi
    echo "error: run Scripts/build-recovery-engines.sh or set RECOVERY_ENGINE_PRODUCTS_DIR" >&2
    exit 1
fi

if ! /usr/bin/cmp -s \
    "$SRCROOT/Configuration/RecoveryEngines.lock.json" \
    "$products_root/RecoveryEngines.lock.json"; then
    echo "error: recovery-engine products were not built from the reviewed lockfile" >&2
    exit 1
fi

if ! (cd "$products_root" && /usr/bin/shasum -a 256 -c SHA256SUMS); then
    echo "error: recovery-engine product checksums do not match SHA256SUMS" >&2
    exit 1
fi

audit_binary() {
    local binary="$1"
    local architectures
    local dependency
    local rpath

    architectures="$(/usr/bin/lipo -archs "$binary")"
    if [[ "$architectures" != "arm64" ]]; then
        echo "error: recovery engine must contain exactly arm64: $binary ($architectures)" >&2
        exit 1
    fi

    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@executable_path/*|@loader_path/*|@rpath/*)
                ;;
            *)
                echo "error: recovery engine links to an external dependency: $binary ($dependency)" >&2
                exit 1
                ;;
        esac
    done < <(/usr/bin/otool -L "$binary" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')

    while IFS= read -r rpath; do
        [[ -z "$rpath" ]] && continue
        case "$rpath" in
            @executable_path/*|@loader_path/*)
                ;;
            *)
                echo "error: recovery engine contains an external runtime search path: $binary ($rpath)" >&2
                exit 1
                ;;
        esac
    done < <(/usr/bin/otool -l "$binary" | /usr/bin/awk '
        $1 == "cmd" && $2 == "LC_RPATH" { reading_rpath = 1; next }
        reading_rpath && $1 == "path" { print $2; reading_rpath = 0 }
    ')
}

for tool in "${required_tools[@]}"; do
    audit_binary "$source_helpers/$tool"
done

/bin/mkdir -p "$destination_helpers"
for tool in "${required_tools[@]}"; do
    destination="$destination_helpers/$tool"
    /usr/bin/install -m 0755 "$source_helpers/$tool" "$destination"

    if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
        signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
        signing_options=()
        if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
            signing_options+=(--options runtime)
        fi
        /usr/bin/codesign \
            --force \
            --sign "$signing_identity" \
            --timestamp=none \
            "${signing_options[@]}" \
            "$destination"
    fi
done

/bin/mkdir -p "$destination_artifacts"
for directory in Licenses Notices SourceArchives SourceBuildScripts SourcePatches; do
    /bin/mkdir -p "$destination_artifacts/$directory"
done
for artifact in "${source_artifacts[@]}"; do
    permissions=0644
    if [[ "$artifact" == SourceBuildScripts/* ]]; then
        permissions=0755
    fi
    /usr/bin/install -m "$permissions" "$products_root/$artifact" "$destination_artifacts/$artifact"
done

echo "Embedded pinned arm64 recovery engines and corresponding distribution artifacts"
