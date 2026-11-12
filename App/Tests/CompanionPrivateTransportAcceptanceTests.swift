import AVFoundation
import Darwin
import Foundation
import Processing
import Shared
import SQLCipher
import Storage
import XCTest
@testable import App
@testable import Database

/// Explicitly sends two authored jobs through the deployed private companion.
/// No AppCoordinator, installed library, preferences, Keychain or device is used.
/// This verifies native transport/import, not installed-App or speaker accuracy acceptance.
final class CompanionPrivateTransportAcceptanceTests: XCTestCase {
    func testDeployedCompanionImportsAuthoredContextAndSpeechThroughNativeOwner() async throws {
        #if !DEBUG
        throw XCTSkip("Private companion acceptance requires debug file isolation")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["RETRACE_TEST_PRIVATE_COMPANION_TRANSPORT"] == "1" else {
            throw XCTSkip("Set RETRACE_TEST_PRIVATE_COMPANION_TRANSPORT=1 for two authored remote jobs")
        }
        try companionRequire(environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1", "file_logging_must_be_disabled")
        try companionRequire(environment["RETRACE_TEST_PRIVATE_COMPANION_ENDPOINT"] == CompanionPrivateFixture.endpoint.absoluteString,
                             "explicit_existing_endpoint_required")
        let artifactRoot = try companionArtifactRoot(path: environment["RETRACE_TEST_COMPANION_ARTIFACT_ROOT"])
        defer { Darwin.close(artifactRoot.descriptor) }
        // The environment contains only a descriptor number. The credential itself
        // must arrive through a bounded, explicitly inherited anonymous pipe.
        let credential = try readCompanionCredential(descriptor: environment["RETRACE_TEST_COMPANION_TOKEN_FD"])
        let root = try companionPrivateDirectory(under: artifactRoot, prefix: "retrace-companion-import-")
        let receiptRoot = try companionPrivateDirectory(under: artifactRoot, prefix: "retrace-companion-import-receipt-")
        let receiptURL = receiptRoot.appendingPathComponent("receipt.json")
        var receipt = CompanionPrivateReceipt()
        var fixture: CompanionPrivateFixture?
        var failure: (any Error)?
        do {
            let first = try await CompanionPrivateFixture.open(root: root, bootstrap: true)
            fixture = first
            receipt.nativeStoreID = first.native
            let authored = try await first.prepareAuthoredEvidence()
            receipt.markerID = authored.marker.id
            receipt.audioSHA256 = authored.aacSHA256
            receipt.authoredInputSHA256 = CompanionPrivateFixture.speechSHA256
            receipt.originalSource = authored.source

            // Enable the real controller before registering the fresh manifest.
            // An older or disabled-period manifest must never be auto-enrolled.
            try await first.owner.configure(.init(endpoint: CompanionPrivateFixture.endpoint, bearerToken: credential))
            let manifest = try await first.media.register(authored.mediaReceipt)
            let published = try await first.owner.recordedBatch(manifest: manifest, records: authored.firstPass)
            let retry = try await first.owner.recordedBatch(manifest: manifest, records: authored.firstPass)
            try companionRequire(published == retry && published.jobIDs.count == 1 && !published.alreadyCovered,
                                 "speech_retry_changed_publication")
            // The configure loop owns the first context publication. Wait for its
            // durable transaction before deliberately exercising retry calls.
            try await first.awaitInitialContextPublication()
            try await first.owner.refreshMarker(markerID: authored.marker.id)
            try await first.owner.refreshMarker(markerID: authored.marker.id)

            let records = try await first.awaitAcknowledgedJobs()
            let speechRecord = try companionUnwrap(records.first { $0.jobID == published.jobIDs[0] }, "speech_job_missing")
            let contextRecord = try companionUnwrap(records.first { $0.jobID != speechRecord.jobID }, "context_job_missing")
            let speechRequest = try CompanionWire.decode(CompanionJobRequest.self, data: speechRecord.requestPayload, limit: 768 * 1024)
            let contextRequest = try CompanionWire.decode(CompanionJobRequest.self, data: contextRecord.requestPayload, limit: 768 * 1024)
            try companionRequire(speechRequest.kind == .speaker && contextRequest.kind == .context, "two_job_kinds_mismatch")
            let speechResultData = try companionUnwrap(speechRecord.resultPayload, "speech_result_missing")
            let contextResultData = try companionUnwrap(contextRecord.resultPayload, "context_result_missing")
            let speechResult = try CompanionWire.decode(CompanionResult.self, data: speechResultData, limit: 2 * 1024 * 1024)
            let contextResult = try CompanionWire.decode(CompanionResult.self, data: contextResultData, limit: 2 * 1024 * 1024)
            try CompanionWire.validate(speechResult, request: speechRequest, id: speechRecord.jobID)
            try CompanionWire.validate(contextResult, request: contextRequest, id: contextRecord.jobID)
            try companionRequire(CompanionWire.digest(speechRecord.requestPayload) == speechRecord.jobID &&
                CompanionWire.digest(contextRecord.requestPayload) == contextRecord.jobID, "request_digest_mismatch")
            let requestSpeech = try companionUnwrap(speechRequest.speaker, "speech_request_missing")
            try companionRequire(requestSpeech.sourceIdentity == authored.source &&
                requestSpeech.firstPassReferences == authored.firstPassReferences &&
                requestSpeech.firstPassText == CompanionPrivateFixture.firstPassText &&
                requestSpeech.media.count == 1 && requestSpeech.media[0].sha256 == manifest.sha256,
                "speech_source_identity_mismatch")
            let requestContext = try companionUnwrap(contextRequest.context, "context_request_missing")
            try companionRequire(requestContext.markerID == authored.marker.id &&
                requestContext.markerRevision == authored.marker.revision &&
                requestContext.evidence.count == 1 && requestContext.evidence[0].reference.v23Transcript == authored.contextReference,
                "context_exact_reference_mismatch")
            let retained = try companionUnwrap(try await first.markers.contextProposal(jobID: contextRecord.jobID), "native_context_import_missing")
            try companionRequire(retained.requestPayload == contextRecord.requestPayload && retained.resultPayload == contextResultData &&
                retained.resultSHA256 == CompanionWire.digest(contextResultData), "native_context_import_digest_mismatch")
            let ranges = try await first.owner.contextRanges().list(markerID: authored.marker.id)
            try companionRequire(!ranges.items.isEmpty && ranges.items.allSatisfy { $0.availability == .available && $0.range != nil },
                                 "native_context_support_unavailable")
            let rangeReference = try companionUnwrap(ranges.items.first?.reference, "context_range_missing")
            let batch = try companionUnwrap(try await first.owner.speakerPresentation(jobID: speechRecord.jobID), "native_speech_import_missing")
            try companionRequire(!batch.turnReferences.isEmpty && !batch.enhancement.automaticNamesCalibrated &&
                batch.firstPassText == CompanionPrivateFixture.firstPassText && batch.firstPassReferences == authored.firstPassReferences,
                "native_speech_presentation_mismatch")
            let turnReference = try companionUnwrap(batch.turnReferences.first, "native_turn_missing")
            let turn = try await first.owner.resolveTurn(turnReference)
            let pcm = try await first.media.resolvePCM(.init(nativeStoreID: first.native, identity: turn.sourceIdentity))
            try companionRequire(!pcm.isEmpty && pcm.count == turn.sourceIdentity.sampleCount * 2 &&
                turn.sourceIdentity.startSample >= authored.source.startSample &&
                turn.sourceIdentity.startSample + turn.sourceIdentity.sampleCount <= authored.source.startSample + authored.source.sampleCount,
                "native_turn_pcm_range_mismatch")
            let originalAAC = try await first.media.verifiedBytes(for: manifest)
            let originalPCM = try ExactAudioDecoder.decode(aac: originalAAC, expectedFrames: authored.source.sampleCount)
            let offset = Int((turn.sourceIdentity.startSample - authored.source.startSample) * 2)
            try companionRequire(pcm == originalPCM.subdata(in: offset..<(offset + pcm.count)), "native_turn_pcm_differed_from_original")
            receipt.turnPCMCount = pcm.count
            receipt.turnPCMSHA256 = CompanionWire.digest(pcm)
            receipt.turnReference = turnReference
            receipt.contextRangeReference = rangeReference
            receipt.contextRangeCount = ranges.items.count
            receipt.speakerTurnCount = batch.turnReferences.count
            receipt.modelFingerprint = batch.enhancement.modelFingerprint
            receipt.firstPassReferences = batch.firstPassReferences
            receipt.jobs = try records.map { record in
                let request = try CompanionWire.decode(CompanionJobRequest.self, data: record.requestPayload, limit: 768 * 1024)
                return .init(id: record.jobID, kind: request.kind.rawValue, stage: record.stage.rawValue,
                             resultSHA256: record.resultPayload.map(CompanionWire.digest))
            }
            try await first.verifyOriginals(authored, manifest: manifest)
            let completedRetry = try await first.owner.recordedBatch(manifest: manifest, records: authored.firstPass)
            try companionRequire(completedRetry == published, "acknowledged_retry_changed_publication")
            try await first.owner.refreshMarker(markerID: authored.marker.id)
            try companionRequire(try await first.deliveryRecords().count == 2, "retry_published_extra_job")
            receipt.publicationRetryPreserved = true
            try await first.close()
            fixture = nil

            // Reopen every native owner without configuring transport. Retained
            // reads still validate the exact private recording rows and AAC.
            let reopened = try await CompanionPrivateFixture.open(root: root, bootstrap: false)
            fixture = reopened
            try companionRequire(reopened.native == receipt.nativeStoreID, "reopen_store_identity_changed")
            let offlineState = await reopened.owner.status()
            try companionRequire(offlineState.state == .unconfigured, "offline_reopen_started_transport")
            let offlineTurn = try await reopened.owner.resolveTurn(turnReference)
            let offlinePCM = try await reopened.media.resolvePCM(.init(nativeStoreID: reopened.native, identity: offlineTurn.sourceIdentity))
            try companionRequire(CompanionWire.digest(offlinePCM) == receipt.turnPCMSHA256, "offline_pcm_changed")
            let offlineContext = try await reopened.owner.contextRanges().resolve(rangeReference)
            try companionRequire(offlineContext.availability == .available, "offline_context_unavailable")
            try await reopened.verifyOriginals(authored, manifest: manifest)
            receipt.offlineReopenValidated = true
            receipt.firstPassAndAACPreserved = true

            // Only now deliberately revise authored source text. No remote owner
            // is active, so invalidation cannot enqueue an additional job.
            reopened.owner.sourceChanged(refreshContext: false)
            try await reopened.audio.updateTranscriptionText(id: authored.contextReference.rowID, text: "Authored source revised after acceptance")
            let staleContext = try await reopened.owner.contextRanges().resolve(rangeReference)
            try companionRequire(staleContext.availability == .sourceUnavailable && staleContext.range == nil,
                                 "stale_context_leaked_derived_text")
            reopened.owner.sourceChanged(refreshContext: false)
            try await reopened.audio.updateTranscriptionText(id: authored.firstPassReferences[0].rowID, text: "Authored first pass revised after acceptance")
            do {
                _ = try await reopened.owner.resolveTurn(turnReference)
                throw CompanionPrivateFailure("stale_turn_still_resolved")
            } catch CompanionError.staleEvidence { }
            receipt.staleSourceInvalidated = true
            try companionRequire(try await reopened.deliveryRecords().count == 2, "offline_read_created_job")
            let finalBytes = try await reopened.media.verifiedBytes(for: manifest)
            try companionRequire(CompanionWire.digest(finalBytes) == authored.aacSHA256, "source_mutation_changed_aac")
        } catch { failure = error }

        var cleanupJoined = true
        if let fixture {
            do { try await fixture.close() }
            catch { cleanupJoined = false; if failure == nil { failure = error } }
        }
        receipt.joinedCleanup = cleanupJoined
        if cleanupJoined, failure == nil {
            do { try FileManager.default.removeItem(at: root); receipt.fixtureRemoved = true }
            catch { if failure == nil { failure = error } }
        }
        if !receipt.fixtureRemoved { receipt.retainedFixturePath = root.path }
        receipt.completedAt = Date()
        receipt.passed = failure == nil
        receipt.failure = failure.map { ($0 as? CompanionPrivateFailure)?.category ?? "fixture_failed" }
        try writeCompanionReceipt(receipt, to: receiptURL)
        print("Private authored companion import receipt: \(receiptURL.path)")
        if failure != nil { throw CompanionPrivateFailure(receipt.failure ?? "fixture_failed") }
        #endif
    }
}

#if DEBUG
private struct CompanionPrivateFixture {
    static let endpoint = URL(string: "https://stuarts-macbook-pro.tail7a4fcb.ts.net/retrace-companion")!
    static let speechPath = "/tmp/retrace-live-context-20261021/authored-stream-speech.aiff"
    static let speechSHA256 = "ae0a36ff7f807a97c092b46063043b74b801966b7e55084bbefc8e370d2b7936"
    static let firstPassText = "This is an authored demonstration about a planning decision. Purple banana. Preserve the explanation about the Cedar document and the revised delivery date. We discussed the details before this moment, and the final reason follows now. The fictional invoice must be checked before Friday. Here is a separate reminder. Purple banana. The second marker concerns a different decision about the fictional Harbor project. Keep the first decision distinct from this second explanation. The near miss is purple bandana. Those words are an example and should not activate a marker. This ends the authored demonstration."
    static let contextText = "Cobalt paperwork review: the Cobalt paperwork must be checked before approval because the fictional delivery address changed. Preserve this Cobalt paperwork review explanation."
    let root: URL
    let database: DatabaseManager
    let adapter: DataAdapter
    let recall: ProgressiveRecallService
    let audio: AudioTranscriptionQueries
    let markers: TimelineMarkerService
    let media: MarkerAudioMediaService
    let owner: CompanionController
    let native: UUID

