import Darwin
import Foundation
import Shared
import XCTest
@testable import App

/// Explicitly exercises the already-deployed private gateway and SSH tunnel against
/// authored temporary native state. This is not installed-App or foreground acceptance.
final class RetracePrivateTransportAcceptanceTests: XCTestCase {
    func testDeployedPrivateGatewayUsesAuthoredNativeMarkerOwner() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RETRACE_TEST_PRIVATE_MCP_TRANSPORT"] == "1" else {
            throw XCTSkip("Set RETRACE_TEST_PRIVATE_MCP_TRANSPORT=1 for the deployed private transport fixture")
        }
        try acceptanceRequire(environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1", "file_logging_must_be_disabled")
        try acceptanceRequire(environment["RETRACE_TEST_PRIVATE_MCP_ENDPOINT"] == PrivateMCPClient.endpoint.absoluteString,
                              "explicit_existing_endpoint_required")
        try requirePrivateMCPPortAvailable()

        let root = try makePrivateMCPDirectory(prefix: "retrace-private-mcp-fixture-")
        defer { try? FileManager.default.removeItem(at: root) }
        let receiptDirectory = try makePrivateMCPDirectory(prefix: "retrace-private-mcp-receipt-")
        let receiptURL = receiptDirectory.appendingPathComponent("receipt.json")
        let services = ServiceContainer(inMemory: true)
        let serviceRoot = await services.storage.getStorageDirectory()
        let coordinator = AppCoordinator(services: services)
        let nativeID = UUID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { nativeID })
        let allowed: Set<RetraceOperation> = [.health, .markerList, .markerRead, .markerCreate,
                                            .markerUpdate, .markerRemove, .markerRestore]
        let handlers = await RetraceNativeCommandHandlers.make(coordinator: coordinator, markers: markers)
            .filter { allowed.contains($0.operation) }
        let access = RetraceCommandAccessService(storageRoot: root, handlers: { handlers })
        let client = PrivateMCPClient()
        var receipt = PrivateMCPReceipt(nativeStoreID: nativeID)
        var failure: (any Error)?
        var clientID: String?
        do {
            let capabilities: Set<RetraceCapability> = [.operationsRead, .markersRead, .markersWrite, .foregroundControl, .evidenceRead]
            let issued = try await access.createClient(name: "AUTHORED private transport acceptance",
                capabilities: capabilities,
                expiresAt: Date().addingTimeInterval(86_400))
            clientID = issued.summary.id
            let configuration = try Data(contentsOf: root.appendingPathComponent("context/native-access/clients.json"))
            try acceptanceRequire(!String(decoding: configuration, as: UTF8.self).contains(issued.bearerToken),
                                  "private_configuration_must_not_contain_bearer")
            try await access.setEnabled(true)
            let state = await access.state()
            try acceptanceRequire(state.listening && state.clients.count == 1 && state.clients[0].capabilities == capabilities,
                                  "private_listener_or_capabilities_not_ready")
            try await exercise(client: client, bearer: issued.bearerToken, markers: markers,
                               expectedOperations: allowed.union([.manifest]), receipt: &receipt)
            try await access.revokeClient(id: issued.summary.id)
            clientID = nil
            let revoked = await access.state()
            try acceptanceRequire(revoked.clients.isEmpty && !revoked.listening, "revocation_did_not_stop_listener")
            let unavailable = try await client.raw(method: "tools/list", parameters: .object([:]), bearer: issued.bearerToken)
            try acceptanceRequire(unavailable.status == 503, "revoked_only_client_must_leave_gateway_unavailable")
            let rejection = try RetraceWire.decoder().decode(PrivateMCPRejection.self, from: unavailable.data)
            try acceptanceRequire(rejection.error == "laptop_unavailable" && !rejection.queued, "offline_command_must_not_queue")
            receipt.revokedListenerStopped = true
            receipt.revokedGatewayStatus = unavailable.status
            try acceptanceRequire(!FileManager.default.fileExists(atPath: serviceRoot.path), "uninitialized_services_created_storage")
        } catch { failure = error }

        // These are the same owners as production. Always join access before closing
        // the marker database, including when any network assertion failed.
        if let clientID {
            do { try await access.revokeClient(id: clientID) }
            catch { if failure == nil { failure = error } }
        }
        await access.close()
        client.close()
        do { try await markers.close() } catch { if failure == nil { failure = error } }
        do { try await services.shutdown() } catch { if failure == nil { failure = error } }
        let closed = await access.state()
        receipt.closedListenerStopped = !closed.listening
        if closed.listening, failure == nil { failure = PrivateMCPFailure("closed_listener_still_listening") }
        do {
            try FileManager.default.removeItem(at: root)
            if FileManager.default.fileExists(atPath: serviceRoot.path) {
                // The in-memory container generated this private path for this test.
                try FileManager.default.removeItem(at: serviceRoot)
            }
            receipt.fixtureRemoved = true
        } catch { if failure == nil { failure = error } }
        receipt.completedAt = Date()
        receipt.passed = failure == nil
        // Record a categorical failure only; URLSession errors can contain request
        // details, and credentials are never part of this receipt or XCTest output.
        receipt.failure = failure.map { ($0 as? PrivateMCPFailure)?.category ?? "fixture_failed" }
        try writePrivateMCPReceipt(receipt, to: receiptURL)
        print("Private authored MCP transport receipt: \(receiptURL.path)")
        if let failure { throw PrivateMCPFailure(receipt.failure ?? "fixture_failed_\(type(of: failure))") }
    }

    private func exercise(client: PrivateMCPClient, bearer: String, markers: TimelineMarkerService,
                          expectedOperations: Set<RetraceOperation>, receipt: inout PrivateMCPReceipt) async throws {
        let tools = try await client.tools(bearer: bearer)
        let expectedTools = Set(expectedOperations.map { "retrace_" + $0.rawValue.replacingOccurrences(of: ".", with: "_") })
        try acceptanceRequire(Set(tools.map(\.name)) == expectedTools && tools.count == expectedTools.count,
                              "deployed_tools_must_match_filtered_native_handlers")
        let manifestResult = try await client.call(.manifest, bearer: bearer)
        receipt.record(.manifest, manifestResult)
        try requireSuccess(manifestResult)
        let manifest = try requireData(manifestResult).decode(RetraceCapabilityManifest.self)
        try acceptanceRequire(manifest.protocolVersion == 1 && manifest.liveLaptop &&
            Set(manifest.operations.map(\.operation)) == expectedOperations, "manifest_mismatch")

        let healthResult = try await client.call(.health, bearer: bearer)
        receipt.record(.health, healthResult)
        try requireSuccess(healthResult)
        let health = try requireData(healthResult).decode(RetraceOperationsSnapshot.self)
        try acceptanceRequire(health.liveLaptop && !health.recording && health.companion == nil &&
            health.voiceMarkers == nil && health.pendingText == nil && health.pendingSavedAudio == nil &&
            health.unavailable.contains(.cpuMeasurement), "private_health_must_preserve_unknown_state")

        let anchor = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1000) / 1000)
        let title = "AUTHORED MCP ACCEPTANCE — temporary"
        let note = "Disposable private fixture, not recorded speech."
        let createArguments = RetraceJSON.object(["anchoredAt": .number(anchor.timeIntervalSince1970 * 1000),
            "title": .string(title), "note": .string(note)])
        let createID = UUID()
        let created = try await client.call(.markerCreate, requestID: createID, arguments: createArguments, bearer: bearer)
        receipt.record(.markerCreate, created); try requireSuccess(created)
        let initial = try requireData(created).decode(PrivateMCPMarkerReceipt.self)
        receipt.markerID = initial.id
        try acceptanceRequire(initial.historicalOutcome, "creation_receipt_not_historical")
        let replay = try await client.call(.markerCreate, requestID: createID, arguments: createArguments, bearer: bearer)
        receipt.record(.markerCreate, replay); try requireSuccess(replay)
        try acceptanceRequire(replay.replayed && replay.data == created.data, "creation_retry_changed_outcome")
        let query = RetraceJSON.object(["from": .number(anchor.timeIntervalSince1970 * 1000),
            "to": .number(anchor.timeIntervalSince1970 * 1000), "limit": .integer(5), "query": .string("AUTHORED MCP ACCEPTANCE")])
        let listed = try await client.call(.markerList, arguments: query, bearer: bearer)
        receipt.record(.markerList, listed); try requireSuccess(listed)
        let page = try requireData(listed).decode(PrivateMCPMarkerPage.self)
        try acceptanceRequire(page.markers.count == 1 && page.markers.first?.id == initial.id && page.nextCursor == nil,
                              "create_retry_did_not_leave_exactly_one_marker")
        let local = try await markers.listMarkers()
        try acceptanceRequire(local.markers.count == 1 && local.markers.first?.revision == initial.revision,
                              "https_result_did_not_reach_private_native_owner")
        let readArguments = RetraceJSON.object(["id": .string(initial.id.uuidString)])
        let read = try await client.call(.markerRead, arguments: readArguments, bearer: bearer)
        receipt.record(.markerRead, read); try requireSuccess(read)
        let original = try requireData(read).decode(TimelineMarker.self)
        try acceptanceRequire(original.nativeStoreID == receipt.nativeStoreID && abs(original.anchoredAt.timeIntervalSince(anchor)) < 0.001 &&
            original.title == title && original.note == note && original.screenReference == nil && original.spokenObservation == nil,
            "authored_marker_identity_mismatch")

        let originalArguments = revisionArguments(initial)
        let oldPreviewResult = try await client.call(.markerRemove, arguments: originalArguments, mode: .preview, bearer: bearer)
        receipt.record(.markerRemove, oldPreviewResult)
        let oldPreview = try requirePreview(oldPreviewResult, marker: initial)
        let editedTitle = "AUTHORED MCP ACCEPTANCE — edited"
        let edited = try await client.call(.markerUpdate, arguments: .object([
            "id": .string(initial.id.uuidString), "expectedRevision": .string(initial.revision.uuidString),
            "title": .string(editedTitle), "note": .string(note)]), bearer: bearer)
        receipt.record(.markerUpdate, edited); try requireSuccess(edited)
        let updated = try requireData(edited).decode(PrivateMCPMarkerReceipt.self)
        try acceptanceRequire(updated.id == initial.id && updated.revision != initial.revision, "edit_did_not_advance_revision")
        let stale = try await client.call(.markerRemove, arguments: originalArguments, mode: .execute,
            confirmation: .init(previewID: oldPreview.id, digest: oldPreview.digest), bearer: bearer)
        receipt.record(.markerRemove, stale)
        try acceptanceRequire(stale.status == .conflict && stale.code == "revision_conflict", "stale_preview_was_not_rejected")
        let afterStale = try await markers.marker(id: initial.id)
        try acceptanceRequire(afterStale?.revision == updated.revision && afterStale?.anchoredAt == original.anchoredAt &&
            afterStale?.title == editedTitle, "stale_preview_changed_private_marker")

        let removalPreviewResult = try await client.call(.markerRemove, arguments: revisionArguments(updated), mode: .preview, bearer: bearer)
        receipt.record(.markerRemove, removalPreviewResult)
        let removalPreview = try requirePreview(removalPreviewResult, marker: updated)
        let removalID = UUID()
        let confirmation = RetracePreviewConfirmation(previewID: removalPreview.id, digest: removalPreview.digest)
        let removed = try await client.call(.markerRemove, requestID: removalID, arguments: revisionArguments(updated),
                                           mode: .execute, confirmation: confirmation, bearer: bearer)
        receipt.record(.markerRemove, removed); try requireSuccess(removed)
        let deleted = try requireData(removed).decode(PrivateMCPMarkerReceipt.self)
        try acceptanceRequire(deleted.id == initial.id && deleted.revision != updated.revision, "delete_revision_mismatch")
        let removeReplay = try await client.call(.markerRemove, requestID: removalID, arguments: revisionArguments(updated),
                                                mode: .execute, confirmation: confirmation, bearer: bearer)
        receipt.record(.markerRemove, removeReplay); try requireSuccess(removeReplay)
        try acceptanceRequire(removeReplay.replayed && removeReplay.data == removed.data, "removal_retry_changed_outcome")
        let missing = try await client.call(.markerRead, arguments: readArguments, bearer: bearer)
        receipt.record(.markerRead, missing)
        try acceptanceRequire(missing.status == .unavailable && missing.code == "operation_unavailable", "deleted_marker_remained_readable")
        let empty = try await client.call(.markerList, arguments: query, bearer: bearer)
        receipt.record(.markerList, empty); try requireSuccess(empty)
        try acceptanceRequire(try requireData(empty).decode(PrivateMCPMarkerPage.self).markers.isEmpty, "deleted_marker_remained_listed")

        let restored = try await client.call(.markerRestore, arguments: revisionArguments(deleted), bearer: bearer)
        receipt.record(.markerRestore, restored); try requireSuccess(restored)
        let restoredReceipt = try requireData(restored).decode(PrivateMCPMarkerReceipt.self)
        try acceptanceRequire(restoredReceipt.id == initial.id && restoredReceipt.revision != deleted.revision, "restore_revision_mismatch")
        let restoredRead = try await client.call(.markerRead, arguments: readArguments, bearer: bearer)
        receipt.record(.markerRead, restoredRead); try requireSuccess(restoredRead)
        let restoredMarker = try requireData(restoredRead).decode(TimelineMarker.self)
        try acceptanceRequire(restoredMarker.revision == restoredReceipt.revision && restoredMarker.title == editedTitle &&
            restoredMarker.anchoredAt == original.anchoredAt && restoredMarker.deletedAt == nil, "restored_marker_changed_anchor_or_content")
        let cleanupPreviewResult = try await client.call(.markerRemove, arguments: revisionArguments(restoredReceipt), mode: .preview, bearer: bearer)
        receipt.record(.markerRemove, cleanupPreviewResult)
        let cleanupPreview = try requirePreview(cleanupPreviewResult, marker: restoredReceipt)
        let cleanup = try await client.call(.markerRemove, arguments: revisionArguments(restoredReceipt), mode: .execute,
            confirmation: .init(previewID: cleanupPreview.id, digest: cleanupPreview.digest), bearer: bearer)
        receipt.record(.markerRemove, cleanup); try requireSuccess(cleanup)
        let finalPage = try await markers.listMarkers()
        try acceptanceRequire(finalPage.markers.isEmpty, "authored_marker_cleanup_failed")
    }
}

