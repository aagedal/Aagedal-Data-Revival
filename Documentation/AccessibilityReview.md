# Version 1.0 accessibility review

The 1.0 candidate must be checked with the macOS accessibility settings below on
every supported macOS major version. Record the app version, build number,
hardware, macOS version, tester, date, and any exception with the release record.

## Implemented baseline

- Native SwiftUI controls provide standard keyboard focus and activation.
- Workflow steps, scan metrics, imaging progress, recovery sessions, storage
  devices, Quick Look previews, and recovered-file details have explicit spoken
  labels or values.
- Status and validation meaning is always expressed with text and symbols, not
  color alone.
- Command-O chooses an existing disk image, Escape cancels an active scan or
  leaves sample results, Command-Shift-E exports selected files, and Command-R
  rescans removable media.
- The app uses no custom animation or motion effects. System control animation
  therefore follows the user's Reduce Motion preference.

## Manual release matrix

Repeat the complete image-scan-review-export path and the card imaging controls
for each row. A row passes only when content remains readable, controls remain
reachable and operable, focus order follows the visible workflow, and no status
is conveyed only by color or motion.

| Setting | Off/default | On | Notes and evidence |
| --- | --- | --- | --- |
| VoiceOver | [ ] | [ ] | |
| Full Keyboard Access | [ ] | [ ] | |
| Increase Contrast | [ ] | [ ] | |
| Differentiate Without Color | [ ] | [ ] | |
| Reduce Transparency | [ ] | [ ] | |
| Reduce Motion | [ ] | [ ] | |

## VoiceOver checks

- [ ] Sidebar destinations announce a concise name and can be selected.
- [ ] The current recovery step and scan metrics announce their names and values.
- [ ] Source choice, scan profile, scan, cancel, filter, search, table selection,
  preview, and export controls have an understandable order.
- [ ] Recovery session rows announce source, status, profile, result count, and
  update time before opening.
- [ ] Device rows announce the card name, size, connection, source type, and BSD
  device path before selection.
- [ ] Authorization, imaging, cancellation, failure, completion, remount, and
  eject states are announced without requiring visual inspection.
- [ ] Validation labels and explanations distinguish readable, preview-readable,
  unchecked, and possibly-partial files without overstating integrity.
- [ ] Alerts and destructive cleanup confirmation receive focus and read their
  complete consequences.

## Keyboard checks

- [ ] Starting at launch, Tab and Shift-Tab reach every enabled interactive
  control in a predictable order when Full Keyboard Access is enabled.
- [ ] Arrow keys operate sidebar, list, table, segmented picker, and row selection.
- [ ] Space or Return activates the focused control without moving focus
  unexpectedly.
- [ ] Command-O, Escape, Command-Shift-E, and Command-R work only when their
  corresponding actions are available.
- [ ] Focus remains visible at default, increased-contrast, and reduced-
  transparency settings.

## Layout and appearance checks

- [ ] At the largest Accessibility text size, essential labels do not truncate
  ambiguously and actions remain reachable by scrolling or resizing the window.
- [ ] Light and dark appearances preserve readable text, focus rings, validation
  states, disabled controls, and selected rows.
- [ ] Increased contrast and Differentiate Without Color preserve every status
  distinction.
- [ ] Reduce Motion introduces no required motion, hidden delay, or loss of state.
