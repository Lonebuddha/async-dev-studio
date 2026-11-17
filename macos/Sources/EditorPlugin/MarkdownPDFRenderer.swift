import AppKit

/// Uses the system Markdown parser and TextKit; exporting requires no external tools.
@MainActor
enum MarkdownPDFRenderer {
    private static let pageSize = NSSize(width: 595.28, height: 841.89)
    private static let margin: CGFloat = 48
    private static let ink = NSColor(calibratedWhite: 0.12, alpha: 1)

    static func render(_ markdown: String, title: String) throws -> Data {
        let storage = NSTextStorage(attributedString: try styledMarkdown(markdown))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox,
                  [kCGPDFContextTitle: title, kCGPDFContextCreator: "Async Dev Studio"] as CFDictionary) else {
            throw EditorError.pdfConversionFailed
        }
        var nextGlyph = 0
        var page = 0
        repeat {
            let container = NSTextContainer(size: NSSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = pageGlyphRange(layout: layout, container: container, storage: storage)
            guard storage.length == 0 || NSMaxRange(range) > nextGlyph else {
                context.closePDF()
                throw EditorError.pdfConversionFailed
            }
            page += 1
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: NSPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: range, at: NSPoint(x: margin, y: margin))
            let footer = NSAttributedString(string: "\(page)", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1)
            ])
            footer.draw(at: NSPoint(x: (pageSize.width - footer.size().width) / 2, y: pageSize.height - 30))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            nextGlyph = NSMaxRange(range)
        } while nextGlyph < layout.numberOfGlyphs
        context.closePDF()
        return data as Data
    }

    private static func pageGlyphRange(layout: NSLayoutManager, container: NSTextContainer, storage: NSTextStorage) -> NSRange {
        var range = layout.glyphRange(for: container)
        // Move a trailing heading to the next page together with its first body line.
        while range.length > 0, NSMaxRange(range) < layout.numberOfGlyphs {
            let characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            let text = storage.string as NSString
            var end = NSMaxRange(characters)
            while end > characters.location {
                guard let scalar = UnicodeScalar(text.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
                end -= 1
            }
            guard end > characters.location,
                  let style = storage.attribute(.paragraphStyle, at: end - 1, effectiveRange: nil) as? NSParagraphStyle,
                  style.headerLevel > 0 else { break }
            let heading = text.paragraphRange(for: NSRange(location: end - 1, length: 0))
            let glyphs = layout.glyphRange(forCharacterRange: heading, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: NSIntersectionRange(glyphs, range), in: container)
            guard rect.minY > 40, rect.minY < container.size.height else { break }
            container.size.height = rect.minY
            range = layout.glyphRange(for: container)
        }
        return range
    }

    private static func styledMarkdown(_ markdown: String) throws -> NSAttributedString {
        let parsed = try AttributedString(markdown: markdown)
        let result = NSMutableAttributedString(string: "")
        var blockID: Int?
        var paragraph = NSMutableParagraphStyle()
        var blockFont = NSFont.systemFont(ofSize: 11)
        var blockColor = ink
        var codeBlock = false
        var tables: [Int: NSTextTable] = [:]
        var seenListItems: Set<Int> = []

        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            if blockID != components.first?.identity || result.length == 0 {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: blockFont, .paragraphStyle: paragraph]))
                }
                blockID = components.first?.identity
                paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 3
                paragraph.paragraphSpacing = 9
                paragraph.lineBreakMode = .byWordWrapping
                blockFont = NSFont.systemFont(ofSize: 11)
                blockColor = ink
                codeBlock = false
                var listItem: PresentationIntent.IntentType?
                var orderedList = false
                var depth = 0
                var tableColumns: [PresentationIntent.TableColumn] = []
                var tableID: Int?
                var row = 0
                var column = 0
                var header = false

                for component in components.reversed() {
                    switch component.kind {
                    case .header(let level):
                        blockFont = NSFont.systemFont(ofSize: [25, 20, 16, 13, 12, 11][min(max(level - 1, 0), 5)], weight: .bold)
                        paragraph.paragraphSpacingBefore = 12
                        paragraph.paragraphSpacing = 8
                        paragraph.headerLevel = level
                    case .orderedList: orderedList = true; depth += 1
                    case .unorderedList: orderedList = false; depth += 1
                    case .listItem: listItem = component
                    case .codeBlock:
                        codeBlock = true
                        blockFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
                        paragraph.headIndent = 10
                        paragraph.firstLineHeadIndent = 10
                        paragraph.tailIndent = -10
                        paragraph.lineSpacing = 2
                    case .blockQuote:
                        paragraph.headIndent += 18
                        paragraph.firstLineHeadIndent += 18
                        blockColor = NSColor(calibratedWhite: 0.38, alpha: 1)
                    case .thematicBreak: blockColor = NSColor(calibratedWhite: 0.65, alpha: 1)
                    case .table(let columns): tableID = component.identity; tableColumns = columns
                    case .tableHeaderRow: header = true
                    case .tableRow(let index): row = index
                    case .tableCell(let index): column = index
                    default: break
                    }
                }
                if let item = listItem, case .listItem(let ordinal) = item.kind {
                    let indent = paragraph.headIndent + CGFloat(depth) * 20
                    paragraph.headIndent = indent
                    paragraph.firstLineHeadIndent = indent
                    paragraph.paragraphSpacing = 4
                    if seenListItems.insert(item.identity).inserted {
                        paragraph.firstLineHeadIndent = indent - 16
                        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                        result.append(NSAttributedString(string: orderedList ? "\(ordinal).\t" : "•\t", attributes: [
                            .font: blockFont, .foregroundColor: blockColor, .paragraphStyle: paragraph
                        ]))
                    }
                }
                if let tableID, !tableColumns.isEmpty {
                    let table: NSTextTable
                    if let existing = tables[tableID] { table = existing }
                    else {
                        table = NSTextTable()
                        table.numberOfColumns = tableColumns.count
                        table.layoutAlgorithm = .fixedLayoutAlgorithm
                        table.collapsesBorders = true
                        table.setContentWidth(100, type: .percentageValueType)
                        tables[tableID] = table
                    }
                    let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cell.setContentWidth(100 / CGFloat(tableColumns.count), type: .percentageValueType)
                    cell.setWidth(6, type: .absoluteValueType, for: .padding)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(NSColor(calibratedWhite: 0.8, alpha: 1))
                    if header {
                        cell.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1)
                        blockFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
                    }
                    paragraph.textBlocks = [cell]
                    paragraph.paragraphSpacing = 0
                    paragraph.lineSpacing = 2
                    if column < tableColumns.count {
                        switch tableColumns[column].alignment {
                        case .center: paragraph.alignment = .center
                        case .right: paragraph.alignment = .right
                        default: break
                        }
                    }
                }
            }

            let inline = run.inlinePresentationIntent ?? []
            var font = blockFont
            if inline.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: blockFont.pointSize * 0.92, weight: .regular) }
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: blockColor, .paragraphStyle: paragraph]
            if codeBlock || inline.contains(.code) { attributes[.backgroundColor] = NSColor(calibratedWhite: 0.95, alpha: 1) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor(calibratedRed: 0.12, green: 0.29, blue: 0.58, alpha: 1)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            // Images use their alt text; do not fetch remote resources during export.
            var text = String(parsed[run.range].characters)
            if codeBlock, text.hasSuffix("\n") { text.removeLast() }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }
}
