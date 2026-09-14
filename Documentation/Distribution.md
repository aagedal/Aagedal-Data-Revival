# Distribution and updates

Version 1.0.0 was published on 2026-09-15 as the project's first public
release. Downloads are provided through
[GitHub Releases](https://github.com/aagedal/Aagedal-Data-Revival/releases).
The release points to tag `1.0.0` at commit
`16e0a7da550ee056b68fbb5558b0f357c84d6795` and contains
`Aagedal_Data_Revival_1-0-0.zip`. Its SHA-256 digest is:

```text
d577b05504db038adf3b765ec75765917bb7f570f86dfd163c382a325a0f0d50
```

Verify a downloaded copy before opening it:

```sh
shasum -a 256 Aagedal_Data_Revival_1-0-0.zip
```

## Version 1.0.0 binary status

Do not run the currently published binary. A fresh download on 2026-09-15
matched the digest above, but both supported extraction methods produced the
same app binaries and `codesign --verify --deep --strict` rejected the app and
each bundled executable. The bundle contains a stapled notarization ticket, but
the repository's signed-bundle audit also stops at the invalid PhotoRec
signature. The tag and source history are unaffected. Follow the
[rollback procedure](RollbackProcedure.md) and publish the corrected build under
a new version; do not replace the 1.0.0 asset or move its tag.

The app bundle retains the embedded, checksum-verified corresponding source for
the bundled recovery engines and includes its GPLv3-or-later notice and the
complete GPLv3 license. See the
[version 1.0.0 release notes](Releases/1.0.0.md) for requirements, scope, and
known limitations.

## Preparing a release

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

The app has no automatic updater in 1.0.0 and performs no network request to check
for releases. Users opt in to updates by visiting the releases page. Release
notes must say which macOS and hardware versions were tested, list known
recovery limitations, and link to the changelog, privacy statement, support
information, and source code for the exact tag.

Git tags and release artifacts are immutable release records. If an artifact is
unsafe or materially incorrect, withdraw it using the documented rollback
procedure; do not replace a published file in place under the same version.