    static func open(root: URL, bootstrap: Bool) async throws -> Self {
        let path = root.appendingPathComponent("recording.db").path
        if bootstrap { try await bootstrapDatabase(path) }
        let database = DatabaseManager(testingUnencryptedDatabasePath: path)
        var adapter: DataAdapter?
        var markers: TimelineMarkerService?
        do {
            try await database.initialize()
            let reader = try SQLiteConnection(readOnlyDatabasePath: path)
            let data = DataAdapter(retraceConnection: reader,
                retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
                retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
            adapter = data
            try await data.initialize()
            let native = try await data.evidenceStoreID(source: .native)
            let markerOwner = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
            markers = markerOwner
            let media = MarkerAudioMediaService(storageRoot: root, markers: markerOwner, nativeStoreID: { native })
            let recall = ProgressiveRecallService(database: database, adapter: data, configuration: { CaptureConfig() },
                imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
            let owner = CompanionController(storageRoot: root.appendingPathComponent("companion"), nativeStoreID: native,
                databasePath: path, adapter: data, recall: recall, markers: markerOwner,
                verifiedBytes: { try await media.verifiedBytes(for: $0) }, policy: {})
            let pointer = try companionUnwrap(await database.getConnection(), "private_database_pointer_missing")
            return .init(root: root, database: database, adapter: data, recall: recall,
                         audio: AudioTranscriptionQueries(db: pointer), markers: markerOwner, media: media, owner: owner, native: native)
        } catch {
            try? await markers?.close()
            await adapter?.shutdown()
            try? await database.close()
            throw error
        }
    }
    struct Authored {
        let marker: TimelineMarker
        let contextReference: V23TranscriptReference
        let firstPass: [AudioTranscription]
        let firstPassReferences: [V23TranscriptReference]
        let source: LiveAudioSampleIdentity
        let mediaReceipt: PersistedAudioBatchReceipt
        let aacSHA256: String
    }
    func prepareAuthoredEvidence() async throws -> Authored {
        let inputBytes = try boundedCompanionFile(URL(fileURLWithPath: Self.speechPath), maximum: 8 * 1024 * 1024)
        try companionRequire(CompanionWire.digest(inputBytes) == Self.speechSHA256, "authored_speech_digest_mismatch")
        let copiedInput = root.appendingPathComponent("authored-input.aiff")
        try inputBytes.write(to: copiedInput, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copiedInput.path)
        let pcm = try convertCompanionSpeech(copiedInput)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(audioData: pcm, timestamp: start, source: .microphone)
        let file = root.appendingPathComponent(saved.filePath)
        let aac = try boundedCompanionFile(file, maximum: 16 * 1024 * 1024)
        _ = try ExactAudioDecoder.decode(aac: aac, expectedFrames: Int64(pcm.count / 2))
        let end = start.addingTimeInterval(Double(pcm.count / 2) / 16_000)
        let id = try await audio.insertTranscription(sessionID: nil, text: Self.firstPassText, startTime: start, endTime: end,
            source: .microphone, confidence: nil, words: [], audioPath: saved.filePath, transcriptionPass: 1, batchAudioPath: saved.filePath)
        let contextStart = start.addingTimeInterval(-600)
        let contextID = try await audio.insertTranscription(sessionID: nil, text: Self.contextText, startTime: contextStart,
            endTime: contextStart.addingTimeInterval(12), source: .system, confidence: nil, words: [])
        let contextRow = try companionUnwrap(try await audio.getContextEntry(id: contextID), "context_source_missing")
        let firstPass = try await audio.getContextBatchEntries(batchAudioPath: saved.filePath)
        try companionRequire(firstPass.count == 1 && firstPass[0].id == id, "authored_first_pass_missing")
        let source = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: 80_000,
            sampleCount: Int64(pcm.count / 2), sampleRate: 16_000, approximateOrigin: start.addingTimeInterval(-5))
        let marker = try await markers.createManualMarker(.init(anchoredAt: start, title: "Cobalt paperwork",
            note: "Cobalt paperwork approval justification."))
        return .init(marker: marker, contextReference: try CompanionTranscriptSnapshot.reference(for: contextRow, nativeStoreID: native),
            firstPass: firstPass, firstPassReferences: try CompanionTranscriptSnapshot.firstPassReferences(for: firstPass, nativeStoreID: native),
            source: source, mediaReceipt: .init(rawBatchID: id, relativePath: saved.filePath, fileURL: file, fileSize: saved.fileSize,
                frameCount: source.sampleCount, sampleRate: 16_000, channels: 1, source: .microphone, startTimestamp: start,
                endTimestamp: end, sourceRanges: [.init(source: source, batchStartSample: 0)]), aacSHA256: CompanionWire.digest(aac))
    }
    func deliveryRecords(includeResults: Bool = false) async throws -> [CompanionDeliveryRecord] {
        let catalog = CompanionDeliveryDatabase(databasePath: root.appendingPathComponent("companion/delivery/delivery.db").path,
                                                nativeStoreID: native, readOnly: true)
        do {
            try await catalog.initialize()
            let summaries = try await catalog.records(activeOnly: false, limit: 8)
            var records: [CompanionDeliveryRecord] = []
            for summary in summaries {
                if includeResults {
                    // Listing deliberately omits potentially large result payloads.
                    // Fetch the exact immutable bytes through the bounded ID API.
                    let record = try companionUnwrap(try await catalog.record(jobID: summary.jobID, includeResult: true),
                                                     "exact_delivery_record_missing")
                    try companionRequire(record.sequence == summary.sequence && record.stage == summary.stage &&
                        record.requestPayload == summary.requestPayload, "delivery_record_changed_during_read")
                    records.append(record)
                } else { records.append(summary) }
            }
            try await catalog.close()
            return records
        } catch { try? await catalog.close(); throw error }
    }
    func awaitAcknowledgedJobs() async throws -> [CompanionDeliveryRecord] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(480))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let records = try await deliveryRecords()
            try companionRequire(records.count <= 2, "unexpected_extra_remote_job")
            if records.count == 2 && records.allSatisfy({ $0.stage == .acknowledged }) {
                let retained = try await deliveryRecords(includeResults: true)
                try companionRequire(retained.count == 2 && retained.allSatisfy { $0.stage == .acknowledged } &&
                    Set(retained.map(\.jobID)) == Set(records.map(\.jobID)), "acknowledged_jobs_changed")
                return retained
            }
            try companionRequire(!records.contains { $0.stage == .invalidated }, "native_delivery_invalidated")
            try await Task.sleep(for: .seconds(2))
        }
        throw CompanionPrivateFailure("remote_jobs_deadline_exceeded")
    }
    func awaitInitialContextPublication() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            let records = try await deliveryRecords()
            try companionRequire(records.count <= 2, "unexpected_extra_remote_job")
            for record in records {
                let request = try CompanionWire.decode(CompanionJobRequest.self, data: record.requestPayload, limit: 768 * 1024)
                if request.kind == .context { return }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CompanionPrivateFailure("initial_context_publication_deadline_exceeded")
    }
    func verifyOriginals(_ authored: Authored, manifest: AudioMediaManifest) async throws {
        let current = try await audio.getContextBatchEntries(batchAudioPath: manifest.relativePath)
        try companionRequire(try CompanionTranscriptSnapshot.firstPassReferences(for: current, nativeStoreID: native) == authored.firstPassReferences &&
            current.map(\.text).joined(separator: "\n") == Self.firstPassText, "first_pass_changed_by_enrichment")
        let bytes = try await media.verifiedBytes(for: manifest)
        try companionRequire(CompanionWire.digest(bytes) == authored.aacSHA256, "original_aac_changed_by_enrichment")
    }
    func close() async throws {
        // Cancellation and all transport callbacks are joined before either DB closes.
        try await owner.close()
        try await markers.close()
        await adapter.shutdown()
        try await database.close()
    }
}

