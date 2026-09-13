#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
suite="$repo_root/Benchmarks/RecoveryQuality/v1"
manifest="$suite/manifest.json"
photorec="${PHOTOREC_EXECUTABLE:-$repo_root/Build/RecoveryEngines/Helpers/photorec}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/DataRevivalRecoveryBenchmark.XXXXXX")"

cleanup() {
    local status=$?
    if [[ "${KEEP_BENCHMARK_OUTPUT:-0}" == "1" ]]; then
        echo "preserved benchmark output at $temporary_root"
    else
        rm -rf "$temporary_root"
    fi
    return "$status"
}
trap cleanup EXIT

if [[ ! -x "$photorec" ]]; then
    echo "error: PhotoRec is not executable at $photorec" >&2
    echo "Build the pinned engines first or set PHOTOREC_EXECUTABLE." >&2
    exit 1
fi

/usr/bin/python3 - "$manifest" "$suite" "$photorec" "$temporary_root" <<'PY'
import base64
import gzip
import hashlib
import json
import pathlib
import subprocess
import sys

manifest_path = pathlib.Path(sys.argv[1])
suite = pathlib.Path(sys.argv[2])
photorec = pathlib.Path(sys.argv[3])
work = pathlib.Path(sys.argv[4])
manifest = json.loads(manifest_path.read_text())

if manifest.get("schemaVersion") != 2:
    raise SystemExit("error: unsupported recovery benchmark manifest schema")

originals = {item["id"]: item for item in manifest["originals"]}
for original in originals.values():
    encoded = (suite / original["encodedPath"]).read_bytes()
    payload = base64.b64decode(encoded, validate=False)
    if hashlib.sha256(payload).hexdigest() != original["sha256"]:
        raise SystemExit(
            f"error: encoded original checksum mismatch: {original['encodedPath']}"
        )
expected_total = 0
exact_total = 0
fixture_results = []

for fixture in manifest["fixtures"]:
    archive = suite / fixture["archivePath"]
    archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    if archive_hash != fixture["archiveSHA256"]:
        raise SystemExit(f"error: fixture archive checksum mismatch: {archive}")

    fixture_work = work / fixture["id"]
    fixture_work.mkdir()
    image = fixture_work / "source image with spaces.img"
    with gzip.open(archive, "rb") as source, image.open("wb") as destination:
        while chunk := source.read(1024 * 1024):
            destination.write(chunk)

    output = fixture_work / "recovered output"
    output.mkdir()
    log = fixture_work / "photorec.log"
    command = [
        str(photorec),
        "/logname", str(log),
        "/d", str(output / "recovered"),
        "/cmd", str(image),
        "fileopt,everything,disable,jpg,enable,wholespace,search",
    ]
    completed = subprocess.run(command, cwd=fixture_work, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    if completed.returncode != 0:
        print(completed.stdout, file=sys.stderr)
        raise SystemExit(
            f"error: PhotoRec failed for {fixture['id']} with status {completed.returncode}"
        )

    recovered_hashes = {}
    for candidate in output.rglob("*"):
        if candidate.is_file() and candidate.name != "report.xml":
            payload = candidate.read_bytes()
            digest = hashlib.sha256(payload).hexdigest()
            recovered_hashes.setdefault(digest, []).append(
                (str(candidate.relative_to(output)), len(payload))
            )

    expected = fixture.get("expectedRecoveries", [])
    exact = sum(item["sha256"] in recovered_hashes for item in expected)
    forbidden = fixture.get("forbiddenRecoveries", [])
    unexpectedly_recovered = [
        item for item in forbidden if item["sha256"] in recovered_hashes
    ]
    minimum_recovered = fixture.get("minimumDistinctRecoveredPayloads", len(expected))
    if exact != len(expected) or unexpectedly_recovered or len(recovered_hashes) < minimum_recovered:
        for digest, candidates in recovered_hashes.items():
            for path, size in candidates:
                print(f"  recovered {path}: {size} bytes, sha256 {digest}")
    if unexpectedly_recovered:
        labels = ", ".join(item["label"] for item in unexpectedly_recovered)
        raise SystemExit(
            f"error: {fixture['id']} unexpectedly recovered prohibited artifact(s): {labels}"
        )
    if len(recovered_hashes) < minimum_recovered:
        raise SystemExit(
            f"error: {fixture['id']} recovered {len(recovered_hashes)} distinct payloads; "
            f"expected at least {minimum_recovered}"
        )
    expected_total += len(expected)
    exact_total += exact
    fixture_results.append((
        fixture["id"],
        exact,
        len(expected),
        len(recovered_hashes),
        fixture["classification"],
    ))

if expected_total == 0:
    raise SystemExit("error: benchmark manifest contains no expected recoveries")

rate = exact_total / expected_total
minimum = manifest["acceptance"]["minimumExactRecoveryRate"]
for identifier, exact, expected, recovered_count, classification in fixture_results:
    print(f"{identifier}: {exact}/{expected} expected byte-exact artifacts; "
          f"{recovered_count} distinct recovered payloads; {classification}")
print(f"Exact recovery rate: {rate:.1%} (required: {minimum:.1%})")
if rate < minimum:
    raise SystemExit("error: recovery benchmark acceptance threshold was not met")
print(f"Recovery benchmark {manifest['suiteVersion']} passed")
PY
