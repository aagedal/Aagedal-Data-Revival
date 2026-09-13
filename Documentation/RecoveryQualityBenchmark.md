# Recovery-quality benchmark

The versioned benchmark under `Benchmarks/RecoveryQuality/v1` is a
non-sensitive release-gate corpus. It measures contiguous JPEG recovery after
a genuine quick format of both FAT32 and exFAT volumes, plus deterministic raw
images containing fragmented, truncated, corrupt-metadata, and overwritten
JPEG data. Every expected recovery is compared with a declared SHA-256 digest;
a file that merely decodes or has the expected extension does not count as
exact.

The checked-in original is a programmatically generated color gradient, stored
as Base64 so the repository contains an auditable text representation. The
fixture archives are generated on macOS by copying that original to fresh
filesystem images and quick-formatting those images a second time. Virtual disk
images advertise discard support, which lets the formatter deallocate old data
blocks unlike an ordinary camera-card quick format. The generator therefore
restores the exact payload bytes at their original pre-format data-cluster
offset after capturing the newly formatted filesystem. It does not restore any
name, directory, or allocation metadata. The generator records each archive
digest in the suite manifest.

Generate or deliberately refresh every fixture archive with:

```sh
Scripts/generate-recovery-benchmark-fixtures.sh
```

The generator temporarily attaches only disk images it created under a unique
temporary directory. It does not enumerate, erase, or write to physical disks.
Review and commit both generated archives and the manifest hash changes
together.

To refresh only the deterministic raw edge-case fixtures without attaching a
disk image, run:

```sh
EDGE_FIXTURES_ONLY=1 Scripts/generate-recovery-benchmark-fixtures.sh
```

Build the pinned recovery engines and run the gate with:

```sh
Scripts/build-recovery-engines.sh
Scripts/run-recovery-benchmark.sh
```

Set `PHOTOREC_EXECUTABLE` to exercise another reviewed PhotoRec build. Paths
containing spaces are intentional in both the copied source filename and the
benchmark working directories.

## Measured JPEG matrix

These results describe the pinned PhotoRec 7.2 build and this exact synthetic
corpus. They are not a promise that arbitrary files in the same category will
behave identically.

| Source state | Gate result | Meaning |
| --- | --- | --- |
| FAT32 quick format, contiguous | Intact file recovered byte-for-byte | Supported by the current gate |
| exFAT quick format, contiguous | Intact file recovered byte-for-byte | Supported by the current gate |
| Raw image, fragmented | A candidate is carved, but the intact-file hash is absent | Known limitation; ordinary carving does not reconstruct the moved extent |
| Raw image, truncated | A candidate is carved, but the intact-file hash is absent | Known limitation; missing tail data is not reconstructed |
| Raw image, invalid EXIF byte-order marker | Damaged source artifact recovered byte-for-byte | Carving survives this metadata fault; this does not repair the metadata |
| Raw image, 512 bytes overwritten | Damaged source artifact recovered byte-for-byte; intact hash absent | Carving preserves the damage and cannot restore overwritten bytes |

“Byte-for-byte” for a damaged source artifact means PhotoRec copied the bytes
that remain in the image. It does not mean that Data Revival repaired the file
or recovered the intact original.

## Formats not yet qualified

Representative, redistributable camera RAW originals are still needed for
Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Pentax, and Sigma. Until those
fixtures pass, the benchmark makes no byte-exact recovery claim for those
families. Cancellation/resume, device removal, read errors, and destination
exhaustion also remain to be exercised end-to-end before the complete P0
quality gate can be marked finished. Paths containing spaces are exercised by
every benchmark run.
