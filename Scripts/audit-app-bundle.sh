#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/Aagedal\ Data\ Revival.app" >&2
    exit 64
fi

app="$1"
helpers="$app/Contents/Helpers"
bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
main_executable="$app/Contents/MacOS/$bundle_executable"
required_tools=(photorec ddrescue)

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
            @executable_path/*|@loader_path/*)
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

for tool in "${required_tools[@]}"; do
    binary="$helpers/$tool"
    if [[ ! -x "$binary" ]]; then
        echo "error: required bundled engine is missing or not executable: $binary" >&2
        exit 1
    fi

    audit_architecture "$binary"
    audit_dependencies "$binary"
    codesign --verify --strict --verbose=2 "$binary"
done

while IFS= read -r candidate; do
    if [[ "$(file "$candidate")" == *Mach-O* ]]; then
        audit_architecture "$candidate"
        audit_dependencies "$candidate"
        codesign --verify --strict --verbose=2 "$candidate"
    fi
done < <(find "$helpers" "$app/Contents/Frameworks" -type f 2>/dev/null || true)

codesign --verify --deep --strict --verbose=2 "$app"
echo "Bundle audit passed: recovery engines are bundled, signed, architecture-compatible, and free of non-system absolute dependencies."
