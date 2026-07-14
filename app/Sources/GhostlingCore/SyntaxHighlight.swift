import Foundation

/// The language a diff line is highlighted as — inferred from the file's extension.
/// `generic` (no known extension) still highlights strings/numbers/comments, just
/// with no keyword set, so an unknown file is never worse than plain text.
public enum CodeLanguage: Sendable, Equatable {
    case swift, python, javascript, c, shell, generic

    /// Map a file path's extension to a language. Unknown → `generic`.
    public static func infer(fromPath path: String) -> CodeLanguage {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "py", "pyi": return .python
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .javascript
        case "c", "h", "cpp", "cc", "hpp", "m", "mm": return .c
        case "sh", "bash", "zsh": return .shell
        default: return .generic
        }
    }

    /// The token that starts a to-end-of-line comment (`//`, `#`). A line lexer only
    /// needs the single-line form; block comments spanning lines aren't tracked.
    var lineComment: String? {
        switch self {
        case .swift, .javascript, .c: return "//"
        case .python, .shell: return "#"
        case .generic: return nil
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift: return CodeLanguage.swiftKeywords
        case .python: return CodeLanguage.pythonKeywords
        case .javascript: return CodeLanguage.javascriptKeywords
        case .c: return CodeLanguage.cKeywords
        case .shell: return CodeLanguage.shellKeywords
        case .generic: return []
        }
    }
}

/// A tiny, single-line syntax lexer. It classifies a line of source into contiguous
/// spans (keyword / string / number / comment / plain) whose texts concatenate back
/// to the input — so a renderer can colour each span without leaving gaps. It is
/// deliberately line-local (a diff is line-oriented): a string or block comment that
/// spans lines is highlighted only on the line it opens, which is good enough for a
/// review pane and keeps the lexer pure and cheap.
public enum SyntaxHighlight {
    public enum TokenKind: Sendable, Equatable {
        case plain, keyword, string, number, comment
    }

    public struct Span: Sendable, Equatable {
        public let text: String
        public let kind: TokenKind
        public init(text: String, kind: TokenKind) {
            self.text = text
            self.kind = kind
        }
    }

    public static func spans(_ line: String, language: CodeLanguage) -> [Span] {
        var lexer = Lexer(line: line, language: language)
        return lexer.run()
    }
}

/// The scanner behind ``SyntaxHighlight/spans(_:language:)``. Walks the line once,
/// emitting one span per token and coalescing runs of unclassified characters into a
/// single trailing `plain` span.
private struct Lexer {
    private let chars: [Character]
    private let language: CodeLanguage
    private var index = 0
    private var plain = ""
    private var spans: [SyntaxHighlight.Span] = []

    init(line: String, language: CodeLanguage) {
        self.chars = Array(line)
        self.language = language
    }

    mutating func run() -> [SyntaxHighlight.Span] {
        while index < chars.count {
            if consumeComment() || consumeString() || consumeNumber() || consumeWord() {
                continue
            }
            plain.append(chars[index])
            index += 1
        }
        flushPlain()
        return spans
    }

    /// A `//` or `#` run to end of line — everything after is one comment span.
    private mutating func consumeComment() -> Bool {
        guard let marker = language.lineComment, matches(marker) else { return false }
        emit(String(chars[index...]), .comment)
        index = chars.count
        return true
    }

    /// A `"…"` or `'…'` literal, honouring `\` escapes; an unterminated quote runs to
    /// end of line (the line-local limitation, intentional).
    private mutating func consumeString() -> Bool {
        let quote = chars[index]
        guard quote == "\"" || quote == "'" else { return false }
        var text = String(quote)
        var cursor = index + 1
        while cursor < chars.count {
            let character = chars[cursor]
            text.append(character)
            if character == "\\", cursor + 1 < chars.count {
                text.append(chars[cursor + 1])
                cursor += 2
                continue
            }
            cursor += 1
            if character == quote { break }
        }
        emit(text, .string)
        index = cursor
        return true
    }

    /// A numeric literal — a digit not glued to the middle of an identifier, then any
    /// run of digits / `.` / hex letters / separators.
    private mutating func consumeNumber() -> Bool {
        guard chars[index].isNumber, !isIdentifier(before: index) else { return false }
        var cursor = index
        while cursor < chars.count, isNumeric(chars[cursor]) { cursor += 1 }
        emit(String(chars[index..<cursor]), .number)
        index = cursor
        return true
    }

    /// An identifier run — emitted as `keyword` when it's in the language's set, else
    /// left for the plain buffer (so callers keep the diff's base colour on it).
    private mutating func consumeWord() -> Bool {
        guard isWordStart(chars[index]) else { return false }
        var cursor = index
        while cursor < chars.count, isWordBody(chars[cursor]) { cursor += 1 }
        let word = String(chars[index..<cursor])
        if language.keywords.contains(word) {
            emit(word, .keyword)
        } else {
            plain += word
        }
        index = cursor
        return true
    }

    // MARK: - Emit helpers

    private mutating func emit(_ text: String, _ kind: SyntaxHighlight.TokenKind) {
        flushPlain()
        spans.append(SyntaxHighlight.Span(text: text, kind: kind))
    }

    private mutating func flushPlain() {
        guard !plain.isEmpty else { return }
        spans.append(SyntaxHighlight.Span(text: plain, kind: .plain))
        plain = ""
    }

    // MARK: - Character classes

    private func matches(_ token: String) -> Bool {
        let end = index + token.count
        guard end <= chars.count else { return false }
        return String(chars[index..<end]) == token
    }

    private func isIdentifier(before position: Int) -> Bool {
        position > 0 && isWordBody(chars[position - 1])
    }

    private func isNumeric(_ character: Character) -> Bool {
        character.isHexDigit || character == "." || character == "_"
            || character == "x" || character == "X"
    }

    private func isWordStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private func isWordBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

// MARK: - Keyword sets

extension CodeLanguage {
    fileprivate static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
        "import", "init", "inout", "internal", "let", "open", "operator", "private",
        "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias",
        "var", "break", "case", "continue", "default", "defer", "do", "else",
        "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where",
        "while", "as", "catch", "false", "is", "nil", "self", "super", "throw", "throws",
        "true", "try", "async", "await", "actor", "nonisolated", "some", "any", "final",
        "override", "weak", "lazy", "mutating", "convenience", "required",
    ]
    fileprivate static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
        "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
        "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
        "return", "try", "while", "with", "yield", "True", "False", "None", "self",
        "match", "case",
    ]
    fileprivate static let javascriptKeywords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "finally", "for", "function", "if",
        "import", "in", "instanceof", "let", "new", "return", "super", "switch", "this",
        "throw", "try", "typeof", "var", "void", "while", "with", "yield", "async",
        "await", "of", "true", "false", "null", "undefined", "interface", "type",
        "enum", "implements", "private", "public", "protected", "readonly", "static",
    ]
    fileprivate static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
        "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
        "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
        "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool",
        "true", "false", "nullptr", "class", "namespace", "template", "public", "private",
    ]
    fileprivate static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until",
        "do", "done", "in", "function", "select", "time", "return", "export", "local",
        "readonly", "declare", "unset", "echo", "exec", "source",
    ]
}