private func bootstrapDatabase(_ path: String) async throws {
    let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    try companionRequire(fd >= 0, "private_database_creation_failed")
    Darwin.close(fd)
    var raw: OpaquePointer?
    let status = sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK, let raw else {
        if let raw { sqlite3_close_v2(raw) }
        throw CompanionPrivateFailure("private_database_open_failed")
    }
    defer { sqlite3_close_v2(raw) }
    let migrations = MigrationRunner(db: raw)
    try await migrations.runMigrations()
    try companionRequire(try await migrations.getCurrentVersion() == 24, "private_recording_schema_not_v24")
    // DatabaseManager checks this row before consulting any Rewind location.
    try companionRequire(sqlite3_exec(raw, "INSERT INTO sqlite_sequence(name,seq) VALUES('frame',0)", nil, nil, nil) == SQLITE_OK,
                         "private_frame_sequence_bootstrap_failed")
}

private func convertCompanionSpeech(_ url: URL) throws -> Data {
    let file = try AVAudioFile(forReading: url)
    try companionRequire(file.length > 0 && Double(file.length) / file.processingFormat.sampleRate <= 60, "authored_speech_duration_invalid")
    let input = try companionUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)), "input_buffer_failed")
    try file.read(into: input)
    let format = try companionUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true), "pcm_format_failed")
    let converter = try companionUnwrap(AVAudioConverter(from: input.format, to: format), "pcm_converter_failed")
    var delivered = false, result = Data()
    for _ in 0..<256 {
        let output = try companionUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192), "output_buffer_failed")
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if !delivered { delivered = true; state.pointee = .haveData; return input }
            state.pointee = .endOfStream; return nil
        }
        try companionRequire(error == nil && status != .error, "pcm_conversion_failed")
        if output.frameLength > 0 {
            let pointer = try companionUnwrap(output.int16ChannelData?[0], "pcm_samples_missing")
            result.append(Data(bytes: pointer, count: Int(output.frameLength) * 2))
        }
        try companionRequire(result.count <= 60 * 16_000 * 2, "pcm_duration_exceeded")
        if status == .endOfStream { return result }
        try companionRequire(output.frameLength > 0, "pcm_conversion_stalled")
    }
    throw CompanionPrivateFailure("pcm_conversion_iteration_limit")
}

