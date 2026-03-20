import SwiftUI

// MARK: - Markdown Segment

enum MarkdownSegment: Equatable {
    /// Inline markdown text (bold, italic, code spans, links, etc.)
    case text(String)
    /// Fenced code block with optional language tag
    case codeBlock(String, String?)
    /// Header with level 1-6
    case header(String, Int)
    /// Table: rows of cells, first row is header
    case table([[String]])
}

// MARK: - Markdown Parser

/// Parses markdown content into segments for rendering.
/// Handles fenced code blocks, headers, and groups consecutive
/// text lines (including lists) into text segments for inline rendering.
func parseMarkdown(_ content: String) -> [MarkdownSegment] {
    let lines = content.components(separatedBy: "\n")
    var segments: [MarkdownSegment] = []
    var currentTextLines: [String] = []
    var inCodeBlock = false
    var codeBlockLines: [String] = []
    var codeBlockLanguage: String?
    var currentTableLines: [String] = []

    func flushTextLines() {
        guard !currentTextLines.isEmpty else { return }
        // Trim trailing empty lines but preserve internal structure
        var trimmed = currentTextLines
        while trimmed.last?.isEmpty == true {
            trimmed.removeLast()
        }
        if !trimmed.isEmpty {
            segments.append(.text(trimmed.joined(separator: "\n")))
        }
        currentTextLines.removeAll()
    }

    func flushTableLines() {
        guard !currentTableLines.isEmpty else { return }
        var rows: [[String]] = []
        for tableLine in currentTableLines {
            let trimmed = tableLine.trimmingCharacters(in: .whitespaces)
            // Skip separator lines (e.g., "|---|---|")
            let stripped = trimmed.replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }

            let cells = trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .dropFirst() // leading empty from "|"
                .dropLast()  // trailing empty from "|"
                .map { String($0) }
            if !cells.isEmpty {
                rows.append(cells)
            }
        }
        if !rows.isEmpty {
            segments.append(.table(rows))
        }
        currentTableLines.removeAll()
    }

    /// Returns true if the line looks like part of a markdown table (contains `|`).
    func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && (trimmed.hasPrefix("|") || trimmed.hasSuffix("|"))
    }

    for line in lines {
        if inCodeBlock {
            if line.hasPrefix("```") {
                // End of code block
                let code = codeBlockLines.joined(separator: "\n")
                segments.append(.codeBlock(code, codeBlockLanguage))
                codeBlockLines.removeAll()
                codeBlockLanguage = nil
                inCodeBlock = false
            } else {
                codeBlockLines.append(line)
            }
            continue
        }

        // Check for code block start
        if line.hasPrefix("```") {
            flushTextLines()
            flushTableLines()
            inCodeBlock = true
            let langTag = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            codeBlockLanguage = langTag.isEmpty ? nil : langTag
            continue
        }

        // Check for headers (# through ######)
        if let headerMatch = parseHeader(line) {
            flushTextLines()
            flushTableLines()
            segments.append(.header(headerMatch.text, headerMatch.level))
            continue
        }

        // Check for table lines (lines containing | separators)
        if isTableLine(line) {
            flushTextLines()
            currentTableLines.append(line)
            continue
        }

        // If we were accumulating table lines and hit a non-table line, flush the table
        if !currentTableLines.isEmpty {
            flushTableLines()
        }

        // Convert list markers to visual bullets/numbers so AttributedString
        // doesn't misinterpret `* text` as italic emphasis.
        currentTextLines.append(normalizeListLine(line))
    }

    // Handle unclosed code block — treat as text
    if inCodeBlock {
        currentTextLines.append("```" + (codeBlockLanguage ?? ""))
        currentTextLines.append(contentsOf: codeBlockLines)
        inCodeBlock = false
    }

    flushTableLines()
    flushTextLines()
    return segments
}

/// Measures the indent level of a line (number of leading spaces, tabs count as 4).
private func indentLevel(_ line: String) -> Int {
    var count = 0
    for ch in line {
        if ch == " " { count += 1 }
        else if ch == "\t" { count += 4 }
        else { break }
    }
    return count
}

/// Visual indent string for a given nesting depth.
/// Each level adds 3 non-breaking spaces for clear visual nesting.
private func visualIndent(depth: Int) -> String {
    String(repeating: "\u{00A0}\u{00A0}\u{00A0}", count: depth)
}

/// Converts markdown list markers to visual representations so that
/// `AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace`
/// doesn't misinterpret `* text` as italic or `1. text` as plain text.
///
/// Handles nested lists by measuring indent depth and producing proportional
/// visual indentation. Supports `- `, `* `, `+ ` (unordered) and `1. `, `2) ` (ordered).
private func normalizeListLine(_ line: String) -> String {
    let spaces = indentLevel(line)
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    let depth = spaces / 2

    // Unordered: `- `, `* `, `+ ` at start (after optional indent)
    for prefix in ["- ", "* ", "+ "] {
        if trimmed.hasPrefix(prefix) {
            return "\(visualIndent(depth: depth))• \(trimmed.dropFirst(2))"
        }
    }

    // Ordered: `1. `, `2. `, `10. ` or `1) `, `2) ` etc.
    var i = trimmed.startIndex
    while i < trimmed.endIndex && trimmed[i].isNumber {
        i = trimmed.index(after: i)
    }
    if i > trimmed.startIndex && i < trimmed.endIndex {
        let afterDigits = trimmed[i]
        let rest = trimmed.index(after: i)
        if (afterDigits == "." || afterDigits == ")") && rest < trimmed.endIndex && trimmed[rest] == " " {
            let number = trimmed[trimmed.startIndex..<i]
            let content = trimmed[trimmed.index(after: rest)...]
            return "\(visualIndent(depth: depth))\(number). \(content)"
        }
    }

    return line
}

