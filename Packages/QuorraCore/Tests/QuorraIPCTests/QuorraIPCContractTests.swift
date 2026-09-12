import Darwin
import Foundation
import Testing
@testable import QuorraIPC

@Suite("IPC contract")
struct QuorraIPCContractTests {
    @Test func helperIPCUsesExactMutualCodeSigningRequirements() {
        #expect(QuorraIMDSHelperXPC.machServiceName == "dev.ajbeck.quorra.imds-helper")
        #expect(
            QuorraIMDSHelperXPC.appCodeSigningRequirement
                == "anchor apple generic and identifier \"dev.ajbeck.quorra\" "
                    + "and certificate leaf[subject.OU] = \"9GEBAJV9R4\""
        )
        #expect(
            QuorraIMDSHelperXPC.helperCodeSigningRequirement
                == "anchor apple generic and identifier \"dev.ajbeck.quorra.imds-helper\" "
                    + "and certificate leaf[subject.OU] = \"9GEBAJV9R4\""
        )
    }

    @Test func requestRoundTripsWithVersionAndArguments() throws {
        let requestID = UUID(uuidString: "E3B12F5D-CC25-4D54-A1B6-D7703EC0287F")!
        let request = QuorraIPCRequest(
            requestID: requestID,
            operation: .imdsStart,
            arguments: ["endpoint": "default"]
        )

        let data = try QuorraIPCCodec.encode(request)
        let decoded = try QuorraIPCCodec.decode(QuorraIPCRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.protocolVersion == 1)
    }

    @Test func typedSuccessPayloadRoundTrips() throws {
        let requestID = UUID(uuidString: "12D88E24-2710-48A8-9F47-046FBB44DE51")!
        let info = QuorraIPCServerInfo(appVersion: "0.4.0")

        let response = try QuorraIPCResponse.success(requestID: requestID, payload: info)
        let encodedResponse = try QuorraIPCCodec.encode(response)
        let decodedResponse = try QuorraIPCCodec.decode(QuorraIPCResponse.self, from: encodedResponse)
        let decodedInfo = try decodedResponse.decodePayload(as: QuorraIPCServerInfo.self)

        #expect(decodedResponse.status == .success)
        #expect(decodedInfo == info)
    }

    @Test func profileSignInOperationRoundTripsWithoutCredentialMaterial() throws {
        let operationID = UUID(uuidString: "D10D8566-BC52-485D-8927-343FD6A6ECED")!
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let operation = QuorraProfileSignInOperationRecord(
            id: operationID,
            profileName: "production-admin",
            sessionName: "production",
            state: .waitingForUser,
            startedAt: timestamp,
            updatedAt: timestamp
        )

        let encoded = try QuorraIPCCodec.encode(operation)
        let decoded = try QuorraIPCCodec.decode(
            QuorraProfileSignInOperationRecord.self,
            from: encoded
        )

        #expect(decoded == operation)
        #expect(decoded.state.isTerminal == false)
        #expect(String(decoding: encoded, as: UTF8.self).contains("accessToken") == false)
        #expect(String(decoding: encoded, as: UTF8.self).contains("secretAccessKey") == false)
    }

    @Test func failuresCarryStableMachineReadableCodes() {
        let requestID = UUID(uuidString: "A7C56ACD-0DD7-4D02-9797-945B34798E83")!

        let response = QuorraIPCResponse.failure(
            requestID: requestID,
            code: .incompatibleProtocol,
            message: "Update Quorra and its command-line tool."
        )

        #expect(response.status == .failure)
        #expect(response.error?.code == .incompatibleProtocol)
    }

    @Test func unixSocketRoundTripsARequest() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanUp() }
        let server = QuorraIPCServer(endpoint: fixture.endpoint) { request in
            try! .success(
                requestID: request.requestID,
                payload: QuorraIPCServerInfo(appVersion: "0.4.0")
            )
        }
        try server.start()
        defer { server.stop() }

        let request = QuorraIPCRequest(operation: .handshake)
        let client = QuorraIPCClient(timeout: 2, endpoint: fixture.endpoint)
        let response = try client.send(request)
        let info = try response.decodePayload(as: QuorraIPCServerInfo.self)

        #expect(response.requestID == request.requestID)
        #expect(info.appVersion == "0.4.0")
        #expect(info.protocolVersion == QuorraIPCProtocol.currentVersion)
    }

    @Test func socketIsOwnerReadWriteOnly() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanUp() }
        let server = QuorraIPCServer(endpoint: fixture.endpoint) { request in
            .failure(requestID: request.requestID, code: .invalidRequest, message: "unused")
        }
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.endpoint.socketURL.path
        )
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o600)
    }

    @Test func secondServerCannotReplaceAnActiveSocket() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanUp() }
        let first = QuorraIPCServer(endpoint: fixture.endpoint) { request in
            .failure(requestID: request.requestID, code: .invalidRequest, message: "unused")
        }
        let second = QuorraIPCServer(endpoint: fixture.endpoint) { request in
            .failure(requestID: request.requestID, code: .invalidRequest, message: "unused")
        }
        try first.start()
        defer { first.stop() }

        #expect(throws: QuorraIPCServerError.alreadyRunning) {
            try second.start()
        }
    }

    @Test func regularFileAtSocketPathIsNeverRemoved() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanUp() }
        let marker = Data("keep-me".utf8)
        try marker.write(to: fixture.endpoint.socketURL)
        let server = QuorraIPCServer(endpoint: fixture.endpoint) { request in
            .failure(requestID: request.requestID, code: .invalidRequest, message: "unused")
        }

        #expect(throws: QuorraIPCServerError.endpointOccupied) {
            try server.start()
        }
        #expect(try Data(contentsOf: fixture.endpoint.socketURL) == marker)
    }

    @Test func staleSocketIsReplacedAndRemovedOnStop() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanUp() }
        let staleDescriptor = try QuorraIPCTransport.makeSocket()
        var address = try QuorraIPCTransport.address(for: fixture.endpoint.socketURL)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    staleDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        #expect(bindResult == 0)
        Darwin.close(staleDescriptor)

        let server = QuorraIPCServer(endpoint: fixture.endpoint) { request in
            try! .success(requestID: request.requestID, payload: "ready")
        }
        try server.start()
        #expect(FileManager.default.fileExists(atPath: fixture.endpoint.socketURL.path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.endpoint.socketURL.path))
    }

    @Test func incompatibleProtocolReturnsVersionedFailure() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanUp() }
        let server = QuorraIPCServer(endpoint: fixture.endpoint) { request in
            try! .success(requestID: request.requestID, payload: "unexpected")
        }
        try server.start()
        defer { server.stop() }

        let request = QuorraIPCRequest(
            protocolVersion: QuorraIPCProtocol.currentVersion + 1,
            operation: .handshake
        )
        let response = try QuorraIPCClient(endpoint: fixture.endpoint).send(request)

        #expect(response.requestID == request.requestID)
        #expect(response.status == .failure)
        #expect(response.error?.code == .incompatibleProtocol)
    }

    @Test func clientReportsWhenNoAppOwnsTheSocket() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanUp() }
        let client = QuorraIPCClient(timeout: 0.05, endpoint: fixture.endpoint)

        #expect(throws: QuorraIPCClientError.appNotRunning) {
            _ = try client.send(QuorraIPCRequest(operation: .handshake))
        }
        #expect(QuorraIPCClientError.appNotRunning.localizedDescription == "Quorra is not running.")
    }

    @Test func fallbackLocatorRequiresAnExistingMacOSGroupContainer() throws {
        let fixture = try SocketFixture()
        defer { fixture.cleanUp() }
        let groupContainer = fixture.directoryURL
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(QuorraIPCProtocol.appGroupIdentifier, isDirectory: true)

        #expect(QuorraIPCEndpoint.fallbackContainerURL(
            fileManager: .default,
            homeDirectory: fixture.directoryURL
        ) == nil)

        try FileManager.default.createDirectory(
            at: groupContainer,
            withIntermediateDirectories: true
        )

        #expect(QuorraIPCEndpoint.fallbackContainerURL(
            fileManager: .default,
            homeDirectory: fixture.directoryURL
        ) == groupContainer)
    }
}

private struct SocketFixture {
    let directoryURL: URL
    let endpoint: QuorraIPCEndpoint

    init() throws {
        let identifier = UUID().uuidString.prefix(8)
        directoryURL = URL(
            fileURLWithPath: "/private/tmp/qipc-\(identifier)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        endpoint = QuorraIPCEndpoint(
            socketURL: directoryURL.appendingPathComponent("test.sock")
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
