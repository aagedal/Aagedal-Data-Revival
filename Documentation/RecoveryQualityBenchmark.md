# Recovery-quality benchmark

The versioned benchmark under `Benchmarks/RecoveryQuality/v1` is the first
non-sensitive release-gate corpus. It currently measures contiguous JPEG
recovery after a genuine quick format of both FAT32 and exFAT volumes. Every
expected recovery is compared with its known original using SHA-256; a file
that merely decodes or has the expected extension does not count as exact.

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

Generate or deliberately refresh the fixture archives with:

```sh
Scripts/generate-recovery-benchmark-fixtures.sh
```

The generator temporarily attaches only disk images it created under a unique
temporary directory. It does not enumerate, erase, or write to physical disks.
Review and commit both generated archives and the manifest hash changes
together.

Build the pinned recovery engines and run the gate with:

```sh
Scripts/build-recovery-engines.sh
Scripts/run-recovery-benchmark.sh
```

Set `PHOTOREC_EXECUTABLE` to exercise another reviewed PhotoRec build. Paths
containing spaces are intentional in both the copied source filename and the
benchmark working directories.

## Current matrix

| Filesystem state | JPEG | Camera RAW | Fragmented | Truncated | Corrupt metadata | Overwritten |
| --- | --- | --- | --- | --- | --- | --- |
| FAT32 quick format | Byte-exact gate | Not yet covered | Not yet covered | Not yet covered | Not yet covered | Not yet covered |
| exFAT quick format | Byte-exact gate | Not yet covered | Not yet covered | Not yet covered | Not yet covered | Not yet covered |

This is deliberately a narrow starting matrix, not a broader compatibility
claim. Representative, redistributable camera RAW originals are still needed
for Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Pentax, and Sigma. The
benchmark must also grow cases for fragmentation, truncation, corrupt metadata,
overwriting, cancellation/resume, device removal, read errors, and destination
exhaustion before the complete P0 quality gate can be marked finished.