private func readCompanionCredential(descriptor: String?) throws -> String {
    guard let descriptor, let fd = Int32(descriptor), (3...1024).contains(fd), String(fd) == descriptor else {
        throw CompanionPrivateFailure("explicit_credential_pipe_required")
    }
    defer { Darwin.close(fd) }
    var info = stat()
    try companionRequire(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO && info.st_uid == geteuid(), "credential_descriptor_not_private_pipe")
    let flags = fcntl(fd, F_GETFL)
    try companionRequire(flags >= 0 && flags & O_ACCMODE == O_RDONLY &&
        fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, "credential_pipe_flags_invalid")
    var bytes = [UInt8](repeating: 0, count: 65)
    defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
    var count = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        var event = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = poll(&event, 1, 100)
        if ready < 0 && errno == EINTR { continue }
        try companionRequire(ready >= 0, "credential_pipe_poll_failed")
        if ready == 0 { continue }
        let received = bytes.withUnsafeMutableBytes { pointer in Darwin.read(fd, pointer.baseAddress!.advanced(by: count), 65 - count) }
        if received < 0 && [EINTR, EAGAIN].contains(errno) { continue }
        try companionRequire(received >= 0, "credential_pipe_read_failed")
        if received == 0 {
            try companionRequire(count == 64 && bytes.prefix(count).allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }, "credential_pipe_must_contain_exactly_64_url_safe_ascii_bytes")
            return String(decoding: bytes.prefix(count), as: UTF8.self)
        }
        count += received
        try companionRequire(count <= 64, "credential_pipe_exceeded_bound")
    }
    throw CompanionPrivateFailure("credential_pipe_deadline_exceeded")
}

