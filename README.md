# Aagedal Data Revival

A proposed open-source, native macOS app for recovering files from accidentally formatted camera cards.

Status: runnable SwiftUI prototype with an experimental PhotoRec-backed JPEG scan for raw disk images. Physical-card imaging, file validation, RAW/video recovery, and production engine packaging are not connected yet.

## Run the prototype

Requires macOS 14 or newer and Xcode with Swift 6 support. Open `Aagedal Data Revival.xcodeproj` and run the **Aagedal Data Revival** scheme. The Xcode project shares the implementation in `Sources/DataRevival` with the Swift package, which remains available for command-line builds and tests using `swift run DataRevival` and `swift test`.

The prototype includes source selection, a raw-image file picker, persistent session manifests, cancellation, real JPEG result discovery, searchable sample results, and placeholders for disk tools. The four sample files remain illustrative metadata, not actual recovered files.

For development scans, install the Homebrew `testdisk` formula, which supplies the `photorec` executable:

```sh
brew install testdisk
```

Select a nonempty raw image, choose **Recover JPEGs…**, and select a destination folder. The app creates an isolated `DataRevival-<UUID>` folder containing `session.json`, PhotoRec logs, and recovered output. PhotoRec is launched with an argument array and the source image is never opened for writing by the app.

This is an integration spike, not a production recovery release. It currently performs a whole-image JPEG carve and reports files as unvalidated. Use disposable test images and copies of owned media.

## First release

Focus on SD, microSD, and CFexpress cards containing FAT32 or exFAT volumes. Support JPEG and camera RAW recovery first, with clearly qualified MOV/MP4 recovery. Start development with existing raw disk images; add physical-card imaging once the recovery pipeline is tested.

The main workflow is:

1. Select a card or an existing raw disk image.
2. Choose storage on a different physical device for the image and recovered files.
3. Create a resumable image of the card.
4. Scan the image, collecting recovered candidates into a session folder.
5. Review thumbnails, file types, dates where available, and validation results.
6. Export selected files to a chosen folder.

Scanning can write substantial recovered data before the user chooses what to export. The UI must explain this and account for both the full card image and recovered output when estimating space.

## Native interface

Use SwiftUI with AppKit integration where needed, a source/session sidebar, a recovery detail pane, and a preview inspector. Keep the interface focused on the next useful action. Show real progress when the engine supplies it and indeterminate progress otherwise.

Sessions should survive app restarts. Distinguish found files from successfully validated files. A thumbnail or readable header is not evidence that an entire photo or video is intact. Do not invent recovery probability percentages.

## Implementation approach

- **App:** SwiftUI, structured concurrency, persistent session manifests, Quick Look and format-specific previews.
- **Initial recovery engine:** PhotoRec behind a process adapter. It has documented scripted operation and can scan disk images. Prototype its progress reporting, cancellation, and resume behavior before committing to the integration design.
- **Card imaging:** GNU ddrescue behind a separate adapter, preserving its mapfile for interrupted or difficult reads.
- **Device access:** Disk Arbitration for discovery and lifecycle management; investigate a narrowly scoped privileged helper for raw device access. Keep the UI unprivileged.
- **Validation:** Decode recovered photos where supported; inspect video structure and decoding separately. Keep partial files available with an explicit status.
- **Later filesystem recovery:** Add metadata-aware FAT32/exFAT recovery to retain names and directory structure where metadata survives. Carving alone generally cannot preserve this information.

Use argument arrays rather than shell command strings. Give each session an isolated output and working directory. Record engine versions, configuration, source identity, logs, and validation results.

## Source protection

Open recovery sources read-only. Never repair, format, or write partition structures on an original card. Reject destinations backed by the source physical device, including a different partition on the same device. Revalidate device identity before opening it; device names can change after reconnection.

For raw-image development, reject source/output aliases and existing output collisions. For card imaging, handle unplugging, full destination disks, read errors, cancellation, and resume explicitly. Store mapfiles and logs away from the source.

## Important limits

Recovery depends on what the camera's format operation actually erased and whether the card has been reused. Overwritten or erased content cannot be reconstructed by ordinary file recovery software.

Fragmented video is a separate engineering problem. PhotoRec documents camera recordings that ordinary carving cannot reconstruct. Do not promise universal video recovery; build camera-specific fixtures and validation before advertising support.

## Development milestones

1. Native UI prototype with explicitly labeled sample data and the source-to-results workflow.
2. Real recovery from raw disk image files, with PhotoRec integration, persistent sessions, cancellation, and result browsing.
3. Tested physical-device discovery and resumable card imaging with source/destination protections.
4. Format validation and a repeatable recovery benchmark using synthetic images and owned camera recordings.
5. Metadata-aware recovery, more file types, and additional imaging/inspection tools.

Benchmark with known original files and byte hashes. Include quick-formatted FAT32/exFAT images, contiguous and fragmented files, truncated images, corrupt metadata, cancellation, output exhaustion, and filenames containing spaces. Test destructive formatting only on disposable test images or explicitly designated test media.

## Open-source and distribution decisions

PhotoRec is GPL-2.0-or-later. Review the licenses and source-distribution obligations for the exact engine versions and bundled dependencies before selecting the app's license and distributing binaries. License and distribution packaging are not yet decided.

Investigate a signed and notarized direct-download macOS application early, including helper installation and engine packaging.

## Primary references

- [PhotoRec overview](https://www.cgsecurity.org/wiki/PhotoRec)
- [PhotoRec and TestDisk scripted operation](https://www.cgsecurity.org/wiki/Scripted_run)
- [PhotoRec camera-video recovery limitations](https://www.cgsecurity.org/testdisk_doc/photorec_video.html)
- [GNU ddrescue manual](https://www.gnu.org/software/ddrescue/manual/ddrescue_manual.html)
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
