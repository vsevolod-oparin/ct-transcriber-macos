import AppKit

// MARK: - Syntax Highlighter

/// Provides regex-based syntax highlighting for code blocks.
///
/// Applies coloring rules in a deliberate order so that higher-priority
/// tokens (strings, comments) override lower-priority ones (keywords inside
/// a string literal stay string-colored). The order is:
///
///   1. Types (PascalCase identifiers)
///   2. Keywords
///   3. Numbers
///   4. Decorators / annotations
///   5. Strings (override keywords/types inside them)
///   6. Comments (override everything inside them)
///
/// Results are cached by a composite key of code content + font size + appearance
/// to avoid redundant work on re-renders.
enum SyntaxHighlighter {

    // MARK: - Token Colors

    /// Semantic color palette that adapts to light/dark appearance automatically
    /// via `NSColor` system colors.
    private enum TokenColor {
        static let keyword    = NSColor.systemPink
        static let string     = NSColor.systemOrange
        static let comment    = NSColor.systemGray
        static let number     = NSColor.systemPurple
        static let type       = NSColor.systemTeal
        static let decorator  = NSColor.systemBrown
    }

    // MARK: - Keyword Sets

    /// Language keywords grouped loosely. Covers Swift, Python, JavaScript/TypeScript,
    /// C/C++, Rust, Go, Java, Ruby, and shell builtins at a "good enough" level.
    private static let keywords: Set<String> = [
        // Swift
        "func", "var", "let", "class", "struct", "enum", "protocol", "extension",
        "if", "else", "for", "while", "repeat", "return", "import", "guard",
        "switch", "case", "default", "break", "continue", "fallthrough",
        "try", "catch", "throw", "throws", "rethrows", "do",
        "async", "await", "actor", "nonisolated", "sending",
        "public", "private", "internal", "fileprivate", "open",
        "static", "final", "override", "mutating", "nonmutating", "lazy",
        "weak", "unowned", "inout", "some", "any",
        "self", "Self", "super", "init", "deinit", "subscript",
        "true", "false", "nil",
        "where", "typealias", "associatedtype",
        "get", "set", "willSet", "didSet",
        "is", "as", "in",
        "#if", "#else", "#elseif", "#endif", "#selector", "#available",
        "@objc", "@escaping", "@autoclosure", "@discardableResult",
        "@MainActor", "@Sendable", "@Published", "@State", "@Binding",
        "@ObservedObject", "@StateObject", "@EnvironmentObject", "@Environment",
        "@ViewBuilder", "@available", "@unknown",
        // Python
        "def", "lambda", "yield", "from", "with", "pass", "raise",
        "and", "or", "not", "del", "global", "nonlocal", "assert",
        "except", "finally", "elif", "None", "True", "False",
        "print", "range", "len", "type", "list", "dict", "set", "tuple",
        // JavaScript / TypeScript
        "const", "function", "new", "this", "typeof", "instanceof",
        "undefined", "null", "export", "require", "module",
        "interface", "implements", "abstract", "declare",
        "of", "debugger", "delete", "void", "never",
        // C / C++
        "int", "float", "double", "char", "long", "short", "unsigned", "signed",
        "sizeof", "typedef", "extern", "register", "volatile",
        "inline", "virtual", "template", "namespace", "using",
        "auto", "constexpr", "nullptr", "include", "define", "ifdef", "ifndef", "endif", "pragma",
        // Rust
        "fn", "mod", "use", "crate", "pub", "impl", "trait", "match",
        "ref", "move", "unsafe", "extern",
        // Go
        "package", "go", "defer", "chan", "select", "map", "make",
        "goroutine", "fallthrough",
        // Java
        "extends", "super", "synchronized", "native", "transient",
        "strictfp", "throws",
        // Ruby
        "begin", "end", "rescue", "ensure", "unless", "until",
        "puts", "require_relative",
        // Shell
        "echo", "exit", "source", "alias", "unset", "export",
    ]

