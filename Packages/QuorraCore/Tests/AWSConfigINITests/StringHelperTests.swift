// StringHelperTests.swift — unit tests for the parser's string-manipulation helpers.

import Testing
import Foundation
@testable import AWSConfigINI

@Suite("String helpers")
struct StringHelperTests {

    @Test func trimProfileCommentHashAnywhere() {
        // No whitespace requirement for profile comment delimiter
        #expect(trimProfileComment("[profile foo]#comment") == "[profile foo]")
        #expect(trimProfileComment("[profile foo];comment") == "[profile foo]")
        #expect(trimProfileComment("[profile foo]") == "[profile foo]")
    }

    @Test func trimPropertyCommentRequiresWhitespace() {
        // Comment delimiter must be preceded by space or tab.
        // strings.Cut removes the delimiter AND everything after it, so the space/tab
        // that precedes the '#' or ';' is ALSO removed.
        #expect(trimPropertyComment("foo#notcomment") == "foo#notcomment")
        #expect(trimPropertyComment("foo;notcomment") == "foo;notcomment")
        #expect(trimPropertyComment("foo #comment") == "foo")
        #expect(trimPropertyComment("foo\t#comment") == "foo")
        #expect(trimPropertyComment("foo ;comment") == "foo")
        #expect(trimPropertyComment("foo\t;comment") == "foo")
    }

    @Test func splitPropertyEqualsWins() {
        let result = splitProperty("foo = bar = baz")
        #expect(result?.key == "foo")
        #expect(result?.value == "bar = baz")
    }

    @Test func splitPropertyColonFirst() {
        let result = splitProperty("key:= value1")
        #expect(result?.key == "key")
        #expect(result?.value == "= value1")
    }

    @Test func splitPropertyColonOnly() {
        let result = splitProperty("key : value5")
        #expect(result?.key == "key")
        #expect(result?.value == "value5")
    }

    @Test func splitPropertyNilWhenNoSeparator() {
        #expect(splitProperty("noseparatorhere") == nil)
    }

    @Test func legacyStrconvDoubleQuotes() {
        #expect(legacyStrconv("\"foo-region\"") == "foo-region")
    }

    @Test func legacyStrconvSingleQuotes() {
        #expect(legacyStrconv("'foo'") == "foo")
    }

    @Test func legacyStrconvMixedQuotes() {
        #expect(legacyStrconv("\"foo'") == "\"foo'")
    }

    @Test func legacyStrconvNoQuotes() {
        #expect(legacyStrconv("foo") == "foo")
    }

    @Test func splitProfileType() {
        let (type, name) = splitProfile("profile foo")
        #expect(type == "profile")
        #expect(name == "foo")
    }

    @Test func splitProfileNoType() {
        let (type, name) = splitProfile("default")
        #expect(type == "")
        #expect(name == "default")
    }

    @Test func isBracketedTrue() {
        #expect(isBracketed("[default]"))
        #expect(isBracketed("[profile foo]"))
    }

    @Test func isBracketedFalse() {
        #expect(!isBracketed("[abc"))
        #expect(!isBracketed("abc]"))
        #expect(!isBracketed(""))
        #expect(!isBracketed("["))
    }
}
