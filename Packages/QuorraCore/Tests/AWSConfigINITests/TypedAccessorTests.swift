// TypedAccessorTests.swift — coercion matrix for Key.intValue/doubleValue/boolValue/mapValue
// and the lookup contract for Section.key(_:).

import Testing
import Foundation
@testable import AWSConfigINI

@Suite("Typed accessors")
struct TypedAccessorTests {

    // MARK: - intValue

    /// Mirrors `strconv.ParseInt(_, 0, 64)` from the AWS Go SDK (sections.go:136).
    @Test(arguments: [
        ("42",                 Int64?.some(42)),
        ("-1",                 -1),
        ("0xAFB1",             44977),
        ("0xafb1",             44977),
        ("0o107",              71),
        ("0b1001",             9),
        ("-0xff",              -255),
        ("-0o17",              -15),
        ("-0b1010",            -10),
        ("9223372036854775807", Int64.max),
        ("",                   nil),
        ("abc",                nil),
        ("1.5",                nil),
        ("9223372036854775808", nil),
    ])
    func intValueMatrix(input: String, expected: Int64?) throws {
        let doc = try AWSConfigINIDocument("[s]\nk = \(input)\n")
        #expect(doc.section("s")?.key("k")?.intValue() == expected)
    }

    @Test func intValueAgainstBaseNumbersFixture() throws {
        // The fixture exercises real-world numeric formats including a hex color string
        // (970b00) that has no 0x prefix and must therefore not coerce to Int.
        let doc = try AWSConfigINIDocument(loadFixtureString("base_numbers_profile"))
        let s = doc.section("default")
        #expect(s?.key("hex")?.intValue() == 44977)
        #expect(s?.key("hex2")?.intValue() == 44977)
        #expect(s?.key("binary")?.intValue() == 9)
        #expect(s?.key("octal")?.intValue() == 71)
        #expect(s?.key("ten")?.intValue() == 12)
        #expect(s?.key("color")?.intValue() == nil)
    }

    // MARK: - doubleValue

    /// `Double.init(_:)` semantics. Mirrors `strconv.ParseFloat(_, 64)`. Note that
    /// `Double("nan")`/`"inf"` produce NaN and ±∞ rather than nil — this matches Go.
    @Test(arguments: [
        ("12.3",   true),    // plain decimal
        ("1e4",    true),    // scientific lowercase
        ("1E-4",   true),    // negative exponent
        ("-1.5",   true),    // negative
        ("nan",    true),    // returns NaN, not nil
        ("inf",    true),    // returns +∞
        ("0x1ob",  false),   // hex float not supported
        ("",       false),
        ("abc",    false),
    ])
    func doubleValueMatrix(input: String, parsesNonNil: Bool) throws {
        let doc = try AWSConfigINIDocument("[s]\nk = \(input)\n")
        let v = doc.section("s")?.key("k")?.doubleValue()
        #expect((v != nil) == parsesNonNil, "input '\(input)' expected parsesNonNil=\(parsesNonNil), got \(v as Any)")
    }

    @Test func doubleValueExactValues() throws {
        // Verify a few exact coercions to pin down the parser, complementing the matrix.
        let doc = try AWSConfigINIDocument("[s]\na = 12.3\nb = 1e4\nc = -1.5\n")
        let s = doc.section("s")
        #expect(s?.key("a")?.doubleValue() == 12.3)
        #expect(s?.key("b")?.doubleValue() == 10000.0)
        #expect(s?.key("c")?.doubleValue() == -1.5)
    }

    // MARK: - boolValue (strict — Decision D11)

    /// Strict bool grammar: case-insensitive `true`/`false` only. Anything else returns nil.
    /// Mirrors `value.go:79-88` from the AWS Go SDK (avoids strconv.ParseBool).
    @Test(arguments: [
        ("true",  Bool?.some(true)),
        ("True",  true),
        ("TRUE",  true),
        ("false", false),
        ("False", false),
        ("FALSE", false),
        ("yes",   nil),
        ("no",    nil),
        ("on",    nil),
        ("off",   nil),
        ("1",     nil),
        ("0",     nil),
        ("y",     nil),
        ("n",     nil),
        ("",      nil),
        ("truee", nil),
    ])
    func boolValueMatrix(input: String, expected: Bool?) throws {
        let doc = try AWSConfigINIDocument("[s]\nk = \(input)\n")
        #expect(doc.section("s")?.key("k")?.boolValue() == expected)
    }

    // MARK: - mapValue

    @Test func mapValueOnMapTypedKey() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("nested_fields"))
        let m = doc.section("foo")?.key("aws_access_key_id")?.mapValue()
        #expect(m?["aws_secret_access_key"] == "valid;comment")
        #expect(m?["aws_secret_access_key2"] == "valid2")
    }

    @Test func mapValueOnStringKeyIsNil() throws {
        let doc = try AWSConfigINIDocument("[s]\nk = hello\n")
        #expect(doc.section("s")?.key("k")?.mapValue() == nil)
    }

    @Test func mapValueOnEmptyValueKeyIsNil() throws {
        let doc = try AWSConfigINIDocument("[s]\nk =\n")
        #expect(doc.section("s")?.key("k")?.mapValue() == nil)
    }

    // MARK: - stringValue

    @Test func stringValueReturnsRawString() throws {
        let doc = try AWSConfigINIDocument("[s]\nk = hello\n")
        #expect(doc.section("s")?.key("k")?.stringValue == "hello")
    }

    @Test func stringValueOnEmptyKeyIsEmpty() throws {
        let doc = try AWSConfigINIDocument("[s]\nk =\n")
        #expect(doc.section("s")?.key("k")?.stringValue == "")
    }

    @Test func stringValueOnMapKeyReturnsEmpty() throws {
        // Parser spec §10.1 / plan §8.2: map-typed keys return "" from stringValue.
        let doc = try AWSConfigINIDocument(loadFixtureString("nested_fields"))
        #expect(doc.section("foo")?.key("aws_access_key_id")?.stringValue == "")
    }

    // MARK: - Section.key(_:) lookup

    @Test func keyLookupIsCaseInsensitive() throws {
        // Stored keys are lowercased. Any-case lookup must resolve to the stored key.
        let doc = try AWSConfigINIDocument(loadFixtureString("mixed_case_keys"))
        let k = doc.section("with_mixed_case_keys")?.key("STRING_VALUE")
        #expect(k?.name == "string_value")
        #expect(k?.stringValue == "secret")
    }

    @Test func keyLookupReturnsNilForMissingKey() throws {
        let doc = try AWSConfigINIDocument("[s]\nfoo = bar\n")
        #expect(doc.section("s")?.key("baz") == nil)
    }
}