    /// Precompiled keyword pattern (word-boundary-wrapped alternation).
    private static let keywordPattern: String = {
        // Escape any regex-special characters in keywords (e.g. # in Swift directives, @ in attributes)
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        return "(?<![a-zA-Z_])(" + escaped.joined(separator: "|") + ")(?![a-zA-Z0-9_])"
    }()

    // MARK: - Regex Patterns

    /// Each rule is a (pattern, color) pair applied in order. Later rules override
    /// earlier ones so that strings/comments take visual precedence.
    private static let highlightRules: [(pattern: String, color: NSColor)] = [
        // 1. Types: PascalCase identifiers (at least two characters, starts uppercase)
        ("\\b[A-Z][a-zA-Z0-9_]*\\b", TokenColor.type),

        // 2. Keywords
        (keywordPattern, TokenColor.keyword),

        // 3. Numeric literals (integers, floats, hex, binary, octal, underscores)
        ("\\b0[xX][0-9a-fA-F_]+\\b|\\b0[bB][01_]+\\b|\\b0[oO][0-7_]+\\b|\\b\\d[\\d_]*(\\.[\\d_]+)?([eE][+-]?\\d+)?\\b", TokenColor.number),

        // 4. Decorators / annotations (@word)
        ("@[a-zA-Z_][a-zA-Z0-9_]*", TokenColor.decorator),

        // 5. Strings — double-quoted and single-quoted (with escape handling)
        ("\"\"\"[\\s\\S]*?\"\"\"|\"[^\"\\\\]*(\\\\.[^\"\\\\]*)*\"", TokenColor.string),
        ("'[^'\\\\]*(\\\\.[^'\\\\]*)*'", TokenColor.string),
        // Backtick template literals (JS/TS)
        ("`[^`\\\\]*(\\\\.[^`\\\\]*)*`", TokenColor.string),

        // 6. Comments (highest priority — overrides everything)
        ("//[^\n]*", TokenColor.comment),
        ("#[^\n]*", TokenColor.comment),
        ("/\\*[\\s\\S]*?\\*/", TokenColor.comment),
    ]

    /// Pre-compiled regular expressions (compiled once, reused).
    private static let compiledRules: [(regex: NSRegularExpression, color: NSColor)] = {
        highlightRules.compactMap { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.dotMatchesLineSeparators]) else {
                return nil
            }
            return (regex, rule.color)
        }
    }()

    // MARK: - Cache

    private static let cache: NSCache<CacheKeyWrapper, CacheValueWrapper> = {
        let c = NSCache<CacheKeyWrapper, CacheValueWrapper>()
        c.countLimit = 64
        return c
    }()

    private final class CacheKeyWrapper: NSObject {
        let code: String
        let fontSize: CGFloat
        let isDark: Bool
        init(code: String, fontSize: CGFloat, isDark: Bool) {
            self.code = code
            self.fontSize = fontSize
            self.isDark = isDark
            super.init()
        }
        override var hash: Int { code.hashValue ^ fontSize.hashValue ^ isDark.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? CacheKeyWrapper else { return false }
            return code == other.code && fontSize == other.fontSize && isDark == other.isDark
        }
    }

    private final class CacheValueWrapper: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value; super.init() }
    }

    // MARK: - Public API

    static func highlight(_ code: String, language: String?, fontSize: CGFloat, isDark: Bool) -> AttributedString {
        let key = CacheKeyWrapper(code: code, fontSize: fontSize, isDark: isDark)
        if let cached = cache.object(forKey: key) {
            return cached.value
        }

        let nsAttributed = buildHighlightedString(code, fontSize: fontSize)
        let result = AttributedString(nsAttributed)
        cache.setObject(CacheValueWrapper(result), forKey: key)
        return result
    }

    // MARK: - Internal

    private static func buildHighlightedString(_ code: String, fontSize: CGFloat) -> NSAttributedString {
        let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]

        let result = NSMutableAttributedString(string: code, attributes: baseAttributes)
        let fullRange = NSRange(location: 0, length: result.length)

        for rule in compiledRules {
            for match in rule.regex.matches(in: code, options: [], range: fullRange) {
                result.addAttribute(.foregroundColor, value: rule.color, range: match.range)
            }
        }

        return result
    }
}