private struct PrivateMCPFailure: Error {
    let category: String
    init(_ category: String) { self.category = category }
}
private func acceptanceRequire(_ condition: Bool, _ category: String) throws {
    guard condition else { throw PrivateMCPFailure(category) }
}
private func requireSuccess(_ response: RetraceCommandResponse) throws {
    try acceptanceRequire(response.status == .succeeded && !response.queued, "expected_success_\(response.code ?? response.status.rawValue)")
}
private func requireData(_ response: RetraceCommandResponse) throws -> RetraceJSON {
    guard let data = response.data else { throw PrivateMCPFailure("missing_native_data") }
    return data
}
private func revisionArguments(_ marker: PrivateMCPMarkerReceipt) -> RetraceJSON {
    .object(["id": .string(marker.id.uuidString), "expectedRevision": .string(marker.revision.uuidString)])
}
private func requirePreview(_ response: RetraceCommandResponse, marker: PrivateMCPMarkerReceipt) throws -> RetraceDestructivePreview {
    guard response.status == .preview, !response.queued, let preview = response.preview else { throw PrivateMCPFailure("missing_destructive_preview") }
    try acceptanceRequire(preview.affectedCount == 1 && preview.revision == marker.revision.uuidString &&
        preview.summary.contains(marker.id.uuidString) && preview.expiresAt > Date(), "preview_scope_mismatch")
    return preview
}
private struct PrivateMCPMarkerReceipt: Decodable { let id: UUID; let revision: UUID; let historicalOutcome: Bool }
private struct PrivateMCPMarkerPage: Decodable { let markers: [TimelineMarker]; let nextCursor: TimelineMarkerCursor? }
private struct PrivateMCPRejection: Decodable { let error: String; let queued: Bool }
private struct PrivateMCPTool: Decodable { let name: String }

