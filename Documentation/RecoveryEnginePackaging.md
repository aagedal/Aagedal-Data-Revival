# Recovery engine packaging

The release app must not discover or launch recovery engines from Homebrew,
MacPorts, `/usr/local`, or another machine-specific installation. Debug builds
may use those locations to keep development convenient; release builds do not.
Version 1.0 targets Apple silicon only: the app, both recovery engines, and all
bundled native libraries must contain exactly the arm64 architecture.

## Required bundle layout

Place both executable entry points in the signed app:

```text
Aagedal Data Revival.app/
  Contents/
    Helpers/
      photorec
      ddrescue
    Library/
      LaunchDaemons/
        com.aagedal.DataRevival.ImagingHelper.plist
    MacOS/
      DataRevivalImagingHelper
    Resources/
      RecoveryEngines/
        Licenses/
        Notices/
        SourceArchives/
        RecoveryEngines.lock.json
        SHA256SUMS
```

If an engine needs non-system dynamic libraries, copy them into a standard
nested-code location inside the app, rewrite load commands to relocatable
`@loader_path`, `@executable_path`, or `@rpath` paths, and sign the innermost
libraries and executables before signing the outer app. Prefer reproducible
universal builds whose dependency set is known over copying binaries from a
developer's package-manager prefix.

The engine binaries, exact upstream license texts and author notices, build
lock, checksums, and corresponding source archives ship together in every
release app. This makes the source used for the bundled binaries available
offline from the application itself rather than relying on a future download
or a time-limited written offer. Per-file copyright notices and complete build
inputs are retained in those unmodified source archives. In particular,
PhotoRec's GPL terms affect how the final application and its source are
distributed.

The arm64-only `DataRevivalImagingHelper` executable is embedded and signed
before the outer app. Its `SMAppService` LaunchDaemon property list remains
inside the app bundle and points to that relative executable with
`BundleProgram`, so moving the app does not leave an independent privileged
binary behind. The helper accepts only the signed Data Revival app over its
Mach service, verifies an administrator authorization right for imaging,
revalidates the source and destination, and passes an already-open read-only
raw-device descriptor to bundled ddrescue.

The reviewed source versions and checksums are locked in
`Configuration/RecoveryEngines.lock.json`. Build and audit the arm64 engines
with `Scripts/build-recovery-engines.sh`; selection rationale and deliberately
disabled optional dependencies are documented in
`Documentation/RecoveryEngineVersions.md`.

The Xcode target runs `Scripts/embed-recovery-engines.sh` after compiling the
app. It takes engine products from `Build/RecoveryEngines` by default; set the
`RECOVERY_ENGINE_PRODUCTS_DIR` build setting to use a separate verified output.
Debug builds warn and continue when those products are absent. Release builds
fail instead of silently producing an app without its engines. When code
signing is active, the phase signs each engine with Xcode's expanded identity
and hardened-runtime option before Xcode signs the outer app. The deliberately
unsigned CI build skips only that signing operation.

## Release gate

After creating and signing an archive, run:

```sh
Scripts/audit-app-bundle.sh "/path/to/Aagedal Data Revival.app"
```

The audit fails when the app, imaging helper, or bundled native code is not arm64-only, a
required engine is absent, is not executable, is not signed, or links to an
absolute dependency outside macOS system locations. It also rejects external
`LC_RPATH` entries, validates the LaunchDaemon/Mach-service identity, verifies every packaged engine artifact against the build
checksums, requires both corresponding source archives, and verifies the outer
app's nested signature. `SHA256SUMS` retains the reproducible pre-sign engine
digests; the audit validates shipped executable identity with code signatures
because signing necessarily changes their Mach-O bytes. All non-code artifacts
must still match `SHA256SUMS` byte for byte.

This audit is intentionally a release check, separate from embedding. The
embedding phase repeats architecture and dependency checks so a local
package-manager binary cannot silently become shipped recovery behavior.
