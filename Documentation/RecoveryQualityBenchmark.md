# Recovery-quality benchmark

The versioned benchmark under `Benchmarks/RecoveryQuality/v1` is a
non-sensitive release-gate corpus. It measures contiguous JPEG recovery after
a genuine quick format of both FAT32 and exFAT volumes, deterministic raw
images containing fragmented, truncated, corrupt-metadata, and overwritten
JPEG data, and representative real-camera RAW files from eight manufacturers.
Every promised exact recovery is compared with a declared SHA-256 digest; a
file that merely decodes or has the expected extension does not count as exact.

The checked-in JPEG original is a programmatically generated color gradient,
stored as Base64 so the repository contains an auditable text representation.
The fixture archives are generated on macOS by copying that original to fresh
filesystem images and quick-formatting those images a second time. Virtual disk
images advertise discard support, which lets the formatter deallocate old data
blocks unlike an ordinary camera-card quick format. The generator therefore
restores the exact payload bytes at their original pre-format data-cluster
offset after capturing the newly formatted filesystem. It does not restore any
name, directory, or allocation metadata. The generator records each archive
digest in the suite manifest.

The camera RAW originals are unmodified CC0 files from raw.pixls.us. Their
published provenance and hashes are recorded in
`Benchmarks/RecoveryQuality/v1/originals/camera-raw/SOURCES.md`. At runtime, the
gate places each original at a 1 MiB boundary in an otherwise zero-filled image
and runs the same PhotoRec file-family profile used by the app. This isolates
each signature and makes any retained trailing bytes deterministic.

Generate or deliberately refresh every JPEG fixture archive with:

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

## Measured camera RAW matrix

These are representative format samples, not model-wide compatibility claims.
“Trailing bytes retained” means the pinned carver found the correct RAW header
but did not determine the original end boundary. The resulting candidate is not
byte-exact and must remain honestly labeled as preview-readable, unchecked, or
possibly partial by the app.

| Family and sample | Gate result | 1.0 qualification |
| --- | --- | --- |
| Canon CR2, EOS 40D | Intact file recovered byte-for-byte | Qualified representative |
| Nikon NEF, D2H | Intact file recovered byte-for-byte | Qualified representative |
| Sony ARW, ILCE-7S | Candidate recovered as the shared SR2 family with trailing bytes retained | Known limitation; no byte-exact claim |
| Fujifilm RAF, FinePix S5000 | Candidate recovered with trailing bytes retained | Known limitation; no byte-exact claim |
| Olympus ORF, E-3 | Intact file recovered byte-for-byte | Qualified representative |
| Panasonic RW2, DMC-FZ28 | Candidate recovered with trailing bytes retained | Known limitation; no byte-exact claim |
| Pentax PEF, K10D | Intact file recovered byte-for-byte | Qualified representative |
| Sigma X3F, DP1 | Candidate recovered with trailing bytes retained | Known limitation; no byte-exact claim |

## Remaining physical-media qualification

The automated foundation suite verifies that cancelling the imaging process
preserves its partial image and resume sidecars, that a resume is bound to the
original source, and that removal, read-error, and destination-exhaustion
failures produce the intended recovery guidance. Those scenarios still need to
be exercised end-to-end with disposable physical cards before the complete P0
quality gate can be marked finished. Paths containing spaces are exercised by
every benchmark run.
