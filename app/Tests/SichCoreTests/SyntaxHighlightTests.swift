import Testing

@testable import SichCore

/// The pure single-line syntax lexer behind the diff pane's code highlighting.
/// These are the machine-verifiable half of the feature: the *classification* is
/// asserted here (keyword/string/number/comment spans, span coverage, language
/// inference); the actual on-screen colours are a visual concern the diff view owns
/// and a human signs off — this proves the tokens the view colours from are right.
@Suite("Syntax highlight lexer")
struct SyntaxHighlightTests {

    /// The spans must tile the input exactly — concatenating them back reproduces the
    /// line with no dropped or duplicated characters (the renderer relies on this to
    /// colour every character exactly once).
    @Test("spans concatenate back to the original line, losslessly", arguments: [
        "let x = 42  // note",
        "def foo(a, b): return a + b  # sum",
        "    guard let y = z else { return }",
        "",
        "   ",
        "нет ascii \"字\" 0xFF",
        "fn parse<'a>(input: &'a str) -> Result<&'a str, Error> { Ok(input) }",
        "SELECT id FROM t WHERE name = 'x' -- note",
        "{\"key\": [1, 2.5, true, null]}",
    ])
    func spansAreLossless(_ line: String) {
        // Every language, not a hand-picked few: a new one added to the enum without a
        // lossless lexer is a renderer that silently drops characters off a diff row.
        for language in CodeLanguage.allCases {
            let joined = SyntaxHighlight.spans(line, language: language)
                .map(\.text).joined()
            #expect(joined == line, "coverage broke for \(language)")
        }
    }

    @Test("keywords are classified; ordinary identifiers stay plain")
    func classifiesKeywords() {
        let spans = SyntaxHighlight.spans("let total = subtotal", language: .swift)
        let keywords = spans.filter { $0.kind == .keyword }.map(\.text)
        #expect(keywords == ["let"])
        // `total` and `subtotal` are identifiers, not keywords → left plain so the
        // diff's ± base colour shows through.
        #expect(spans.contains { $0.kind == .plain && $0.text.contains("total") })
        #expect(!spans.contains { $0.kind == .keyword && $0.text == "subtotal" })
    }

    @Test("a string literal is one span, escapes included")
    func classifiesString() {
        let spans = SyntaxHighlight.spans(#"print("a\"b")"#, language: .python)
        let strings = spans.filter { $0.kind == .string }.map(\.text)
        #expect(strings == [#""a\"b""#])
        #expect(spans.contains { $0.kind == .keyword && $0.text == "print" } == false)
    }

    @Test("line comments swallow the rest of the line")
    func classifiesComment() {
        let swift = SyntaxHighlight.spans("code() // trailing note", language: .swift)
        #expect(swift.last?.kind == .comment)
        #expect(swift.last?.text == "// trailing note")

        // `#` is a comment in python/shell but NOT in swift/js/c.
        let python = SyntaxHighlight.spans("x = 1 # done", language: .python)
        #expect(python.contains { $0.kind == .comment && $0.text == "# done" })
        let js = SyntaxHighlight.spans("x = 1 # done", language: .javascript)
        #expect(js.contains { $0.kind == .comment } == false)
    }

    @Test("numeric literals are classified, but digits inside identifiers are not")
    func classifiesNumbers() {
        let spans = SyntaxHighlight.spans("y = 0xFF + count2", language: .swift)
        let numbers = spans.filter { $0.kind == .number }.map(\.text)
        #expect(numbers == ["0xFF"])
        // `count2` is an identifier — the trailing digit must NOT split off as a number.
        #expect(spans.contains { $0.kind == .number && $0.text.contains("2") } == false)
        #expect(spans.contains { $0.text.contains("count2") })
    }

    @Test("language inference maps extensions and falls back to generic", arguments: [
        ("Foo.swift", CodeLanguage.swift),
        ("core/bar.py", .python),
        ("app.tsx", .javascript),
        ("pty.c", .c),
        ("dev.sh", .shell),
        ("src/main.rs", .rust),
        ("cmd/server/main.go", .go),
        ("Main.java", .java),
        ("app/Build.kts", .kotlin),
        ("lib/thing.rb", .ruby),
        ("index.php", .php),
        ("schema.sql", .sql),
        ("package.json", .json),
        ("ci/config.yml", .yaml),
        ("pyproject.toml", .yaml),
        ("Dockerfile", .shell),
        ("Rakefile", .ruby),
        ("README.md", .generic),
        ("no-extension", .generic),
    ])
    func infersLanguage(_ path: String, _ expected: CodeLanguage) {
        #expect(CodeLanguage.infer(fromPath: path) == expected)
    }

    /// The single-quote rule is per-language. Rust writes lifetimes as `&'a str`, so
    /// treating `'` as a string opener there paints the whole rest of the line as a
    /// string literal — the visible failure this pins down.
    @Test("a Rust lifetime is not a string; the line stays highlighted past it")
    func rustLifetimeIsNotAString() {
        let spans = SyntaxHighlight.spans("fn get<'a>(s: &'a str) -> bool { true }", language: .rust)
        #expect(spans.contains { $0.kind == .string } == false)
        // Highlighting survives past the lifetime — `true` after it is still a keyword.
        #expect(spans.contains { $0.kind == .keyword && $0.text == "true" })
    }

    /// The languages that DO have char/single-quoted literals keep them.
    @Test("single quotes still open a string where the language has them")
    func singleQuotesWhereSupported() {
        for language in [CodeLanguage.python, .javascript, .shell, .ruby, .c, .sql] {
            let spans = SyntaxHighlight.spans("x = 'hi'", language: language)
            #expect(spans.contains { $0.kind == .string && $0.text == "'hi'" },
                    "single-quoted string lost for \(language)")
        }
    }

