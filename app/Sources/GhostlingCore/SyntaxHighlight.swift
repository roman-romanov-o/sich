import Foundation

/// The language a diff line is highlighted as — inferred from the file's extension.
/// `generic` (no known extension) still highlights strings/numbers/comments, just
/// with no keyword set, so an unknown file is never worse than plain text.
public enum CodeLanguage: Sendable, Equatable, CaseIterable {
    case swift, python, javascript, rust, go, java, kotlin, ruby, php, c, shell
    case sql, json, yaml, generic

    /// Map a file path's extension to a language, falling back to the *filename* for
    /// the well-known extensionless ones (`Makefile`, `Dockerfile`, `.zshrc`).
    /// Unknown → `generic`.
    public static func infer(fromPath path: String) -> CodeLanguage {
        let name = (path as NSString).lastPathComponent
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "py", "pyi", "pyw": return .python
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts": return .javascript
        case "rs": return .rust
        case "go": return .go
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "rb", "rake", "gemspec": return .ruby
        case "php": return .php
        case "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm": return .c
        case "sh", "bash", "zsh", "fish": return .shell
        case "sql": return .sql
        case "json", "jsonc": return .json
        case "yml", "yaml", "toml", "ini", "cfg", "conf": return .yaml
        default: return infer(fromFilename: name)
        }
    }

    private static func infer(fromFilename name: String) -> CodeLanguage {
        switch name {
        case "Makefile", "Dockerfile", "Gemfile", ".zshrc", ".bashrc", ".bash_profile",
             ".profile", ".zprofile":
            return .shell
        case "Rakefile": return .ruby
        default: return .generic
        }
    }

    /// The token that starts a to-end-of-line comment (`//`, `#`, `--`). A line lexer
    /// only needs the single-line form; block comments spanning lines aren't tracked.
    var lineComment: String? {
        switch self {
        case .swift, .javascript, .rust, .go, .java, .kotlin, .php, .c: return "//"
        case .python, .shell, .ruby, .yaml: return "#"
        case .sql: return "--"
        case .json, .generic: return nil
        }
    }

    /// Which quote characters open a string literal in this language.
    ///
    /// Deliberately per-language rather than a shared `"` + `'`: Rust's lifetimes
    /// (`&'a str`) and Swift's nothing-of-the-kind mean a stray `'` there is NOT a
    /// string opener, and treating it as one paints the rest of the line as a string.
    /// Backticks are included where they're a real literal (JS templates, Go raw
    /// strings) rather than shell/markdown punctuation.
    var stringDelimiters: Set<Character> {
        switch self {
        case .swift, .rust, .java, .kotlin, .json: return ["\""]
        case .go, .javascript: return ["\"", "'", "`"]
        case .python, .shell, .ruby, .php, .c, .sql, .yaml, .generic: return ["\"", "'"]
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift: return CodeLanguage.swiftKeywords
        case .python: return CodeLanguage.pythonKeywords
        case .javascript: return CodeLanguage.javascriptKeywords
        case .rust: return CodeLanguage.rustKeywords
        case .go: return CodeLanguage.goKeywords
        case .java: return CodeLanguage.javaKeywords
        case .kotlin: return CodeLanguage.kotlinKeywords
        case .ruby: return CodeLanguage.rubyKeywords
        case .php: return CodeLanguage.phpKeywords
        case .c: return CodeLanguage.cKeywords
        case .shell: return CodeLanguage.shellKeywords
        case .sql: return CodeLanguage.sqlKeywords
        case .json: return CodeLanguage.jsonKeywords
        case .yaml: return CodeLanguage.yamlKeywords
        case .generic: return []
        }
    }

    /// SQL is the one language here that's conventionally written in either case
    /// (`select` and `SELECT` are the same keyword), so its lookup lowercases first.
    var keywordsAreCaseInsensitive: Bool { self == .sql }
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
    private let comment: String?
    private let quotes: Set<Character>
    private let keywords: Set<String>
    private let foldsKeywordCase: Bool
    private var index = 0
    private var plain = ""
    private var spans: [SyntaxHighlight.Span] = []

    /// The language's tables are read once here rather than per token — `keywords`
    /// et al are computed properties, and a diff pane lexes every visible line.
    init(line: String, language: CodeLanguage) {
        self.chars = Array(line)
        self.comment = language.lineComment
        self.quotes = language.stringDelimiters
        self.keywords = language.keywords
        self.foldsKeywordCase = language.keywordsAreCaseInsensitive
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
        guard let marker = comment, matches(marker) else { return false }
        emit(String(chars[index...]), .comment)
        index = chars.count
        return true
    }

    /// A `"…"` or `'…'` literal, honouring `\` escapes; an unterminated quote runs to
    /// end of line (the line-local limitation, intentional).
    private mutating func consumeString() -> Bool {
        let quote = chars[index]
        guard quotes.contains(quote) else { return false }
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
        if keywords.contains(foldsKeywordCase ? word.lowercased() : word) {
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
    fileprivate static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
        "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
        "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
        "struct", "super", "trait", "true", "type", "union", "unsafe", "use", "where",
        "while", "Some", "None", "Ok", "Err",
    ]
    fileprivate static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
        "package", "range", "return", "select", "struct", "switch", "type", "var",
        "nil", "true", "false", "make", "new", "len", "cap", "append", "error",
        "string", "int", "bool", "byte", "rune",
    ]
    fileprivate static let javaKeywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
        "class", "const", "continue", "default", "do", "double", "else", "enum",
        "extends", "final", "finally", "float", "for", "if", "implements", "import",
        "instanceof", "int", "interface", "long", "native", "new", "package", "private",
        "protected", "public", "return", "short", "static", "strictfp", "super",
        "switch", "synchronized", "this", "throw", "throws", "transient", "try", "var",
        "void", "volatile", "while", "record", "sealed", "true", "false", "null",
    ]
    fileprivate static let kotlinKeywords: Set<String> = [
        "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if",
        "in", "interface", "is", "null", "object", "package", "return", "super", "this",
        "throw", "true", "try", "typealias", "typeof", "val", "var", "when", "while",
        "by", "catch", "constructor", "delegate", "dynamic", "field", "finally", "get",
        "import", "init", "param", "property", "receiver", "set", "setparam", "where",
        "actual", "abstract", "annotation", "companion", "const", "crossinline", "data",
        "enum", "expect", "external", "final", "infix", "inline", "inner", "internal",
        "lateinit", "noinline", "open", "operator", "out", "override", "private",
        "protected", "public", "reified", "sealed", "suspend", "tailrec", "vararg",
    ]
    fileprivate static let rubyKeywords: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
        "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next",
        "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super",
        "then", "true", "undef", "unless", "until", "when", "while", "yield", "require",
        "require_relative", "attr_accessor", "attr_reader", "attr_writer", "lambda",
        "proc", "raise", "puts",
    ]
    fileprivate static let phpKeywords: Set<String> = [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
        "clone", "const", "continue", "declare", "default", "do", "echo", "else",
        "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch",
        "endwhile", "enum", "extends", "final", "finally", "fn", "for", "foreach",
        "function", "global", "goto", "if", "implements", "include", "include_once",
        "instanceof", "insteadof", "interface", "isset", "list", "match", "namespace",
        "new", "or", "print", "private", "protected", "public", "readonly", "require",
        "require_once", "return", "static", "switch", "throw", "trait", "try", "unset",
        "use", "var", "while", "xor", "yield", "true", "false", "null",
    ]
    /// Lowercase only — SQL's lookup folds case (see `keywordsAreCaseInsensitive`),
    /// so `SELECT`, `Select` and `select` all land here.
    fileprivate static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set",
        "delete", "create", "alter", "drop", "table", "index", "view", "join", "inner",
        "left", "right", "full", "outer", "cross", "on", "as", "and", "or", "not",
        "null", "is", "in", "between", "like", "order", "by", "group", "having",
        "limit", "offset", "union", "all", "distinct", "case", "when", "then", "else",
        "end", "primary", "foreign", "key", "references", "constraint", "unique",
        "default", "with", "returning", "exists", "cast", "begin", "commit", "rollback",
        "transaction", "true", "false",
    ]
    /// JSON has no keywords beyond its three literals.
    fileprivate static let jsonKeywords: Set<String> = ["true", "false", "null"]
    fileprivate static let yamlKeywords: Set<String> = [
        "true", "false", "null", "yes", "no", "on", "off", "None",
    ]
}
