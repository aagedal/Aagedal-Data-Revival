# Version 1.0 release checklist

Complete this checklist from a clean checkout of the exact release commit. Store
the command output and acceptance-test notes with the release record. A checked
box in this document is not a substitute for evidence from the candidate.

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
- [ ] Tag the verified commit `v1.0.0`; do not move or reuse the tag.
- [ ] Create a GitHub Release for that tag, upload the stapled ZIP and checksum,
  link the exact source tree, and publish the final release notes.
- [ ] Download the public artifact on a clean Mac, verify its checksum and
  Gatekeeper assessment, then repeat the smoke-test recovery workflow.
- [ ] Keep the prior known-good artifact available and follow
  `Documentation/RollbackProcedure.md` if a stop-ship problem is found.