private func boundedCompanionFile(_ url: URL, maximum: Int) throws -> Data {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try companionRequire(fd >= 0, "authored_file_open_failed")
    defer { Darwin.close(fd) }
    var info = stat()
    try companionRequire(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size > 0 && info.st_size <= maximum,
                         "authored_file_bounds_invalid")
    var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        try companionRequire(count >= 0, "authored_file_read_failed")
        if count == 0 { break }
        try companionRequire(result.count + count <= maximum, "authored_file_exceeded_bound")
        result.append(contentsOf: buffer.prefix(count))
    }
    try companionRequire(result.count == info.st_size, "authored_file_changed")
    return result
}

private struct CompanionPrivateReceipt: Encodable {
    struct Job: Encodable { let id: String; let kind: String; let stage: String; let resultSHA256: String? }
    let version = 1
    let startedAt = Date()
    let installedAppAcceptance = false
    let physicalSpeechLatencyAcceptance = false
    var completedAt: Date?
    var nativeStoreID: UUID?
    var markerID: UUID?
    var authoredInputSHA256: String?
    var audioSHA256: String?
    var originalSource: LiveAudioSampleIdentity?
    var firstPassReferences: [V23TranscriptReference] = []
    var jobs: [Job] = []
    var turnReference: CompanionTurnReference?
    var contextRangeReference: ContextRangePresentationReference?
    var contextRangeCount = 0
    var speakerTurnCount = 0
    var modelFingerprint: String?
    var turnPCMCount = 0
    var turnPCMSHA256: String?
    var publicationRetryPreserved = false
    var offlineReopenValidated = false
    var firstPassAndAACPreserved = false
    var staleSourceInvalidated = false
    var joinedCleanup = false
    var fixtureRemoved = false
    var retainedFixturePath: String?
    var passed = false
    var failure: String?
}

