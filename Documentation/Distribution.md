# Distribution and updates

Version 1.0 uses signed and notarized direct downloads from
[GitHub Releases](https://github.com/aagedal/Aagedal-Data-Revival/releases).
The canonical artifact is a stapled ZIP containing `Aagedal Data Revival.app`.
Each release also publishes a SHA-256 checksum for the ZIP and source archives
that satisfy the licenses of the application and bundled recovery engines.

The app has no automatic updater in 1.0 and performs no network request to check
for releases. Users opt in to updates by visiting the releases page. Release
notes must say which macOS and hardware versions were tested, list known
recovery limitations, and link to the changelog, privacy statement, support
information, and source code for the exact tag.

Git tags and release artifacts are immutable release records. If an artifact is
unsafe or materially incorrect, withdraw it using the documented rollback
procedure; do not replace a published file in place under the same version.
