import Foundation
import SwiftData
import AppKit

@MainActor
enum ConversationExporter {

    // MARK: - Codable Transfer Types

    struct ExportedConversation: Codable {
        let id: String
        let title: String
        let createdAt: Date
        let updatedAt: Date
        let messages: [ExportedMessage]
    }

    struct ExportedMessage: Codable {
        let id: String
        let role: String
        let content: String
        let timestamp: Date
        let attachments: [ExportedAttachment]
    }

    struct ExportedAttachment: Codable {
        let kind: String
        let originalName: String
    }

    // MARK: - JSON Export

    static func exportJSON(conversation: Conversation) throws -> Data {
        guard !conversation.isDeleted, conversation.modelContext != nil else {
            throw NSError(domain: "ConversationExporter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Conversation is no longer available"])
        }

        let sorted = conversation.messages
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .sorted { $0.timestamp < $1.timestamp }

        let exported = ExportedConversation(
            id: conversation.id.uuidString,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            messages: sorted.map { msg in
                ExportedMessage(
                    id: msg.id.uuidString,
                    role: msg.role.rawValue,
                    content: msg.content,
                    timestamp: msg.timestamp,
                    attachments: msg.attachments
                        .filter { !$0.isDeleted && $0.modelContext != nil }
                        .map { att in
                            ExportedAttachment(kind: att.kind.rawValue, originalName: att.originalName)
                        }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exported)
    }

    // MARK: - Markdown Export

    static func exportMarkdown(conversation: Conversation) -> String {
        guard !conversation.isDeleted, conversation.modelContext != nil else { return "" }

        var md = "# \(conversation.title)\n\n"
        let sorted = conversation.messages
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .sorted { $0.timestamp < $1.timestamp }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        for message in sorted {
            let role = message.role == .user ? "**You**" : "**Assistant**"
            let time = dateFormatter.string(from: message.timestamp)
            md += "### \(role) — \(time)\n\n"

            for attachment in message.attachments where !attachment.isDeleted && attachment.modelContext != nil {
                md += "> Attachment: \(attachment.originalName) (\(attachment.kind.rawValue))\n\n"
            }

            if !message.content.isEmpty {
                md += message.content + "\n\n"
            }
            md += "---\n\n"
        }
        return md
    }

    // MARK: - JSON Import

    static func importJSON(data: Data, into context: ModelContext) throws -> Conversation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(ExportedConversation.self, from: data)

        let conversation = Conversation(title: exported.title)
        conversation.createdAt = exported.createdAt
        conversation.updatedAt = exported.updatedAt

        context.insert(conversation)

        for msg in exported.messages {
            let role = MessageRole(rawValue: msg.role) ?? .user
            let message = Message(role: role, content: msg.content)
            message.timestamp = msg.timestamp
            for expAtt in msg.attachments {
                let kind = AttachmentKind(rawValue: expAtt.kind) ?? .text
                let att = Attachment(kind: kind, storedName: "", originalName: expAtt.originalName)
                message.attachments.append(att)
            }
            conversation.messages.append(message)
        }

        try context.save()
        return conversation
    }

    // MARK: - PDF Export

