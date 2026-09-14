# Version 1.0 release checklist

Complete this checklist from a clean checkout of the exact release commit. Store
the command output and acceptance-test notes with the release record. A checked
box in this document is not a substitute for evidence from the candidate.

## Published release record

Version 1.0.0 was published on 2026-09-15. The GitHub Release uses the immutable
tag `1.0.0`, which points to commit
`16e0a7da550ee056b68fbb5558b0f357c84d6795`. The published asset is
`Aagedal_Data_Revival_1-0-0.zip`, with SHA-256
`d577b05504db038adf3b765ec75765917bb7f570f86dfd163c382a325a0f0d50`.

This section records publication facts only. Unchecked gates below remain
unchecked where their evidence is not stored in the repository; publication
does not retroactively prove an acceptance test passed.

Post-publication verification on 2026-09-15 downloaded the public asset and
confirmed its SHA-256, version 1.0, build 1, arm64 architecture, and stapled
notarization ticket. The extracted app nevertheless failed
`codesign --verify --deep --strict`; the app, PhotoRec, and ddrescue signatures
were all rejected. `Scripts/audit-app-bundle.sh` stopped at PhotoRec's invalid
signature. Treat the binary as withdrawn under the rollback procedure even
while its GitHub asset remains accessible.

## Scope and source

- [ ] Every P0 item in `Documentation/1.0-Implementation-Plan.md` is complete.
- [ ] Release notes describe only qualified JPEG and camera RAW behavior and do
  not claim MOV/MP4, original-name, directory, or full RAW-integrity recovery.
- [ ] `CHANGELOG.md`, `SUPPORT.md`, and `PRIVACY.md` match the candidate.
- [ ] The license review covers the app, PhotoRec, ddrescue, build patches, and
  every bundled library; notices and exact corresponding source are present.
- [ ] `main` is clean, CI is green, `MARKETING_VERSION` is `1.0`, the build
  number is unused, and the release commit has been recorded.

## Automated gates

- [ ] From a clean checkout, `swift test` passes.
- [ ] `Scripts/build-recovery-engines.sh` succeeds using the pinned inputs.
- [ ] `Scripts/run-recovery-benchmark.sh` passes with the just-built PhotoRec.
- [ ] The macOS UI test suite passes from a logged-in user session.
- [ ] A Release archive is created with the intended Developer ID Application
  identity and no development entitlement.
- [ ] `Scripts/audit-app-bundle.sh` passes on the exported app.
- [ ] The exported app and its nested code pass `codesign --verify --deep
  --strict --verbose=2`.
- [ ] The notarization service accepts the ZIP, the ticket is stapled, and
  `stapler validate` and `spctl --assess --type execute --verbose=4` pass with
  the Mac offline.

`Scripts/prepare-release-candidate.sh` performs the signed archive, online
notarization, staple validation, bundle audit, initial Gatekeeper assessment,
and final ZIP/checksum steps. Preserve its complete output, then repeat the
explicitly offline and clean-machine checks above rather than treating the
script run as hardware evidence.

## Hardware acceptance

- [ ] Test each supported macOS major version on Apple silicon hardware.
- [ ] On a clean Mac without Homebrew or developer tools, install and launch the
  candidate through Gatekeeper.
- [ ] With disposable FAT32 and exFAT cards, complete card selection, read-only
  authorization, non-forced unmount, imaging, scan, review, and export.
- [ ] Verify cancellation and resume, card removal, read-error handling, sleep,
  a full destination, remount, and eject while retaining required sidecars.
- [ ] Verify source/destination collision checks with separate partitions on the
  same physical device.
- [ ] Complete keyboard, VoiceOver, contrast, and reduced-motion checks and
  record the matrix in `Documentation/AccessibilityReview.md`.
- [ ] Compare representative supported camera files with known-original hashes
  and record all exceptions in the support matrix and release notes.

## Publish

- [ ] Name the artifact `Aagedal-Data-Revival-1.0.0-macOS-arm64.zip` and record
  its SHA-256 checksum without changing the notarized app after packaging.
- [x] Tag the release commit `1.0.0`; do not move or reuse the tag.
- [ ] Create a GitHub Release for that tag, upload the stapled ZIP and checksum,
  link the exact source tree, and publish the final release notes.
- [ ] Download the public artifact on a clean Mac, verify its checksum and
  Gatekeeper assessment, then repeat the smoke-test recovery workflow.
- [ ] Keep the prior known-good artifact available and follow
  `Documentation/RollbackProcedure.md` if a stop-ship problem is found.
