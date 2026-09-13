# Distribution and updates

Version 1.0 uses signed and notarized direct downloads from
[GitHub Releases](https://github.com/aagedal/Aagedal-Data-Revival/releases).
The canonical artifact is a stapled ZIP containing `Aagedal Data Revival.app`.
Each release also publishes a SHA-256 checksum for the ZIP, links the exact tag
containing the application's corresponding source, and retains the embedded,
checksum-verified corresponding source for the bundled recovery engines. The
app bundle includes its GPLv3-or-later notice and the complete GPLv3 license.

Create the candidate from a clean checkout with an unused positive build number,
a Developer ID Application identity in the signing keychain, and notarization
credentials previously stored with `notarytool store-credentials`:

```sh
DATA_REVIVAL_BUILD_NUMBER=1 \
DATA_REVIVAL_NOTARY_PROFILE=DataRevival-Notary \
Scripts/prepare-release-candidate.sh /path/to/release-output
```

The script rebuilds the pinned engines, creates and exports the Developer ID
archive, runs the signed-bundle audit, submits a temporary ZIP for notarization,
staples and validates the app, repeats the bundle audit, performs a Gatekeeper
assessment, and creates the immutable versioned ZIP and SHA-256 file. It refuses
to overwrite an existing artifact. Keep the complete command output with the
release record and still perform the offline clean-Mac acceptance checks in the
release checklist.

The app has no automatic updater in 1.0 and performs no network request to check
for releases. Users opt in to updates by visiting the releases page. Release
notes must say which macOS and hardware versions were tested, list known
recovery limitations, and link to the changelog, privacy statement, support
information, and source code for the exact tag.

Git tags and release artifacts are immutable release records. If an artifact is
unsafe or materially incorrect, withdraw it using the documented rollback
procedure; do not replace a published file in place under the same version.
