# Privacy statement

Last updated: 2026-09-15

Aagedal Data Revival processes card images and recovered files locally on the
Mac. Version 1.0.0 does not include analytics, advertising, telemetry, cloud
storage, accounts, or an automatic updater, and the app does not transmit card
contents or recovery results to the project maintainers.

The app asks macOS for administrator authorization only when it needs temporary,
read-only access to the selected raw-device path. It does not install a
privileged helper or background service. macOS and the selected distribution
service may independently record normal operating-system or download activity;
those systems are governed by their own policies.

Recovery sessions are stored in the destination folder the user selects. A
session can contain recovered files, a manifest, engine provenance, source
identity and size, scan arguments, and process logs. Card imaging also creates
an image, ddrescue mapfile, resume record, and log beside the chosen image path.
These files remain local until the user moves, shares, or deletes them.

The app's cleanup action moves a managed recovery-session folder to the macOS
Trash after verifying that it is the expected session. Card images and their
sidecars are not silently deleted. Users control the final deletion of items in
the Trash and should review diagnostic files before sharing them because they
may contain paths, device details, filenames, or recovery metadata.

Questions about this statement can be raised through the support channels in
[SUPPORT.md](SUPPORT.md).