/// Parses a header line. Returns (text, level) or nil if not a header.
private func parseHeader(_ line: String) -> (text: String, level: Int)? {
    // Must start with 1-6 # characters followed by a space
    var level = 0
    for ch in line {
        if ch == "#" {
            level += 1
        } else {
            break
        }
    }
    guard level >= 1, level <= 6 else { return nil }
    let rest = line.dropFirst(level)
    guard rest.first == " " else { return nil }
    let text = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return (text, level)
}

// MARK: - Markdown Content View

/// Renders markdown content as a vertical stack of segments.
/// Uses SwiftUI's native `AttributedString(markdown:)` for inline formatting
/// and a custom `CodeBlockView` for fenced code blocks.
struct MarkdownContentView: View {
    let content: String
    let fontSize: CGFloat
    @State private var cachedSegments: [MarkdownSegment]?
    @State private var cachedContentLength: Int = 0

    private var segments: [MarkdownSegment] {
        cachedSegments ?? parseMarkdown(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let md):
                    Text(Self.markdownAttributedString(from: md))
                        .font(.system(size: fontSize))
                        .textSelection(.enabled)

                case .codeBlock(let code, let lang):
                    CodeBlockView(code: code, language: lang, fontSize: fontSize)

                case .header(let text, let level):
                    Text(Self.markdownAttributedString(from: text))
                        .font(headerFont(level: level))
                        .textSelection(.enabled)

                case .table(let rows):
                    TableView(rows: rows, fontSize: fontSize)
                }
            }
        }
        .task(id: content.count) {
            if cachedSegments == nil || content.count != cachedContentLength {
                cachedSegments = parseMarkdown(content)
                cachedContentLength = content.count
            }
        }
    }

    static func markdownAttributedString(from text: String) -> AttributedString {
        let cleaned = text
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: cleaned, options: options) {
            return attributed
        }
        return AttributedString(cleaned)
    }

    private func headerFont(level: Int) -> Font {
        switch level {
        case 1: return .system(size: fontSize * 1.6, weight: .bold)
        case 2: return .system(size: fontSize * 1.4, weight: .bold)
        case 3: return .system(size: fontSize * 1.2, weight: .semibold)
        case 4: return .system(size: fontSize * 1.1, weight: .semibold)
        case 5: return .system(size: fontSize * 1.0, weight: .medium)
        default: return .system(size: fontSize * 0.95, weight: .medium)
        }
    }
}

// MARK: - Table View

/// Renders a markdown table as a simple grid with header row bold and thin separators.
struct TableView: View {
    let rows: [[String]]
    let fontSize: CGFloat

    var body: some View {
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(0..<columnCount, id: \.self) { colIndex in
                            let cellText = colIndex < row.count ? row[colIndex] : ""
                            Text(MarkdownContentView.markdownAttributedString(from: cellText))
                                .font(.system(size: fontSize, weight: rowIndex == 0 ? .semibold : .regular))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }

                    if rowIndex == 0 {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        )
    }
}

// MARK: - Code Block View

/// Renders a fenced code block with a monospaced font, dark background,
/// optional language label, and a copy button.
struct CodeBlockView: View {
    let code: String
    let language: String?
    let fontSize: CGFloat
    @State private var isHovering = false
    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Language header bar (shown when language is specified)
            if let language {
                HStack {
                    Text(language)
                        .font(.system(size: fontSize * 0.85))
                        .foregroundStyle(.secondary)
                    Spacer()
                    copyButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(codeHeaderBackground)
            }

            // Code content
            Text(code)
                .font(.system(size: fontSize * 0.9, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(codeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .overlay(alignment: .topTrailing) {
            // Floating copy button when no language header
            if language == nil {
                copyButton
                    .padding(6)
                    .opacity(isHovering ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
            }
        }
    }

    private var codeBlockBackground: some ShapeStyle {
        // Slightly darker than surrounding bubble
        Color(nsColor: .textBackgroundColor).opacity(0.3)
    }

    private var codeHeaderBackground: some ShapeStyle {
        Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            showCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopied = false
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: fontSize * 0.85))
                    .foregroundStyle(showCopied ? .green : .secondary)
                if showCopied {
                    Text("Copied")
                        .font(.system(size: fontSize * 0.75))
                        .foregroundStyle(.green)
                }
            }
        }
        .buttonStyle(.borderless)
        .help("Copy code")
    }
}
