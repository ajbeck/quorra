// BOMTests.swift — UTF-8/UTF-16 BOM detection on read and re-emission on write.
//
// Decision D17: preserve through round-trip.

import Testing
import Foundation
@testable import AWSConfigINI

@Suite("BOM")
struct BOMTests {

    @Test func utf8BOMDetected() throws {
        var bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        let content = "[default]\nfoo = bar\n"
        bomBytes.append(contentsOf: content.utf8)
        let data = Data(bomBytes)
        let (kind, start) = detectBOM(in: data)
        #expect(kind == .utf8)
        #expect(start == 3)
        let stripped = String(data: data.dropFirst(start), encoding: .utf8)
        #expect(stripped == content)
    }

    @Test func utf16LEBOMDetected() throws {
        let data = Data([0xFF, 0xFE, 0x41, 0x00])
        let (kind, start) = detectBOM(in: data)
        #expect(kind == .utf16LE)
        #expect(start == 2)
    }

    @Test func utf16BEBOMDetected() throws {
        let data = Data([0xFE, 0xFF, 0x00, 0x41])
        let (kind, start) = detectBOM(in: data)
        #expect(kind == .utf16BE)
        #expect(start == 2)
    }

    @Test func noBOMOnPlainInput() throws {
        let data = Data("[default]\nfoo=bar\n".utf8)
        let (kind, start) = detectBOM(in: data)
        #expect(kind == nil)
        #expect(start == 0)
    }

    @Test func bomKindNilForStringInit() throws {
        let doc = try AWSConfigINIDocument("[default]\nfoo = bar\n")
        #expect(doc.bomKind == nil)
    }

    @Test func bomKindSetWhenLoadedFromFile() throws {
        var bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bomBytes.append(contentsOf: "[default]\nbom_key = bom_value\n".utf8)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quorra_bom_test_\(UUID().uuidString).ini")
        try Data(bomBytes).write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let doc = try AWSConfigINIDocument(contentsOf: tmpURL)
        #expect(doc.bomKind == .utf8)
        #expect(doc.section("default")?.key("bom_key")?.stringValue == "bom_value")
    }

    /// A document with a BOM must emit the BOM bytes at the start of the written output.
    @Test func bomBytesLeadOutput() throws {
        var bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bomBytes.append(contentsOf: "[default]\nregion = us-east-1\n".utf8)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quorra_bom_emit_\(UUID().uuidString).ini")
        try Data(bomBytes).write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let doc = try AWSConfigINIDocument(contentsOf: tmpURL)
        let written = try doc.write()
        let writtenData = written.data(using: .utf8)!
        #expect(writtenData.count >= 3)
        #expect(writtenData[0] == 0xEF)
        #expect(writtenData[1] == 0xBB)
        #expect(writtenData[2] == 0xBF)
    }

    /// A document without a BOM must NOT emit BOM bytes.
    @Test func noBomDocumentHasNoBomPrefix() throws {
        let doc = try AWSConfigINIDocument("[default]\nregion = us-east-1\n")
        let written = try doc.write()
        let writtenData = written.data(using: .utf8)!
        #expect(writtenData.count >= 1)
        #expect(writtenData[0] != 0xEF)
    }
}
