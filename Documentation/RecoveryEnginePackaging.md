# Recovery engine packaging

The release app must not discover or launch recovery engines from Homebrew,
MacPorts, `/usr/local`, or another machine-specific installation. Debug builds
may use those locations to keep development convenient; release builds do not.
Version 1.0 targets Apple silicon only: the app, both recovery engines, and all
bundled native libraries must contain exactly the arm64 architecture.

## Required bundle layout

Place both recovery-engine entry points in the signed app:

```text
Aagedal Data Revival.app/
  Contents/
    Helpers/
      photorec
      ddrescue
    Resources/
      RecoveryEngines/
        Licenses/
        Notices/
        SourceArchives/
        SourceBuildScripts/
        SourcePatches/
        RecoveryEngines.lock.json
        SHA256SUMS
```

If an engine needs non-system dynamic libraries, copy them into a standard
nested-code location inside the app, rewrite load commands to relocatable
`@loader_path`, `@executable_path`, or `@rpath` paths, and sign the innermost
libraries and executables before signing the outer app. Prefer reproducible
universal builds whose dependency set is known over copying binaries from a
developer's package-manager prefix.

The engine binaries, exact upstream license texts, author and modification
notices, build lock, checksums, corresponding source archives, build script,
and reviewed source patches ship together in every release app. This makes the source used for the bundled binaries available
offline from the application itself rather than relying on a future download
or a time-limited written offer. Per-file copyright notices and complete build
inputs are retained in those unmodified source archives. In particular,
PhotoRec's GPL terms affect how the final application and its source are
distributed.

The app does not install a privileged helper or LaunchDaemon. It obtains a
temporary, path-specific read-only raw-device descriptor from macOS
`/usr/libexec/authopen`, validates that the descriptor still represents the
selected card, and passes it to bundled ddrescue while ddrescue runs as the
logged-in user. The reviewed ddrescue patch duplicates this inherited descriptor
instead of reopening `/dev/fd/0`, which would make macOS repeat the raw-device
access check in the unprivileged child. The app must remain outside App Sandbox because Authorization
Services does not support privilege elevation from a sandboxed process.

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
signing is active, the phase signs each engine with Xcode's expanded identity,
hardened-runtime option, and the signing service's trusted timestamp before
Xcode signs the outer app. The deliberately unsigned CI build skips only that
signing operation.

## Release gate

After creating and signing an archive, run:

```sh
Scripts/audit-app-bundle.sh "/path/to/Aagedal Data Revival.app"
```

The audit fails when the app or bundled native code is not arm64-only, a
required engine is absent, is not executable, is not signed with a Developer ID
Application identity, lacks hardened runtime or a trusted timestamp, carries
any entitlement not reviewed for the entitlement-free 1.0 Release
configuration, or links to an absolute
dependency outside macOS system locations. It permits the system Swift runtime
path but rejects other external `LC_RPATH` entries, validates the
absence of the obsolete LaunchDaemon/helper payload, verifies every packaged engine artifact against the build
checksums, requires both corresponding source archives, the build script, modification notice, and the reviewed ddrescue source patch, and verifies the outer
app's nested signature. `SHA256SUMS` retains the reproducible pre-sign engine
digests; the audit validates shipped executable identity with code signatures
because signing necessarily changes their Mach-O bytes. All non-code artifacts
must still match `SHA256SUMS` byte for byte.

This audit is intentionally a release check, separate from embedding. The
embedding phase repeats architecture and dependency checks so a local
package-manager binary cannot silently become shipped recovery behavior.
