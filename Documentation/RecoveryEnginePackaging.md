# Recovery engine packaging

The release app must not discover or launch recovery engines from Homebrew,
MacPorts, `/usr/local`, or another machine-specific installation. Debug builds
may use those locations to keep development convenient; release builds do not.

## Required bundle layout

Place both executable entry points in the signed app:

```text
Aagedal Data Revival.app/
  Contents/
    Helpers/
      photorec
      ddrescue
```

If an engine needs non-system dynamic libraries, copy them into a standard
nested-code location inside the app, rewrite load commands to relocatable
`@loader_path`, `@executable_path`, or `@rpath` paths, and sign the innermost
libraries and executables before signing the outer app. Prefer reproducible
universal builds whose dependency set is known over copying binaries from a
developer's package-manager prefix.

The engine binaries, their build inputs, license texts, copyright notices, and
the corresponding source offer/source archives must be versioned and reviewed
before distribution. In particular, PhotoRec's GPL terms affect how the final
application and its source are distributed.

## Release gate

After creating and signing an archive, run:

```sh
Scripts/audit-app-bundle.sh "/path/to/Aagedal Data Revival.app"
```

The audit fails when a required engine is absent, is not executable, lacks one
of the app's architectures, is not signed, or links to an absolute dependency
outside macOS system locations. It also rejects external `LC_RPATH` entries and
verifies the outer app's nested signature.

This audit is intentionally a release check, not an embedding script. Engine
builds should be pinned and reproducible before the Xcode copy/sign phases are
added; otherwise a local package-manager update could silently change the
shipped recovery behavior.
