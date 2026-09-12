# Aagedal Data Revival

A proposed open-source, native macOS app for recovering files from accidentally formatted camera cards.

Status: runnable SwiftUI prototype with experimental PhotoRec-backed JPEG and common camera RAW scans for raw disk images. Physical-card discovery plus new-image and resume safety planning are available; privileged card imaging and production engine packaging are not connected yet. Video recovery and claims of full camera RAW integrity are explicitly outside the 1.0 scope.

## Run the prototype

Requires an Apple silicon Mac running macOS 14 or newer and Xcode with Swift 6 support. Version 1.0 targets arm64 Macs only. Open `Aagedal Data Revival.xcodeproj` and run the **Aagedal Data Revival** scheme. The Xcode project shares the implementation in `Sources/DataRevival` with the Swift package, which remains available for command-line builds and tests using `swift run DataRevival` and `swift test`.

The prototype includes source selection, a raw-image file picker, selectable JPEG-only or JPEG-plus-camera-RAW scan profiles, persistent and reopenable session manifests, cancellation with partial-result retention, live elapsed/file-count/output-size scan activity, real result discovery, searchable and type-filtered results, basic JPEG decode validation, honest RAW/TIFF preview-decode checks, Quick Look previews, collision-safe export, searchable sample results, and live read-only discovery of removable and external whole disks through Disk Arbitration. Common TIFF-based RAW variants and additional proprietary RAW families are included in the broader photo profile. RAW/TIFF files that macOS can preview are labeled “Preview readable,” while unsupported formats remain “Not checked”; neither status claims the sensor data is intact. The disk-tools screen can verify that a proposed card-image destination is on another physical device, has enough free space, and does not collide with image sidecars. It can also validate an interrupted image for safe resume using a structurally valid whole-source ddrescue mapfile and a Data Revival record bound to the original card identity, then report rescued, pending, and bad-sector byte counts. A non-forced Disk Arbitration lifecycle layer can unmount the whole source, re-resolve its identity, and later remount or eject it; this is tested but remains disconnected until authenticated privileged imaging is available. Scans interrupted by an app restart are reconciled on the next launch. Session manifests record the source image identity and PhotoRec version, executable digest, architecture, origin, and exact arguments. The three sample files remain illustrative metadata, not actual recovered files.

For debug-development scans, install the Homebrew `testdisk` formula, which supplies the `photorec` executable:

```sh
brew install testdisk
```

Select a nonempty raw image, choose a scan profile, choose **Recover JPEGs…** or **Recover Photos…**, and select a destination folder. The app creates an isolated `DataRevival-<UUID>` folder containing `session.json`, PhotoRec logs, and recovered output. PhotoRec is launched with an argument array and the source image is never opened for writing by the app.

Package-manager engines are a debug-only convenience. Release builds resolve `photorec` and `ddrescue` only from inside the application bundle. See [Recovery engine packaging](Documentation/RecoveryEnginePackaging.md) for the required layout, signing order, dependency rules, and bundle audit.

This is an integration spike, not a production recovery release. It currently performs a whole-image JPEG carve with basic decode and end-marker validation. Use disposable test images and copies of owned media.

## First release

Focus on SD, microSD, and CFexpress cards containing FAT32 or exFAT volumes. Version 1.0 supports JPEG and camera RAW recovery. MOV/MP4 recovery is deferred until camera-specific recovery and validation fixtures can support an honest compatibility claim. Start development with existing raw disk images; add physical-card imaging once the recovery pipeline is tested.

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

The current ddrescue adapter builds a shell-free, mapfile-backed imaging command, appends separate process output, and writes source-bound resume metadata before launch. Starting it from the UI remains disabled until a narrowly scoped privileged helper is implemented and connected to the tested unmount/revalidation lifecycle.

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
4. Photo-format validation and a repeatable recovery benchmark using synthetic images and owned camera files.
5. Metadata-aware recovery, more file types, and additional imaging/inspection tools.

Benchmark with known original files and byte hashes. Include quick-formatted FAT32/exFAT images, contiguous and fragmented files, truncated images, corrupt metadata, cancellation, output exhaustion, and filenames containing spaces. Test destructive formatting only on disposable test images or explicitly designated test media.

## Open-source and distribution decisions

PhotoRec is GPL-2.0-or-later. Review the licenses and source-distribution obligations for the exact engine versions and bundled dependencies before selecting the app's license and distributing binaries. License and distribution packaging are not yet decided.

Target a signed and notarized direct-download macOS application. Recovery engines and any non-system libraries must be bundled and nested-code signed; a release audit now rejects missing engines, architecture mismatches, invalid signatures, and external dynamic-library paths.

## Primary references

- [PhotoRec overview](https://www.cgsecurity.org/wiki/PhotoRec)
- [PhotoRec and TestDisk scripted operation](https://www.cgsecurity.org/wiki/Scripted_run)
- [PhotoRec camera-video recovery limitations](https://www.cgsecurity.org/testdisk_doc/photorec_video.html)
- [GNU ddrescue manual](https://www.gnu.org/software/ddrescue/manual/ddrescue_manual.html)
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
