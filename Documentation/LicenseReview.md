# Version 1.0 license review

Reviewed: 2026-09-13

This is the project's engineering compliance record, not legal advice. It
covers the code and binary inputs currently planned for the 1.0 direct-download
artifact. A new dependency, engine version, patch, or distribution channel
requires another review.

## Inventory

| Component | Relationship | License and evidence | Distribution treatment |
| --- | --- | --- | --- |
| Aagedal Data Revival | Native app built from this repository | Copyright © 2026 Truls Aagedal; GPLv3-or-later, declared in `NOTICE`, with the complete GPLv3 text in `LICENSE`. | Package the notice and license with the app, publish corresponding source for the exact release tag beside the binary release, and retain all notices. |
| PhotoRec 7.2 | Separate executable launched with command-line arguments; not linked into the app | GPL-2.0-or-later, confirmed by the upstream 7.2 documentation and the source archive's `COPYING` and `AUTHORS` files. | Ship the exact upstream source archive, GPLv2 text, author notice, build script, lockfile, and checksums with the app. |
| GNU ddrescue 1.30 | Separate executable launched with command-line arguments and an inherited read-only descriptor; not linked into the app | GPL-2.0-or-later, confirmed by the pinned source archive's `COPYING` file and executable notice. | Ship the exact upstream source archive, GPLv2 text, author notice, dated modification notice, applied patch, build script, lockfile, and checksums with the app. |
| macOS system libraries | Dynamic dependencies supplied as part of macOS | PhotoRec uses `/usr/lib/libncurses.5.4.dylib` and `/usr/lib/libSystem.B.dylib`; ddrescue uses `/usr/lib/libc++.1.dylib` and `/usr/lib/libSystem.B.dylib`. | Do not redistribute them. The build and bundle audits reject non-system dynamic dependencies. |
| Apple frameworks and Swift runtime | Platform APIs and runtime supplied by Apple/Xcode | No third-party Swift package or linked library is present. | The app bundle carries only the runtime content selected by Xcode; the audit inventories all bundled Mach-O code. |

PhotoRec and ddrescue communicate with the app through ordinary process
arguments, files, process status, text logs, and a byte-stream descriptor. They
do not link with the app or exchange shared in-process data structures. The
project therefore treats the app and recovery engines as separate programs in
an aggregate. The app is nevertheless intended to use a GPL-compatible license,
so the release does not depend on a proprietary aggregation interpretation.

## Corresponding-source controls

`Scripts/build-recovery-engines.sh` creates the exact distributed engine
package and includes:

- the unmodified PhotoRec/TestDisk and GNU ddrescue source archives;
- the exact checksum-pinned ddrescue patch;
- a dated notice identifying the modified file and behavior;
- the build script that applies the patch and compiles both executables;
- the upstream GPLv2 texts and author notices; and
- the reviewed lockfile plus SHA-256 checksums for every item.

The Xcode embedding phase copies those materials into
`Contents/Resources/RecoveryEngines`. The signed-bundle audit rejects a release
when any item is missing, symlinked, or changed. The GitHub Release must also
link the immutable source tree for the exact app tag. Every app build also
contains the approved project notice and complete GPLv3 text under
`Contents/Resources/Legal`, and the interface provides a License & Notices view.

## Approval

Truls Aagedal approved the GPLv3-or-later declaration and copyright notice on
2026-09-13. If distribution is commercial or the separate-program
interpretation is material to the business, obtain qualified legal review
before publishing.

## Primary references

- [GNU GPL version 2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
- [GNU license FAQ: mere aggregation](https://www.gnu.org/licenses/gpl-faq.html#MereAggregation)
- [GNU license FAQ: communication between programs](https://www.gnu.org/licenses/gpl-faq.html#GPLPlugins)
- [PhotoRec/TestDisk 7.2 license statement](https://www.cgsecurity.org/testdisk_doc/presentation.html)
- [GNU ddrescue 1.30 manual](https://www.gnu.org/software/ddrescue/manual/ddrescue_manual.html)