    /// SQL is written in either case, so its keyword lookup folds — unlike every other
    /// language here, where `Let` is an identifier and only `let` is a keyword.
    @Test("SQL keywords match in any case; other languages stay case-sensitive")
    func sqlFoldsKeywordCase() {
        for line in ["SELECT a FROM t", "select a from t", "Select a From t"] {
            let keywords = SyntaxHighlight.spans(line, language: .sql)
                .filter { $0.kind == .keyword }.map { $0.text.lowercased() }
            #expect(keywords == ["select", "from"], "case folding failed for: \(line)")
        }
        let swift = SyntaxHighlight.spans("Let x = 1", language: .swift)
        #expect(swift.contains { $0.kind == .keyword } == false)
    }

    /// `--` is SQL's comment marker and nothing else's — a decrement in C must not
    /// blank the rest of the line.
    @Test("SQL comments use --; C's decrement is not a comment")
    func sqlLineComment() {
        let sql = SyntaxHighlight.spans("SELECT 1 -- why", language: .sql)
        #expect(sql.last?.kind == .comment)
        #expect(sql.last?.text == "-- why")
        let c = SyntaxHighlight.spans("count--; return 0;", language: .c)
        #expect(c.contains { $0.kind == .comment } == false)
    }

    @Test("Rust and Go keywords are classified")
    func classifiesNewLanguages() {
        let rust = SyntaxHighlight.spans("pub fn main() { let mut x = 1; }", language: .rust)
        #expect(rust.filter { $0.kind == .keyword }.map(\.text) == ["pub", "fn", "let", "mut"])
        let go = SyntaxHighlight.spans("func main() { var x int = 2 }", language: .go)
        #expect(go.filter { $0.kind == .keyword }.map(\.text) == ["func", "var", "int"])
    }

    /// `generic` (unknown file) has no keyword set, so nothing is falsely bolded as a
    /// keyword, but strings/numbers/comments are still classifiable structure.
    @Test("generic language never classifies keywords")
    func genericHasNoKeywords() {
        let spans = SyntaxHighlight.spans("let func class = 5", language: .generic)
        #expect(spans.contains { $0.kind == .keyword } == false)
        #expect(spans.contains { $0.kind == .number && $0.text == "5" })
    }
}