    static func exportPDF(conversation: Conversation, pageWidth: CGFloat = 612) -> Data? {
        guard !conversation.isDeleted, conversation.modelContext != nil else { return nil }

        let sorted = conversation.messages
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .sorted { $0.timestamp < $1.timestamp }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let bodyFont = NSFont.systemFont(ofSize: 12)
        let boldFont = NSFont.boldSystemFont(ofSize: 12)
        let titleFont = NSFont.boldSystemFont(ofSize: 18)
        let headerFont = NSFont.boldSystemFont(ofSize: 13)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let captionFont = NSFont.systemFont(ofSize: 10)
        let separatorColor = NSColor.separatorColor

        let result = NSMutableAttributedString()

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.labelColor]
        result.append(NSAttributedString(string: conversation.title + "\n\n", attributes: titleAttrs))

        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: NSColor.secondaryLabelColor]
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.controlBackgroundColor
        ]
        let captionAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: NSColor.tertiaryLabelColor]

        for message in sorted {
            let roleName = message.role == .user ? "You" : "Assistant"
            let time = dateFormatter.string(from: message.timestamp)
            result.append(NSAttributedString(string: "\(roleName) — \(time)\n", attributes: headerAttrs))

            for attachment in message.attachments where !attachment.isDeleted && attachment.modelContext != nil {
                result.append(NSAttributedString(string: "📎 \(attachment.originalName) (\(attachment.kind.rawValue))\n", attributes: captionAttrs))
            }

            if !message.content.isEmpty {
                let segments = parseMarkdown(message.content)
                for segment in segments {
                    switch segment {
                    case .text(let text):
                        let rendered = Self.markdownToNSAttributedString(text, baseFont: bodyFont)
                        result.append(rendered)
                        result.append(NSAttributedString(string: "\n"))
                    case .codeBlock(let code, let lang):
                        if let lang {
                            result.append(NSAttributedString(string: "\(lang):\n", attributes: captionAttrs))
                        }
                        result.append(NSAttributedString(string: code + "\n", attributes: codeAttrs))
                    case .header(let text, let level):
                        let hFont: NSFont
                        switch level {
                        case 1: hFont = NSFont.boldSystemFont(ofSize: 18)
                        case 2: hFont = NSFont.boldSystemFont(ofSize: 16)
                        case 3: hFont = NSFont.boldSystemFont(ofSize: 14)
                        default: hFont = NSFont.boldSystemFont(ofSize: 13)
                        }
                        let rendered = Self.markdownToNSAttributedString(text, baseFont: hFont)
                        result.append(rendered)
                        result.append(NSAttributedString(string: "\n"))
                    case .table(let rows):
                        guard !rows.isEmpty else { break }
                        let colCount = rows.map(\.count).max() ?? 0
                        guard colCount > 0 else { break }

                        let table = NSTextTable()
                        table.numberOfColumns = colCount
                        table.setContentWidth(100, type: .percentageValueType)

                        let borderColor = NSColor.separatorColor
                        let headerBg = NSColor.controlBackgroundColor

                        for (rowIdx, row) in rows.enumerated() {
                            for colIdx in 0..<colCount {
                                let cellText = colIdx < row.count ? row[colIdx] : ""
                                let cellFont = rowIdx == 0 ? boldFont : bodyFont

                                let block = NSTextTableBlock(table: table, startingRow: rowIdx, rowSpan: 1, startingColumn: colIdx, columnSpan: 1)
                                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                                block.setBorderColor(borderColor)
                                block.setWidth(4, type: .absoluteValueType, for: .padding)
                                if rowIdx == 0 {
                                    block.backgroundColor = headerBg
                                }

                                let cellParagraph = NSMutableParagraphStyle()
                                cellParagraph.textBlocks = [block]

                                let cellAttr = Self.markdownToNSAttributedString(cellText, baseFont: cellFont)
                                let mutable = NSMutableAttributedString(attributedString: cellAttr)
                                mutable.addAttribute(.paragraphStyle, value: cellParagraph, range: NSRange(location: 0, length: mutable.length))
                                // Ensure trailing newline for each cell
                                if !cellText.hasSuffix("\n") {
                                    let nlAttr = NSMutableAttributedString(string: "\n")
                                    nlAttr.addAttribute(.paragraphStyle, value: cellParagraph, range: NSRange(location: 0, length: 1))
                                    nlAttr.addAttribute(.font, value: cellFont, range: NSRange(location: 0, length: 1))
                                    mutable.append(nlAttr)
                                }
                                result.append(mutable)
                            }
                        }
                        result.append(NSAttributedString(string: "\n"))
                    }
                }
            }
            result.append(NSAttributedString(string: "\n", attributes: bodyAttrs))

            // Separator line
            let separator = NSMutableAttributedString(string: "─────────────────────────────────\n\n", attributes: [:])
            separator.addAttribute(.foregroundColor, value: separatorColor, range: NSRange(location: 0, length: separator.length))
            separator.addAttribute(.font, value: captionFont, range: NSRange(location: 0, length: separator.length))
            result.append(separator)
        }

        // Render to PDF via NSTextView
        let margin: CGFloat = 40
        let textWidth = pageWidth - margin * 2
        let textStorage = NSTextStorage(attributedString: result)
        let textContainer = NSTextContainer(containerSize: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let totalHeight = usedRect.height + margin * 2

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: totalHeight))
        textView.textContainerInset = NSSize(width: margin, height: margin)
        textView.textStorage?.setAttributedString(result)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        return textView.dataWithPDF(inside: textView.bounds)
    }

    /// Converts a markdown string to NSAttributedString with inline formatting
    /// (bold, italic, strikethrough, inline code, links). Falls back to plain text.
    private static func markdownToNSAttributedString(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let cleaned = text
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let swiftAttr = try? AttributedString(markdown: cleaned, options: options) {
            let nsAttr = NSMutableAttributedString(swiftAttr)
            // Apply base font to ranges that don't have explicit font attributes
            let fullRange = NSRange(location: 0, length: nsAttr.length)
            nsAttr.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                if let existingFont = value as? NSFont {
                    // Preserve bold/italic traits from markdown, but use base font size
                    let traits = NSFontManager.shared.traits(of: existingFont)
                    var newFont = baseFont
                    if traits.contains(.boldFontMask) {
                        newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .boldFontMask)
                    }
                    if traits.contains(.italicFontMask) {
                        newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask)
                    }
                    nsAttr.addAttribute(.font, value: newFont, range: range)
                } else {
                    nsAttr.addAttribute(.font, value: baseFont, range: range)
                }
            }
            nsAttr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
            return nsAttr
        }
        return NSAttributedString(string: cleaned, attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])
    }

    // MARK: - Bulk Export (ZIP)

    static func exportBulkZIP(conversations: [Conversation]) async throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for conversation in conversations {
            let data = try exportJSON(conversation: conversation)
            let safeName = conversation.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(50)
            let fileName = "\(safeName).json"
            try data.write(to: tempDir.appendingPathComponent(fileName))
        }

        // Create ZIP using ditto (built-in macOS tool)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, zipURL.path]
        try process.run()
        await Task.detached {
            process.waitUntilExit()
        }.value
        guard !Task.isCancelled else {
            if process.isRunning { process.terminate() }
            throw CancellationError()
        }

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ConversationExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create ZIP archive"])
        }

        let data = try Data(contentsOf: zipURL)
        return data
    }
}
