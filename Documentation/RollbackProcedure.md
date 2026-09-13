# Release rollback procedure

Use this procedure when a published build can write to or misidentify a source,
overwrite user data, corrupt recovery state, violate distribution obligations,
fail Gatekeeper validation, or materially overstate recovery results. Treat
uncertain source-safety behavior as a stop-ship issue.

1. Mark the affected GitHub Release as a pre-release or remove its downloadable
   binary assets. Keep the Git tag and source history intact for auditability.
2. Put a warning at the top of the release notes naming the affected version,
   impact, safe user action, and last known-good version. Do not ask users to
   continue a potentially unsafe recovery attempt.
3. Open a tracking issue without publishing private card data or security
   details. Preserve the released artifact, checksum, notarization result, CI
   logs, and acceptance evidence in restricted project records.
4. Determine whether existing images, mapfiles, session manifests, or exports
   remain safe to retain. Give users explicit preservation or cleanup guidance.
5. Fix forward on a new version and build number from a reviewed commit. Repeat
   every item in `Documentation/ReleaseChecklist.md`; never replace an asset or
   move a tag for the withdrawn version.
6. Publish the replacement with new checksums and release notes that identify
   the superseded version. Re-test the public download on a clean Mac.

Because version 1.0 has no automatic updater, withdrawing a GitHub asset does
not remove installed copies. The release notice and support response must tell
affected users how to identify their version and stop using it safely.
