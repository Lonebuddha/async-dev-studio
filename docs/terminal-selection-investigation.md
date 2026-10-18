# Terminal selection investigation — 2026-10-16

Implementation follow-up: the coordinate correction, precise mouse-down anchor, output reconciliation, and Shift-drag override are now part of the reproducible dependency patches. Native regression tests cover scrollback, reverse dragging, double-click selection, history rollover, incoming output, overwritten/evicted selections, alternate-buffer switches, and mouse-reporting modes 1000, 1002, and 1003. The research observations below describe the original behavior before these fixes.

## Result

Reproduced the reported delayed inability to select text using synthetic output in the same AppKit terminal view as the application. The primary defect is a duplicated scrollback offset in SwiftTerm 1.5.1 mouse-coordinate handling. A separate behavior clears an active selection whenever output arrives. The earlier copy fix corrected selection text extraction but did not address either of these cases.

The saved PMCA / Dev DB channel configuration starts a normal SSH session with a local database port forward. No database connection or SSH session was started during this investigation, and no credentials or live terminal output were collected. These findings reproduce the symptoms locally; the exact current mode and output stream of the user's running session were not inspected.

## Reproduction and evidence

The native research probe creates a terminal view without a shell and feeds numbered lines into it. It sends AppKit mouse events to select the visible top line. It does not access the clipboard.

| Case | Text visible under pointer | Selection before experimental correction | Selection after correction |
| --- | --- | --- | --- |
| Fresh terminal | ROW_000 | ROW_000 | ROW_000 |
| After 100 lines, drag | ROW_071 | Empty | ROW_071 |
| After 100 lines, double-click | ROW_071 | Empty | ROW_071 |
| Scroll upward 20 lines, drag | ROW_051 | Empty | ROW_051 |

The viewport used in the probe is 30 rows tall. Elapsed time is not the trigger: accumulated output moves the viewport into scrollback. With no scrollback offset, the calculation happens to work.

In `MacTerminalView.swift`, `calculateMouseHit(at:)` adds `terminal.buffer.yDisp` to the screen row. Selection callers then apply this same offset again: dragging uses screen-relative SelectionService methods; double-click selection explicitly adds it. As a result, the selected buffer row differs from the visible row and can exceed available history. Mouse reporting to terminal applications also needs screen-relative coordinates.

For validation, the experiment removed that first offset addition from the local dependency checkout, ran the identical probe, then restored the original source. All four cases returned the expected text after the correction. The existing 70 default tests and the research probe completed successfully in both runs; the probe reports observations rather than asserting that known defects are fixed.

## Additional findings

1. **Incoming output clears selection.** `AppleTerminalView.feedPrepare()` unconditionally sets `selection.active = false`; `MacTerminalView.linefeed(source:)` also clears it. A single carriage return changed selection from active to inactive in the probe. Logs, progress updates, or remote output can therefore interrupt a drag or remove a selection before Copy.
2. **Application mouse reporting takes over selection.** Sending the normal terminal escape sequence to enable mouse reporting stopped local drag selection. Disabling `allowMouseReporting` restored it after the coordinate correction. This is an additional possible cause after mouse-aware programs run; there is no evidence that it is the cause in the user's live SSH session. Plain SSH and local port forwarding do not by themselves establish that such a mode was enabled.
3. **Previous coverage was too narrow.** The earlier copy regression used short output in a fresh terminal. It never exercised scrollback or output arriving during selection.

## Proposed implementation

- Keep mouse-hit rows screen-relative and apply the scrollback offset exactly once where buffer coordinates are required. Add regression assertions for normal dragging, reverse dragging, double-click, and scrolled viewports, including history rollover.
- Preserve selection across unrelated output. Handle scrolling, overwritten selected lines, and history eviction deliberately rather than simply removing every invalidation; verify that copied text still matches the highlighted region.
- Offer a deliberate way to select text while an application has requested mouse reporting, with tests that ordinary application mouse input still works.

For the coordinate correction, use the existing reproducible dependency-patching process and test a fresh dependency resolution. A dependency upgrade should be separately assessed rather than assumed to contain these fixes.

## Running the research probe

From the repository root:

```sh
STUDIO_TERMINAL_SELECTION_RESEARCH=1 macos/scripts/test.sh
```

The probe is `macos/Tests/TerminalPluginTests/SelectionResearch.swift`. It reports the current implementation's behavior using fixture text only. The initial investigation did not change the installed application; fixes were implemented in the subsequent follow-up.

In builds preceding the follow-up fixes, Select All followed by Copy avoids the mouse-coordinate defect, but copies the entire buffer and can still be interrupted by incoming output. Avoid closing a live SSH tunnel merely to reset terminal selection.
