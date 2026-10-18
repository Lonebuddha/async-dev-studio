#!/bin/sh
set -eu
macos_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift package --package-path "$macos_root" --disable-sandbox resolve
# Apply the reviewed SwiftTerm 1.5.1 selection fixes after fresh resolutions:
# extraction endpoints, screen-relative mouse coordinates, output reconciliation,
# and Shift-drag selection while an application has requested mouse reporting.
python3 - "$macos_root/.build/checkouts/SwiftTerm/Sources/SwiftTerm/SelectionService.swift" <<'PY'
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
original = '''let max = if Position.compare(start, end) == .after {
            end
        } else {
            start
        }'''
corrected = '''let max = if Position.compare(start, end) == .after {
            start
        } else {
            end
        }'''
if source.count(original) == 1:
    mode = stat.S_IMODE(path.stat().st_mode)
    try:
        path.chmod(mode | stat.S_IWUSR)
        path.write_text(source.replace(original, corrected, 1))
    finally:
        path.chmod(mode)
elif source.count(corrected) != 1:
    sys.exit('SwiftTerm selection patch no longer matches; review the dependency before building.')

def change(path, original, corrected):
    source = path.read_text()
    # Insertions retain the original anchor inside their replacement.
    if original in corrected and source.count(corrected) == 1:
        return
    if source.count(original) == 1:
        mode = stat.S_IMODE(path.stat().st_mode)
        try:
            path.chmod(mode | stat.S_IWUSR)
            path.write_text(source.replace(original, corrected, 1))
        finally:
            path.chmod(mode)
    elif source.count(corrected) != 1:
        sys.exit(f'SwiftTerm patch no longer matches {path.name}; review before building.')

root = path.parents[0]
mac = root / 'Mac/MacTerminalView.swift'
apple = root / 'Apple/AppleTerminalView.swift'
change(mac, '    public override func mouseDown(with event: NSEvent) {', '''    public override func mouseDown(with event: NSEvent) {
        // A SwiftUI tab update is not guaranteed when the user clicks back
        // after focusing another control. Restore the native input responder.
        if window?.attachedSheet == nil { window?.makeFirstResponder(self) }''')
change(mac,
       'let row = Int ((frame.height-point.y) / cellDimension.height) + terminal.buffer.yDisp',
       'let row = Int ((frame.height-point.y) / cellDimension.height)')
change(mac, '''    open func linefeed(source: Terminal) {
        selection.selectNone()
    }''', '''    open func linefeed(source: Terminal) {
        // Selection is reconciled against the buffer after output is parsed.
    }''')
change(mac, 'if allowMouseReporting && terminal.mouseMode.sendButtonPress()',
       'if allowMouseReporting && !event.modifierFlags.contains(.shift) && terminal.mouseMode.sendButtonPress()')
change(mac, 'if allowMouseReporting && terminal.mouseMode.sendButtonRelease()',
       'if allowMouseReporting && !event.modifierFlags.contains(.shift) && terminal.mouseMode.sendButtonRelease()')
change(mac, 'if allowMouseReporting {', 'if allowMouseReporting && !event.modifierFlags.contains(.shift) {')
change(mac, '''        case 1:
            if selection.active == true {
                if event.modifierFlags.contains(.shift) {
                    selection.shiftExtend(row: hit.row, col: hit.col)
                } else {
                    selection.active = false
                }
            }''', '''        case 1:
            if selection.active && event.modifierFlags.contains(.shift) {
                selection.shiftExtend(row: hit.row, col: hit.col)
            } else {
                selection.setSoftStart(row: hit.row, col: hit.col)
            }''')
change(apple, '''        search.invalidate()
        selection.active = false
        startDisplayUpdates()''', '''        search.invalidate()
        #if os(macOS)
        selection.beginOutput()
        #else
        selection.active = false
        #endif
        startDisplayUpdates()''')
change(apple, '''    func feedFinish ()
    {
        suspendDisplayUpdates ()''', '''    func feedFinish ()
    {
        #if os(macOS)
        selection.endOutput()
        #endif
        suspendDisplayUpdates ()''')
change(path, '    public func getSelectedText () -> String {', '''    // Keep buffer-relative selection anchors while output scrolls or evicts history.
    private var outputSnapshot: (buffer: Buffer, top: Int, start: Position, end: Position,
                                 pivot: Position?, first: BufferLine, last: BufferLine, text: String)?

    func beginOutput() {
        outputSnapshot = nil
        guard active else { return }
        let buffer = terminal.buffer
        guard start.row >= 0, start.row < buffer.lines.count,
              end.row >= 0, buffer.lines.count > 0 else { selectNone(); return }
        let boundedEnd = Position(col: end.col, row: min(end.row, buffer.lines.count - 1))
        outputSnapshot = (buffer, buffer.linesTop, start, boundedEnd, pivot,
                          buffer.lines[start.row], buffer.lines[boundedEnd.row], getSelectedText())
    }

    func endOutput() {
        guard let saved = outputSnapshot else { return }
        defer { outputSnapshot = nil }
        guard active else { return }
        let buffer = terminal.buffer
        let delta = buffer.linesTop - saved.top
        let firstRow = saved.start.row - delta
        let lastRow = saved.end.row - delta
        guard buffer === saved.buffer, delta >= 0,
              firstRow >= 0, lastRow >= 0,
              firstRow < buffer.lines.count, lastRow < buffer.lines.count,
              buffer.lines[firstRow] === saved.first, buffer.lines[lastRow] === saved.last else {
            selectNone()
            return
        }
        start = Position(col: saved.start.col, row: firstRow)
        end = Position(col: saved.end.col, row: lastRow)
        if let oldPivot = saved.pivot {
            pivot = oldPivot.row >= delta ? Position(col: oldPivot.col, row: oldPivot.row - delta) : nil
        }
        guard getSelectedText() == saved.text else { selectNone(); return }
        setActiveAndNotify()
    }

    public func getSelectedText () -> String {''')
PY