private final class PrivateMCPRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private final class PrivateMCPClient {
    static let endpoint = URL(string: "https://stuarts-macbook-pro.tail7a4fcb.ts.net/retrace-mcp")!
    private let session: URLSession
    private let redirectGuard = PrivateMCPRedirectGuard()
    private let deadline = ContinuousClock.now.advanced(by: .seconds(240))
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }
    func close() { session.invalidateAndCancel() }
    func raw(method: String, parameters: RetraceJSON, bearer: String) async throws -> (status: Int, data: Data) {
        try Task.checkCancellation()
        try acceptanceRequire(ContinuousClock.now < deadline, "transport_acceptance_deadline")
        let rpc = RetraceJSON.object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString),
            "method": .string(method), "params": parameters])
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.httpBody = try RetraceWire.encoder().encode(rpc)
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == Self.endpoint,
              http.expectedContentLength <= 1_048_576 else { throw PrivateMCPFailure("unexpected_http_response") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw PrivateMCPFailure("http_response_limit") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (http.statusCode, data)
    }
    func tools(bearer: String) async throws -> [PrivateMCPTool] {
        let response = try await raw(method: "tools/list", parameters: .object([:]), bearer: bearer)
        let result = try rpcResult(response)
        struct Tools: Decodable { let tools: [PrivateMCPTool] }
        return try result.decode(Tools.self).tools
    }
    func call(_ operation: RetraceOperation, requestID: UUID = UUID(), arguments: RetraceJSON = .object([:]),
              mode: RetraceCommandRequest.Mode? = nil, confirmation: RetracePreviewConfirmation? = nil,
              bearer: String) async throws -> RetraceCommandResponse {
        var input: [String: RetraceJSON] = ["request_id": .string(requestID.uuidString), "arguments": arguments]
        if let mode { input["mode"] = .string(mode.rawValue) }
        if let confirmation { input["confirmation"] = try .encode(confirmation) }
        let response = try await raw(method: "tools/call", parameters: .object([
            "name": .string("retrace_" + operation.rawValue.replacingOccurrences(of: ".", with: "_")),
            "arguments": .object(input)]), bearer: bearer)
        struct Content: Decodable { let type: String; let text: String? }
        struct Result: Decodable { let isError: Bool?; let content: [Content]; let structuredContent: RetraceJSON? }
        let result = try rpcResult(response).decode(Result.self)
        try acceptanceRequire(result.isError != true, "mcp_tool_error")
        let native: RetraceCommandResponse
        if let structured = result.structuredContent { native = try structured.decode(RetraceCommandResponse.self) }
        else {
            guard result.content.count == 1, result.content[0].type == "text", let text = result.content[0].text else {
                throw PrivateMCPFailure("unexpected_mcp_content")
            }
            native = try RetraceWire.decoder().decode(RetraceCommandResponse.self, from: Data(text.utf8))
        }
        try acceptanceRequire(operation == .manifest || native.requestID == requestID, "native_request_id_mismatch")
        return native
    }
    private func rpcResult(_ response: (status: Int, data: Data)) throws -> RetraceJSON {
        try acceptanceRequire(response.status == 200, "http_status_\(response.status)")
        struct RPC: Decodable { let jsonrpc: String; let result: RetraceJSON?; let error: RetraceJSON? }
        let rpc = try RetraceWire.decoder().decode(RPC.self, from: response.data)
        guard rpc.jsonrpc == "2.0", rpc.error == nil, let result = rpc.result else { throw PrivateMCPFailure("mcp_rpc_failure") }
        return result
    }
}