private struct CompanionPrivateArtifactRoot {
    let url: URL
    let descriptor: Int32
}

private func companionArtifactRoot(path: String?) throws -> CompanionPrivateArtifactRoot {
    guard let path, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
        throw CompanionPrivateFailure("explicit_absolute_artifact_root_required")
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    try companionRequire((2...128).contains(components.count) && components.first?.isEmpty == true &&
        components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 },
        "artifact_root_path_not_canonical")
    // Walk from / without following any symlink, including macOS /tmp -> /private/tmp.
    // The launcher must supply the existing physical path, not a temporary-directory hint.
    var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try companionRequire(directory >= 0, "artifact_root_open_failed")
    defer { if directory >= 0 { Darwin.close(directory) } }
    for component in components.dropFirst() {
        let child = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try companionRequire(child >= 0, "artifact_root_missing_or_symlinked")
        Darwin.close(directory)
        directory = child
    }
    var info = stat()
    try companionRequire(fstat(directory, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
        info.st_uid == geteuid() && info.st_mode & 0o7777 == 0o700, "artifact_root_must_be_owned_0700_directory")
    let result = CompanionPrivateArtifactRoot(url: URL(fileURLWithPath: path, isDirectory: true), descriptor: directory)
    directory = -1
    return result
}

private func companionPrivateDirectory(under parent: CompanionPrivateArtifactRoot, prefix: String) throws -> URL {
    let name = prefix + UUID().uuidString
    try companionRequire(mkdirat(parent.descriptor, name, 0o700) == 0, "private_artifact_child_creation_failed")
    let child = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try companionRequire(child >= 0, "private_artifact_child_open_failed")
    defer { Darwin.close(child) }
    var info = stat()
    try companionRequire(fstat(child, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
        info.st_uid == geteuid() && info.st_mode & 0o7777 == 0o700, "private_artifact_child_permissions_invalid")
    return parent.url.appendingPathComponent(name, isDirectory: true)
}
private func writeCompanionReceipt(_ receipt: CompanionPrivateReceipt, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let bytes = try encoder.encode(receipt)
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    try companionRequire(fd >= 0, "receipt_creation_failed")
    defer { Darwin.close(fd) }
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            try companionRequire(count > 0, "receipt_write_failed")
            offset += count
        }
    }
    try companionRequire(fsync(fd) == 0, "receipt_sync_failed")
}
private struct CompanionPrivateFailure: Error, CustomStringConvertible {
    let category: String
    init(_ category: String) { self.category = category }
    var description: String { category }
}
private func companionRequire(_ condition: Bool, _ category: String) throws {
    guard condition else { throw CompanionPrivateFailure(category) }
}
private func companionUnwrap<T>(_ value: T?, _ category: String) throws -> T {
    guard let value else { throw CompanionPrivateFailure(category) }
    return value
}
#endif
