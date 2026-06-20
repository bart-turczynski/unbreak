import Testing

@testable import Config

@Suite("TOML subset reader (PRD v2 §8.3)")
struct TOMLTests {
    @Test("Parses scalars of each supported type")
    func scalars() throws {
        let table = try TOML.parse(
            """
            name = "claude-code"
            count = 1_024
            ratio = 0.5
            on = true
            off = false
            """
        )
        #expect(table["name"] == .string("claude-code"))
        #expect(table["count"] == .integer(1024))
        #expect(table["ratio"] == .double(0.5))
        #expect(table["on"] == .boolean(true))
        #expect(table["off"] == .boolean(false))
    }

    @Test("Parses a string array, ignoring a trailing comma")
    func stringArray() throws {
        let table = try TOML.parse(#"terminals = ["a", "b", "c",]"#)
        #expect(table["terminals"] == .array([.string("a"), .string("b"), .string("c")]))
    }

    @Test("Flattens keys under a table header")
    func tableHeader() throws {
        let table = try TOML.parse(
            """
            [thresholds]
            shell_signal_score = 0.5
            structure_risk = 0.7
            """
        )
        #expect(table["thresholds.shell_signal_score"] == .double(0.5))
        #expect(table["thresholds.structure_risk"] == .double(0.7))
    }

    @Test("Ignores blank lines and full-line comments")
    func commentsAndBlanks() throws {
        let table = try TOML.parse(
            """
            # a leading comment

            poll_interval_ms = 400  # an inline comment
            """
        )
        #expect(table == ["poll_interval_ms": .integer(400)])
    }

    @Test("A '#' inside a quoted string is not a comment")
    func hashInString() throws {
        let table = try TOML.parse(#"id = "com.acme.app#beta""#)
        #expect(table["id"] == .string("com.acme.app#beta"))
    }

    @Test("A comma inside a quoted array element does not split it")
    func commaInArrayString() throws {
        let table = try TOML.parse(#"xs = ["a,b", "c"]"#)
        #expect(table["xs"] == .array([.string("a,b"), .string("c")]))
    }

    @Test("Unescapes basic string escapes")
    func stringEscapes() throws {
        let table = try TOML.parse(#"s = "a\tb\nc\"d""#)
        #expect(table["s"] == .string("a\tb\nc\"d"))
    }

    @Test("A line without '=' is a syntax error with its line number")
    func missingEquals() {
        #expect(throws: TOML.ParseError.syntax(line: 2, message: "expected 'key = value'")) {
            try TOML.parse("ok = 1\ngarbage")
        }
    }

    @Test("An unterminated array is a syntax error")
    func unterminatedArray() {
        #expect(throws: (any Error).self) {
            try TOML.parse(#"xs = ["a", "b""#)
        }
    }

    @Test("A table header missing its closing bracket is a syntax error")
    func unterminatedTableHeader() {
        #expect(throws: TOML.ParseError.syntax(line: 1, message: "unterminated table header")) {
            try TOML.parse("[thresholds")
        }
    }

    @Test("An empty table header is a syntax error")
    func emptyTableHeader() {
        #expect(throws: TOML.ParseError.syntax(line: 1, message: "empty table header")) {
            try TOML.parse("[]")
        }
    }

    @Test("A line beginning with '=' has no key and is a syntax error")
    func missingKey() {
        #expect(throws: TOML.ParseError.syntax(line: 1, message: "missing key before '='")) {
            try TOML.parse("= 5")
        }
    }

    @Test("A key with nothing after '=' is a syntax error")
    func missingValue() {
        #expect(throws: TOML.ParseError.syntax(line: 1, message: "missing value after '='")) {
            try TOML.parse("key =")
        }
    }

    @Test("A malformed float is a syntax error")
    func invalidFloat() {
        #expect(throws: TOML.ParseError.syntax(line: 1, message: "invalid float '1.2.3'")) {
            try TOML.parse("ratio = 1.2.3")
        }
    }

    @Test("A bare, non-numeric, unquoted value is unrecognized")
    func unrecognizedValue() {
        // No `.`/`e`/`E`, so it bypasses the float branch and fails as an integer.
        #expect(throws: TOML.ParseError.syntax(line: 1, message: "unrecognized value 'abc'")) {
            try TOML.parse("flag = abc")
        }
    }

    @Test("A string missing its closing quote is a syntax error")
    func unterminatedString() {
        #expect(throws: (any Error).self) {
            try TOML.parse(#"name = "abc"#)
        }
    }

    @Test("A string ending on a dangling escape is a syntax error")
    func danglingEscape() {
        #expect(throws: TOML.ParseError.syntax(line: 1, message: "dangling escape in string")) {
            try TOML.parse(#"name = "ab\""#)
        }
    }

    @Test("An escaped quote inside an array element does not split the element")
    func escapedQuoteInArray() throws {
        let table = try TOML.parse(#"xs = ["a\"b", "c"]"#)
        #expect(table["xs"] == .array([.string(#"a"b"#), .string("c")]))
    }

    @Test("An array element whose string is never closed is a syntax error")
    func unterminatedStringInArray() {
        #expect(throws: TOML.ParseError.syntax(line: 1, message: "unterminated string in array")) {
            try TOML.parse(#"xs = ["a]"#)
        }
    }
}