private struct PrivateMCPReceipt: Encodable {
    struct Step: Encodable {
        let operation: RetraceOperation; let requestID: UUID; let status: RetraceCommandResponse.Status
        let code: String?; let replayed: Bool; let observedAt: Date
    }
    let scope = "Private authored native fixture through deployed HTTPS gateway; not installed-App acceptance"
    let endpoint = PrivateMCPClient.endpoint.absoluteString
    let startedAt = Date()
    let nativeStoreID: UUID
    var completedAt: Date?
    var markerID: UUID?
    var steps: [Step] = []
    var revokedListenerStopped = false
    var revokedGatewayStatus: Int?
    var closedListenerStopped = false
    var fixtureRemoved = false
    var passed = false
    var failure: String?
    mutating func record(_ operation: RetraceOperation, _ response: RetraceCommandResponse) {
        steps.append(.init(operation: operation, requestID: response.requestID, status: response.status,
                           code: response.code, replayed: response.replayed, observedAt: response.observedAt))
    }
}
private func makePrivateMCPDirectory(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    guard mkdir(root.path, 0o700) == 0 else { throw PrivateMCPFailure("private_directory_creation") }
    return root
}
private func writePrivateMCPReceipt(_ receipt: PrivateMCPReceipt, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw PrivateMCPFailure("receipt_creation") }
    defer { Darwin.close(descriptor) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.write(contentsOf: RetraceWire.encoder().encode(receipt))
    guard fsync(descriptor) == 0 else { throw PrivateMCPFailure("receipt_sync") }
}
private func requirePrivateMCPPortAvailable() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw PrivateMCPFailure("port_check_socket") }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(9013).bigEndian
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw PrivateMCPFailure("port_check_address") }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try acceptanceRequire(result == 0, "port_9013_already_owned")
}
