#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
suite="$repo_root/Benchmarks/RecoveryQuality/v1"
manifest="$suite/manifest.json"
fixture_directory="$suite/fixtures"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/DataRevivalBenchmarkFixtures.XXXXXX")"
attached_device=""

cleanup() {
    local status=$?
    if [[ -n "$attached_device" ]]; then
        hdiutil detach "$attached_device" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$temporary_root"
    return "$status"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: benchmark fixtures must be generated on macOS" >&2
    exit 1
fi

mkdir -p "$fixture_directory"
original="$temporary_root/synthetic-gradient.jpg"
/usr/bin/base64 -D -i "$suite/originals/synthetic-gradient.jpg.base64" -o "$original"
actual_original_hash="$(/usr/bin/shasum -a 256 "$original" | /usr/bin/awk '{print $1}')"
expected_original_hash="$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["originals"][0]["sha256"])' \
    "$manifest")"
if [[ "$actual_original_hash" != "$expected_original_hash" ]]; then
    echo "error: encoded benchmark original does not match its manifest hash" >&2
    exit 1
fi

create_fixture() {
    local identifier="$1"
    local filesystem="$2"
    local volume_name="$3"
    local disk_image="$temporary_root/$identifier.dmg"
    local mount_point="$temporary_root/$identifier-volume"
    local preformat_image="$temporary_root/$identifier-before-quick-format.img"
    local raw_image="$temporary_root/$identifier.img"
    local archive="$fixture_directory/$identifier.img.gz"
    local attach_output
    local volume_device
    local raw_device
    local payload_offset

    mkdir -p "$mount_point"
    hdiutil create -quiet -size 96m -fs "$filesystem" -volname "$volume_name" "$disk_image"
    attach_output="$(hdiutil attach -nobrowse -noautoopen -mountpoint "$mount_point" "$disk_image")"
    attached_device="$(/usr/bin/awk 'NR == 1 {print $1}' <<< "$attach_output")"
    [[ "$attached_device" == /dev/disk* ]] || { echo "error: could not identify attached fixture device" >&2; exit 1; }

    /bin/cp "$original" "$mount_point/A photo before quick format.jpg"
    /bin/sync
    hdiutil detach "$attached_device" -quiet
    attached_device=""

    attach_output="$(hdiutil attach -nomount "$disk_image")"
    attached_device="$(/usr/bin/awk 'NR == 1 {print $1}' <<< "$attach_output")"
    volume_device="$(/usr/bin/awk 'END {print $1}' <<< "$attach_output")"
    [[ "$attached_device" == /dev/disk* && "$volume_device" == /dev/disk* ]] || {
        echo "error: could not identify reattached fixture device" >&2
        exit 1
    }

    raw_device="/dev/r${attached_device#/dev/}"
    /bin/dd if="$raw_device" of="$preformat_image" bs=1m status=none
    payload_offset="$(/usr/bin/python3 - "$preformat_image" "$original" <<'PY'
import pathlib
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
payload = pathlib.Path(sys.argv[2]).read_bytes()
print(image.find(payload))
PY
)"
    if (( payload_offset < 0 )); then
        echo "error: copied original was not present in the pre-format disk image" >&2
        exit 1
    fi

    case "$filesystem" in
        "MS-DOS FAT32")
            /sbin/newfs_msdos -F 32 -I 0x44524631 -v "$volume_name" "$volume_device" >/dev/null
            ;;
        "ExFAT")
            /sbin/newfs_exfat -I 0x44525831 -v "$volume_name" "$volume_device" >/dev/null
            ;;
        *)
            echo "error: unsupported benchmark filesystem: $filesystem" >&2
            exit 1
            ;;
    esac
    /bin/dd if="$raw_device" of="$raw_image" bs=1m status=none
    hdiutil detach "$attached_device" -quiet
    attached_device=""

    # Virtual disk images advertise discard support, so Apple's formatters can
    # deallocate old data blocks unlike an ordinary camera-card quick format.
    # Restore the exact payload at its original data-cluster offset, without
    # restoring filename, directory, or allocation metadata.
    /bin/dd if="$original" of="$raw_image" bs=1 seek="$payload_offset" conv=notrunc status=none

    /usr/bin/gzip -n -9 -c "$raw_image" > "$archive"
    echo "generated $archive"
}

if [[ "${EDGE_FIXTURES_ONLY:-0}" != "1" ]]; then
    create_fixture "fat32-quick-format-contiguous-jpeg" "MS-DOS FAT32" "DRBENCHFAT"
    create_fixture "exfat-quick-format-contiguous-jpeg" "ExFAT" "DRBENCHXFT"
fi

create_edge_fixture() {
    local identifier="$1"
    local raw_image="$temporary_root/$identifier.img"
    local payload="$temporary_root/$identifier.jpg"
    local archive="$fixture_directory/$identifier.img.gz"

    /bin/dd if=/dev/zero of="$raw_image" bs=1m count=8 status=none

    case "$identifier" in
        "raw-fragmented-jpeg")
            /bin/dd if="$original" of="$raw_image" bs=1 count=1024 seek=1048576 conv=notrunc status=none
            /bin/dd if="$original" of="$raw_image" bs=1 skip=1024 seek=1052672 conv=notrunc status=none
            ;;
        "raw-truncated-jpeg")
            /bin/dd if="$original" of="$raw_image" bs=1 count=2000 seek=1048576 conv=notrunc status=none
            ;;
        "raw-corrupt-metadata-jpeg")
            /bin/cp "$original" "$payload"
            printf 'ZZ' | /bin/dd of="$payload" bs=1 seek=30 conv=notrunc status=none
            /bin/dd if="$payload" of="$raw_image" bs=1 seek=1048576 conv=notrunc status=none
            ;;
        "raw-overwritten-jpeg")
            /bin/cp "$original" "$payload"
            /bin/dd if=/dev/zero of="$payload" bs=1 seek=1024 count=512 conv=notrunc status=none
            /bin/dd if="$payload" of="$raw_image" bs=1 seek=1048576 conv=notrunc status=none
            ;;
        *)
            echo "error: unsupported edge fixture: $identifier" >&2
            exit 1
            ;;
    esac

    /usr/bin/gzip -n -9 -c "$raw_image" > "$archive"
    echo "generated $archive"
}

create_edge_fixture "raw-fragmented-jpeg"
create_edge_fixture "raw-truncated-jpeg"
create_edge_fixture "raw-corrupt-metadata-jpeg"
create_edge_fixture "raw-overwritten-jpeg"

/usr/bin/python3 - "$manifest" "$fixture_directory" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
fixture_directory = pathlib.Path(sys.argv[2])
manifest = json.loads(path.read_text())
for fixture in manifest["fixtures"]:
    archive = fixture_directory / pathlib.Path(fixture["archivePath"]).name
    fixture["archiveSHA256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
path.write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "updated $manifest with fixture archive hashes"
