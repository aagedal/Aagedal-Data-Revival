#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$repo_root/Configuration/RecoveryEngines.lock.json"
output_root="${1:-$repo_root/Build/RecoveryEngines}"
source_cache="${DATA_REVIVAL_ENGINE_SOURCE_CACHE:-$repo_root/Build/RecoveryEngineSources}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "error: recovery engines must be built natively on an Apple silicon Mac" >&2
    exit 1
fi
if [[ -e "$output_root" ]]; then
    echo "error: output already exists; choose a new path or remove it first: $output_root" >&2
    exit 1
fi

read_manifest() {
    /usr/bin/plutil -extract "$1" raw -o - "$manifest"
}

target_architecture="$(read_manifest target.architecture)"
minimum_macos="$(read_manifest target.minimumMacOS)"
photorec_version="$(read_manifest engines.photorec.version)"
photorec_archive_name="$(read_manifest engines.photorec.sourceArchiveName)"
photorec_url="$(read_manifest engines.photorec.sourceURL)"
photorec_sha256="$(read_manifest engines.photorec.sourceSHA256)"
ddrescue_version="$(read_manifest engines.ddrescue.version)"
ddrescue_archive_name="$(read_manifest engines.ddrescue.sourceArchiveName)"
ddrescue_url="$(read_manifest engines.ddrescue.sourceURL)"
ddrescue_sha256="$(read_manifest engines.ddrescue.sourceSHA256)"

if [[ "$target_architecture" != "arm64" ]]; then
    echo "error: the 1.0 engine manifest must target arm64" >&2
    exit 1
fi

mkdir -p "$source_cache" "$(dirname "$output_root")"

fetch_source() {
    local url="$1"
    local expected_sha256="$2"
    local destination="$3"
    local partial="$destination.partial"

    if [[ -f "$destination" ]] && echo "$expected_sha256  $destination" | shasum -a 256 -c - >/dev/null; then
        return
    fi

    rm -f "$partial"
    /usr/bin/curl --fail --location --proto '=https' "$url" --output "$partial"
    echo "$expected_sha256  $partial" | shasum -a 256 -c -
    mv "$partial" "$destination"
}

photorec_archive="$source_cache/$photorec_archive_name"
ddrescue_archive="$source_cache/$ddrescue_archive_name"
fetch_source "$photorec_url" "$photorec_sha256" "$photorec_archive"
fetch_source "$ddrescue_url" "$ddrescue_sha256" "$ddrescue_archive"

build_root="$(mktemp -d "${TMPDIR:-/tmp}/DataRevivalRecoveryEngines.XXXXXX")"
cleanup() {
    rm -rf "$build_root"
}
trap cleanup EXIT

/usr/bin/tar -xf "$photorec_archive" -C "$build_root"
/usr/bin/tar -xf "$ddrescue_archive" -C "$build_root"

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
clang_path="$(xcrun --find clang)"
clangxx_path="$(xcrun --find clang++)"
deployment_flags="-arch arm64 -mmacosx-version-min=$minimum_macos -isysroot $sdk_path"

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH=1708560000
export ZERO_AR_DATE=1

photorec_source="$build_root/testdisk-$photorec_version"
(
    cd "$photorec_source"
    PKG_CONFIG=/usr/bin/false ./configure \
        --disable-dependency-tracking \
        --disable-qt \
        --enable-missing-uuid-ok \
        --without-ext2fs \
        --without-ewf \
        --without-iconv \
        --without-jpeg \
        --without-ntfs \
        --without-ntfs3g \
        --without-reiserfs \
        --without-uuid \
        --without-zlib \
        CC="$clang_path" \
        CFLAGS="$deployment_flags -O2 -fno-common" \
        LDFLAGS="$deployment_flags"
    /usr/bin/make -C src -j4 photorec
)

ddrescue_source="$build_root/ddrescue-$ddrescue_version"
(
    cd "$ddrescue_source"
    ./configure \
        CXX="$clangxx_path" \
        CXXFLAGS="-Wall -W -O2 $deployment_flags" \
        LDFLAGS="$deployment_flags"
    /usr/bin/make -j4 ddrescue
)

product_root="$build_root/product"
mkdir -p \
    "$product_root/Helpers" \
    "$product_root/Licenses" \
    "$product_root/Notices" \
    "$product_root/SourceArchives"
/usr/bin/install -m 0755 "$photorec_source/src/photorec" "$product_root/Helpers/photorec"
/usr/bin/install -m 0755 "$ddrescue_source/ddrescue" "$product_root/Helpers/ddrescue"
/usr/bin/install -m 0644 "$photorec_source/COPYING" "$product_root/Licenses/PhotoRec-COPYING.txt"
/usr/bin/install -m 0644 "$ddrescue_source/COPYING" "$product_root/Licenses/GNU-ddrescue-COPYING.txt"
/usr/bin/install -m 0644 "$photorec_source/AUTHORS" "$product_root/Notices/PhotoRec-AUTHORS.txt"
/usr/bin/install -m 0644 "$ddrescue_source/AUTHORS" "$product_root/Notices/GNU-ddrescue-AUTHORS.txt"
/usr/bin/install -m 0644 "$photorec_archive" "$product_root/SourceArchives/$photorec_archive_name"
/usr/bin/install -m 0644 "$ddrescue_archive" "$product_root/SourceArchives/$ddrescue_archive_name"
/usr/bin/install -m 0644 "$manifest" "$product_root/RecoveryEngines.lock.json"

audit_binary() {
    local binary="$1"
    local architectures
    local dependency

    architectures="$(lipo -archs "$binary")"
    if [[ "$architectures" != "arm64" ]]; then
        echo "error: engine is not arm64-only: $binary ($architectures)" >&2
        exit 1
    fi

    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        case "$dependency" in
            /System/Library/*|/usr/lib/*)
                ;;
            *)
                echo "error: engine links to a non-system dependency: $binary ($dependency)" >&2
                exit 1
                ;;
        esac
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
}

audit_binary "$product_root/Helpers/photorec"
audit_binary "$product_root/Helpers/ddrescue"

(
    cd "$product_root"
    shasum -a 256 \
        Helpers/photorec \
        Helpers/ddrescue \
        Licenses/PhotoRec-COPYING.txt \
        Licenses/GNU-ddrescue-COPYING.txt \
        Notices/PhotoRec-AUTHORS.txt \
        Notices/GNU-ddrescue-AUTHORS.txt \
        RecoveryEngines.lock.json \
        SourceArchives/"$photorec_archive_name" \
        SourceArchives/"$ddrescue_archive_name" > SHA256SUMS
)

mv "$product_root" "$output_root"
echo "Recovery engines built and audited at $output_root"
"$output_root/Helpers/photorec" --version
"$output_root/Helpers/ddrescue" --version
