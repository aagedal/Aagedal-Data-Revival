# Recovery engine versions

Version 1.0 pins the source inputs in
`Configuration/RecoveryEngines.lock.json`. Changes to an engine version, source
URL, checksum, source patch, target architecture, or minimum macOS version require a reviewed
manifest change and a fresh recovery benchmark.

## Reviewed selections

| Engine | Version | Why this release | Runtime dependencies |
| --- | --- | --- | --- |
| PhotoRec | 7.2 | Latest stable release; the 7.3 line is explicitly WIP. | `/usr/lib/libncurses.5.4.dylib`, `/usr/lib/libSystem.B.dylib` |
| GNU ddrescue | 1.30 | Latest stable release and current upstream recovery algorithm. | `/usr/lib/libc++.1.dylib`, `/usr/lib/libSystem.B.dylib` |

The checked-in SHA-256 values match the checksums published by CGSecurity and
the GNU ddrescue release announcement. The build deliberately disables optional
PhotoRec integrations that would introduce package-manager or non-system
libraries. PhotoRec's file-carving implementation and the formats selected by
Data Revival remain built in; disabled filesystem and GUI integrations are not
used by the scripted whole-image scan.

Data Revival applies the separately checksum-pinned
`ddrescue-inherited-stdin.patch`. It changes only ddrescue's initial input open:
when the app names `/dev/fd/0`, ddrescue duplicates the read-only descriptor that
macOS already authorized instead of reopening it and triggering another device
permission check. The original archive and the exact applied patch are both
included with the app.

Both engines are GPL-2.0-or-later. The inventory, separate-program analysis,
corresponding-source controls, and remaining app-license decision are recorded
in `Documentation/LicenseReview.md`.

## Reproducible build

Run on an Apple silicon Mac with Xcode command-line tools:

```sh
Scripts/build-recovery-engines.sh
```

The script downloads only the two locked HTTPS source archives, verifies their
SHA-256 digests before extraction, targets arm64 and macOS 14, and rejects any
result that links outside macOS system libraries. It emits the two executables,
exact source archives and patches, upstream license texts, lockfile, and output checksums
under `Build/RecoveryEngines` by default. Pass a new output directory as the
first argument to compare independent builds. Set
`DATA_REVIVAL_ENGINE_SOURCE_CACHE` to reuse an existing archive cache.

Generated output is intentionally not committed. The Xcode packaging phase
copies `Helpers/photorec` and `Helpers/ddrescue` into the app and embeds the
exact upstream licenses, author and modification notices, build lock,
checksums, build script, unmodified upstream archives, and applied source
patches under `Contents/Resources/RecoveryEngines`.

As a reproducibility check on 2026-09-13, two clean builds in separate temporary
directories produced byte-identical executables with Apple clang 21.0.0 and the
macOS 27 SDK. Re-run that comparison whenever the toolchain or lockfile changes.
