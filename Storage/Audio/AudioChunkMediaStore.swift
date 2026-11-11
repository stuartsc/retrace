import AudioToolbox
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Shared

public enum AudioChunkMediaStorageError: Error, Sendable {
    case closed, invalidInput, integrityFailure, conflictingIdentity, unavailable, queueFull
}

/// Immutable ten-second AAC chunks and bounded, overlapping logical windows.
/// The publication journal contains the original PCM and complete predecessor
/// plan in one atomic record, so encoding/publication failures remain retryable.
public actor AudioChunkMediaStore: AudioChunkMediaStoreProtocol {
    public nonisolated let storageRoot: URL
    public nonisolated let storeID: UUID
    private let ownerID = UUID()
    private let rootKey: String
    private var closed = false
    private var operations = 0
    private var releasing = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var leases: [UUID: AudioWindowReadLease] = [:]
    private static let maximumJournalBytes = 512 * 1_024
    private static let maximumManifestBytes = 32 * 1_024
    private static let maximumEncodedBytes = 2 * 1_024 * 1_024

    public init(storageRoot: URL, storeID: UUID) {
        self.storageRoot = storageRoot.resolvingSymlinksInPath().standardizedFileURL
        self.storeID = storeID
        self.rootKey = self.storageRoot.path + ":" + storeID.uuidString.lowercased()
    }

    public func persistChunk(_ input: AudioChunkInput, previous: AudioChunkDescriptor?) async throws -> StoredAudioWindow {
        try beginOperation()
        defer { endOperation() }
        try validateInput(input, previous: previous)
        let mutation = try await AudioChunkMediaReaders.shared.acquireMutation(rootKey)
        do {
            try checkOpen()
            let result = try await persist(input, previous: previous)
            await AudioChunkMediaReaders.shared.releaseMutation(mutation)
            return result
        } catch {
            await AudioChunkMediaReaders.shared.releaseMutation(mutation)
            throw error
        }
    }

    public func readWindow(_ window: StoredAudioWindow) async throws -> AudioWindowReadLease {
        try beginOperation()
        defer { endOperation() }
        try validate(window)
        let keys = readKeys(window)
        let registration = try await AudioChunkMediaReaders.shared.beginRead(owner: ownerID, keys: keys)
        do {
            try checkOpen()
            try verifyManifest(window)
            var pcm = Data(capacity: Int(window.manifest.frameCount) * 2)
            for range in window.manifest.ranges {
                try checkOpen()
                guard registration.validity.isValid else { throw CancellationError() }
                try rejectDeletion(streamID: range.chunk.streamID, id: range.chunk.id, kind: .chunk)
                let decoded = try decodeVerified(range.chunk)
                let first = Int(range.offsetFrames) * 2
                let end = first + Int(range.frameCount) * 2
                guard first >= 0, end <= decoded.count, end > first else {
                    throw AudioChunkMediaStorageError.integrityFailure
                }
                pcm.append(decoded[first..<end])
            }
            try verifyManifest(window)
            try checkOpen()
            guard registration.validity.isValid, pcm.count == Int(window.manifest.frameCount) * 2 else {
                throw CancellationError()
            }
            let lease = AudioWindowReadLease(id: registration.id, window: window,
                pcmData: pcm, validity: registration.validity)
            leases[lease.id] = lease
            return lease
        } catch {
            await AudioChunkMediaReaders.shared.endRead(registration.id, owner: ownerID)
            throw error
        }
    }

    public func release(_ lease: AudioWindowReadLease) async {
        guard let owned = leases[lease.id], owned.validity === lease.validity,
              owned.window == lease.window else { return }
        leases.removeValue(forKey: lease.id)
        releasing += 1
        owned.validity.revoke()
        await AudioChunkMediaReaders.shared.endRead(lease.id, owner: ownerID)
        releasing -= 1
        signalClose()
    }

    public func pendingWindows(limit: Int) async throws -> [StoredAudioWindow] {
        try beginOperation()
        defer { endOperation() }
        guard (1...64).contains(limit) else { throw AudioChunkMediaStorageError.invalidInput }
        let mutation = try await AudioChunkMediaReaders.shared.acquireMutation(rootKey)
        do {
            try checkOpen()
            var result: [StoredAudioWindow] = []
            let base = try safeURL("audio/chunk-media/pending")
            if FileManager.default.fileExists(atPath: base.path) {
                guard let enumerator = FileManager.default.enumerator(at: base,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]) else { throw AudioChunkMediaStorageError.unavailable }
                var inspected = 0
                // The caller requests bounded recovery pages. Journals are removed
                // only after canonical database acknowledgement, so a later call
                // resumes from the remaining files without an in-memory backlog.
                while let url = enumerator.nextObject() as? URL, result.count < limit {
                    try checkOpen()
                    inspected += 1
                    guard inspected <= 512 else { break }
                    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                    guard values.isSymbolicLink != true else { throw AudioChunkMediaStorageError.integrityFailure }
                    guard values.isRegularFile == true,
                          url.lastPathComponent.hasPrefix("publish_"), url.pathExtension == "json" else { continue }
                    let journal = try loadJournal(url)
                    guard journal.storeID == storeID else { throw AudioChunkMediaStorageError.integrityFailure }
                    let expected = try journalURL(streamID: journal.streamID, id: journal.id)
                    guard expected == url.standardizedFileURL else { throw AudioChunkMediaStorageError.integrityFailure }
                    if try isDeleted(streamID: journal.streamID, id: journal.id, kind: .window) {
                        try removeFile(url)
                        continue
                    }
                    result.append(try await persist(journal.input, previous: journal.previous))
                }
            }
            await AudioChunkMediaReaders.shared.releaseMutation(mutation)
            return result
        } catch {
            await AudioChunkMediaReaders.shared.releaseMutation(mutation)
            throw error
        }
    }

    public func acknowledgePublished(_ window: StoredAudioWindow) async throws {
        try beginOperation()
        defer { endOperation() }
        try validate(window)
        let mutation = try await AudioChunkMediaReaders.shared.acquireMutation(rootKey)
        do {
            try checkOpen()
            try verifyManifest(window)
            let journalPath = try journalURL(streamID: window.manifest.streamID, id: window.manifest.id)
            if FileManager.default.fileExists(atPath: journalPath.path) {
                let journal = try loadJournal(journalPath)
                try verifyPlan(journal.input, previous: journal.previous, window: window)
                for range in window.manifest.ranges { _ = try decodeVerified(range.chunk) }
                try removeFile(journalPath)
            }
            await AudioChunkMediaReaders.shared.releaseMutation(mutation)
        } catch {
            await AudioChunkMediaReaders.shared.releaseMutation(mutation)
            throw error
        }
    }

    public func deleteAuthorized(windows: [StoredAudioWindow], chunks: [AudioChunkDescriptor]) async throws {
        try beginOperation()
        defer { endOperation() }
        guard windows.count <= 64, chunks.count <= 128, !windows.isEmpty || !chunks.isEmpty else {
            throw AudioChunkMediaStorageError.invalidInput
        }
        for window in windows { try validate(window) }
        for chunk in chunks { try validate(chunk) }
        let mutation = try await AudioChunkMediaReaders.shared.acquireMutation(rootKey)
        do {
            try checkOpen()
            // Durable fences precede revocation and physical deletion. Restart
            // never resumes a publication journal for an explicitly deleted ID.
            for window in windows {
                try writeDeletion(streamID: window.manifest.streamID, id: window.manifest.id, kind: .window)
            }
            for chunk in chunks { try writeDeletion(streamID: chunk.streamID, id: chunk.id, kind: .chunk) }
            let keys = Set(windows.map { windowKey($0.manifest) } + chunks.map(chunkKey))
            await AudioChunkMediaReaders.shared.revokeAndJoin(keys: keys)
            try checkOpen()
            for window in windows {
                try removeFile(try safeURL(window.relativePath))
                try removeFile(try journalURL(streamID: window.manifest.streamID, id: window.manifest.id))
            }
            for chunk in chunks {
                let url = try safeURL(chunk.relativePath)
                if FileManager.default.fileExists(atPath: url.path) {
                    let bytes = try readRegular(url, maximum: Self.maximumEncodedBytes)
                    guard Int64(bytes.count) == chunk.encodedBytes, Self.sha(bytes) == chunk.encodedSHA256 else {
                        throw AudioChunkMediaStorageError.integrityFailure
                    }
                    try removeFile(url)
                }
                try removeFile(try receiptURL(streamID: chunk.streamID, id: chunk.id))
            }
            await AudioChunkMediaReaders.shared.finishRemoval(keys: keys)
            await AudioChunkMediaReaders.shared.releaseMutation(mutation)
        } catch {
            let keys = Set(windows.map { windowKey($0.manifest) } + chunks.map(chunkKey))
            await AudioChunkMediaReaders.shared.finishRemoval(keys: keys)
            await AudioChunkMediaReaders.shared.releaseMutation(mutation)
            throw error
        }
    }

    public func close() async {
        closed = true
        for lease in leases.values { lease.validity.revoke() }
        await AudioChunkMediaReaders.shared.revokeOwner(ownerID)
        if operations > 0 || releasing > 0 || !leases.isEmpty { await withCheckedContinuation { closeWaiters.append($0) } }
    }

    // MARK: Durable publication

    private struct Journal: Codable, Equatable {
        let version: Int
        let storeID: UUID
        let id: UUID
        let streamID: UUID
        let source: AudioSource
        let origin: Date
        let startFrame: Int64
        let pcmData: Data
        let previous: AudioChunkDescriptor?
        var input: AudioChunkInput {
            AudioChunkInput(id: id, streamID: streamID, source: source,
                origin: origin, startFrame: startFrame, pcmData: pcmData)
        }
        init(storeID: UUID, input: AudioChunkInput, previous: AudioChunkDescriptor?) {
            version = 1; self.storeID = storeID; id = input.id; streamID = input.streamID
            source = input.source; origin = input.origin; startFrame = input.startFrame
            pcmData = input.pcmData; self.previous = previous
        }
    }

    private func persist(_ input: AudioChunkInput, previous: AudioChunkDescriptor?) async throws -> StoredAudioWindow {
        try validateInput(input, previous: previous)
        try rejectDeletion(streamID: input.streamID, id: input.id, kind: .window)
        try rejectDeletion(streamID: input.streamID, id: input.id, kind: .chunk)
        let manifestPath = windowPath(streamID: input.streamID, id: input.id)
        let manifestURL = try safeURL(manifestPath)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let existing = try loadWindow(manifestURL, relativePath: manifestPath)
            try verifyPlan(input, previous: previous, window: existing)
            for range in existing.manifest.ranges { _ = try decodeVerified(range.chunk) }
            return existing
        }
        try createStreamDirectory(input.streamID)
        let journal = Journal(storeID: storeID, input: input, previous: previous)
        let journalPath = try journalURL(streamID: input.streamID, id: input.id)
        let journalData = try Self.encode(journal)
        guard journalData.count <= Self.maximumJournalBytes else { throw AudioChunkMediaStorageError.invalidInput }
        if FileManager.default.fileExists(atPath: journalPath.path) {
            guard try loadJournal(journalPath) == journal else { throw AudioChunkMediaStorageError.conflictingIdentity }
        } else { try writeImmutable(journalData, to: journalPath) }
        try checkOpen()
        // The newly captured PCM is durable before a damaged/unavailable
        // predecessor can make context validation fail.
        if let previous { _ = try decodeVerified(previous) }
        let receiptPath = try receiptURL(streamID: input.streamID, id: input.id)
        let chunk: AudioChunkDescriptor
        if FileManager.default.fileExists(atPath: receiptPath.path) {
            chunk = try JSONDecoder().decode(AudioChunkDescriptor.self,
                from: readRegular(receiptPath, maximum: Self.maximumManifestBytes))
            try validate(chunk)
            guard matches(input, chunk: chunk) else { throw AudioChunkMediaStorageError.conflictingIdentity }
            try finalizeEncodedChunk(chunk)
            _ = try decodeVerified(chunk)
        } else {
            chunk = try await encodeChunk(input)
            try checkOpen()
        }
        let context = previous.map { min($0.frameCount, AudioWindowManifest.maximumContextFrames) } ?? 0
        var ranges: [AudioChunkRange] = []
        if let previous, context > 0 {
            ranges.append(AudioChunkRange(chunk: previous, offsetFrames: previous.frameCount - context, frameCount: context))
        }
        ranges.append(AudioChunkRange(chunk: chunk, offsetFrames: 0, frameCount: chunk.frameCount))
        let manifest = AudioWindowManifest(storeID: storeID, id: input.id, streamID: input.streamID,
            source: input.source, origin: input.origin, startFrame: input.startFrame - context,
            frameCount: chunk.frameCount + context, ownedStartFrame: context, ranges: ranges)
        let data = try AudioChunkMediaValidation.encodedManifestData(manifest)
        let result = StoredAudioWindow(manifest: manifest, relativePath: manifestPath,
            manifestSHA256: Self.sha(data), manifestBytes: Int64(data.count))
        try validate(result)
        try checkOpen()
        try writeImmutable(data, to: manifestURL)
        return result
    }

    private func verifyPlan(_ input: AudioChunkInput, previous: AudioChunkDescriptor?, window: StoredAudioWindow) throws {
        try validate(window)
        guard let current = window.manifest.ranges.last?.chunk, matches(input, chunk: current),
              window.manifest.id == input.id, window.manifest.streamID == input.streamID,
              window.manifest.source == input.source, window.manifest.origin == input.origin else {
            throw AudioChunkMediaStorageError.conflictingIdentity
        }
        let context = previous.map { min($0.frameCount, AudioWindowManifest.maximumContextFrames) } ?? 0
        guard window.manifest.ownedStartFrame == context,
              (previous == nil && window.manifest.ranges.count == 1) ||
              (window.manifest.ranges.count == 2 && window.manifest.ranges.first?.chunk == previous) else {
            throw AudioChunkMediaStorageError.conflictingIdentity
        }
    }

    private func matches(_ input: AudioChunkInput, chunk: AudioChunkDescriptor) -> Bool {
        chunk.storeID == storeID && chunk.id == input.id && chunk.streamID == input.streamID &&
        chunk.source == input.source && chunk.origin == input.origin && chunk.startFrame == input.startFrame &&
        chunk.frameCount == input.pcmData.count / 2 && chunk.originalPCMSHA256 == Self.sha(input.pcmData)
    }

    private func loadJournal(_ url: URL) throws -> Journal {
        let journal = try JSONDecoder().decode(Journal.self, from: readRegular(url, maximum: Self.maximumJournalBytes))
        guard journal.version == 1, journal.storeID == storeID else { throw AudioChunkMediaStorageError.integrityFailure }
        try validateInput(journal.input, previous: journal.previous)
        return journal
    }

    // MARK: Native AAC timing and bounded decoding

    private func encodeChunk(_ input: AudioChunkInput) async throws -> AudioChunkDescriptor {
        let relativePath = chunkPath(streamID: input.streamID, id: input.id)
        let destination = try safeURL(relativePath)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AudioChunkMediaStorageError.conflictingIdentity
        }
        let url = try encodingURL(streamID: input.streamID, id: input.id)
        // An unreceipted encoder attempt is not an immutable recording. Its
        // complete raw journal remains the retry source until native verification.
        try removeFile(url)
        try Self.encodePCM(input.pcmData, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try OriginalSpoolFiles.synchronizeFileAndParent(url)
        let encoded = try readRegular(url, maximum: Self.maximumEncodedBytes)
        let timing = try Self.packetTiming(url)
        let count = Int64(input.pcmData.count / 2)
        guard timing.valid == count else { throw AudioChunkMediaStorageError.integrityFailure }
        let decoded = try Self.decodePCM(url, frameCount: count)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first else { throw AudioChunkMediaStorageError.integrityFailure }
        let time = try await track.load(.timeRange)
        try checkOpen()
        guard time.start.isNumeric, time.duration.isNumeric,
              abs(time.start.seconds) <= 0.5 / 16_000,
              abs(time.duration.seconds - Double(count) / 16_000) <= 0.5 / 16_000,
              try readRegular(url, maximum: Self.maximumEncodedBytes) == encoded else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        let chunk = AudioChunkDescriptor(storeID: storeID, id: input.id, streamID: input.streamID,
            source: input.source, origin: input.origin, startFrame: input.startFrame,
            frameCount: count, relativePath: relativePath, encodedBytes: Int64(encoded.count),
            encodedSHA256: Self.sha(encoded), originalPCMSHA256: Self.sha(input.pcmData),
            decodedPCMSHA256: Self.sha(decoded), validFrames: timing.valid,
            primingFrames: timing.priming, remainderFrames: timing.remainder,
            packetCount: timing.packets, framesPerPacket: timing.framesPerPacket,
            trackStartSeconds: time.start.seconds, decodeContract: .nativeAACPCM16V1)
        try validate(chunk)
        try writeImmutable(Self.encode(chunk), to: receiptURL(streamID: input.streamID, id: input.id))
        try finalizeEncodedChunk(chunk)
        return chunk
    }

    private func finalizeEncodedChunk(_ chunk: AudioChunkDescriptor) throws {
        let finalURL = try safeURL(chunk.relativePath)
        let stagedURL = try encodingURL(streamID: chunk.streamID, id: chunk.id)
        if !FileManager.default.fileExists(atPath: finalURL.path) {
            let staged = try readRegular(stagedURL, maximum: Self.maximumEncodedBytes)
            guard Int64(staged.count) == chunk.encodedBytes, Self.sha(staged) == chunk.encodedSHA256 else {
                throw AudioChunkMediaStorageError.integrityFailure
            }
            try installImmutable(stagedURL, at: finalURL)
        } else if FileManager.default.fileExists(atPath: stagedURL.path) {
            let staged = try readRegular(stagedURL, maximum: Self.maximumEncodedBytes)
            let published = try readRegular(finalURL, maximum: Self.maximumEncodedBytes)
            guard staged == published, Self.sha(published) == chunk.encodedSHA256 else {
                throw AudioChunkMediaStorageError.integrityFailure
            }
            try removeFile(stagedURL)
        }
    }

    private func decodeVerified(_ chunk: AudioChunkDescriptor) throws -> Data {
        try validate(chunk)
        try rejectDeletion(streamID: chunk.streamID, id: chunk.id, kind: .chunk)
        let url = try safeURL(chunk.relativePath)
        let identity = try fileIdentity(url)
        let encoded = try readRegular(url, maximum: Self.maximumEncodedBytes)
        guard Int64(encoded.count) == chunk.encodedBytes, Self.sha(encoded) == chunk.encodedSHA256 else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        let timing = try Self.packetTiming(url)
        guard timing.valid == chunk.validFrames, timing.priming == chunk.primingFrames,
              timing.remainder == chunk.remainderFrames, timing.packets == chunk.packetCount,
              timing.framesPerPacket == chunk.framesPerPacket else { throw AudioChunkMediaStorageError.integrityFailure }
        let pcm = try Self.decodePCM(url, frameCount: chunk.frameCount)
        // The versioned native AAC contract binds encoded identity and exact
        // sample geometry. Its PCM hash is the initial verification diagnostic:
        // native Float32 decoding can vary in final bits on reopening the same
        // AAC. A missing contract retains the pretrial strict-hash behavior.
        if chunk.decodeContract == nil, Self.sha(pcm) != chunk.decodedPCMSHA256 {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        guard try fileIdentity(url) == identity,
              try readRegular(url, maximum: Self.maximumEncodedBytes) == encoded else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        return pcm
    }

    private static func encodePCM(_ pcm: Data, to url: URL) throws {
        let count = pcm.count / 2
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let destination = buffer.floatChannelData?[0] else { throw AudioChunkMediaStorageError.integrityFailure }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { bytes in
            for index in 0..<count {
                destination[index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
            }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        // Leaving this synchronous scope closes AVAudioFile and writes native
        // packet priming/remainder metadata before any receipt can be admitted.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private static func decodePCM(_ url: URL, frameCount: Int64) throws -> Data {
        guard (1...AudioWindowManifest.maximumChunkFrames).contains(frameCount) else {
            throw AudioChunkMediaStorageError.invalidInput
        }
        // Read bounded finite native Float32, then apply explicit PCM16
        // quantization. Native Float32 itself can vary in its final bits;
        // quantization does not claim cross-read or cross-OS bit stability.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length == frameCount, format.sampleRate == 16_000, format.channelCount == 1,
              format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        var result = Data(capacity: Int(frameCount) * 2)
        var remaining = frameCount
        while remaining > 0 {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 4_096)))
            guard buffer.frameLength > 0, Int64(buffer.frameLength) <= remaining,
                  let samples = buffer.floatChannelData?[0] else { throw AudioChunkMediaStorageError.integrityFailure }
            for index in 0..<Int(buffer.frameLength) {
                let sample = samples[index]
                guard sample.isFinite else { throw AudioChunkMediaStorageError.integrityFailure }
                let scaled = (Double(sample) * 32_768).rounded(.toNearestOrAwayFromZero)
                var quantized = Int16(max(-32_768, min(32_767, scaled))).littleEndian
                withUnsafeBytes(of: &quantized) { result.append(contentsOf: $0) }
            }
            remaining -= Int64(buffer.frameLength)
        }
        // AVAudioFile throws a bridged `nilError` when asked to read beyond its
        // exact valid-frame endpoint on macOS 26. Packet-table arithmetic and
        // file.length already bind that endpoint; require the completed native
        // cursor and byte count instead of making an invalid extra read.
        guard file.framePosition == frameCount, result.count == Int(frameCount) * 2 else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        return result
    }

    private struct PacketTiming {
        let valid: Int64, priming: Int64, remainder: Int64, packets: Int64, framesPerPacket: Int64
    }

    private static func packetTiming(_ url: URL) throws -> PacketTiming {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        defer { AudioFileClose(file) }
        var table = AudioFilePacketTableInfo()
        var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr,
              format.mFormatID == kAudioFormatMPEG4AAC, format.mSampleRate == 16_000,
              format.mChannelsPerFrame == 1, format.mFramesPerPacket > 0 else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        var packets: UInt64 = 0
        size = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &packets) == noErr,
              packets > 0, packets <= 1_024, table.mNumberValidFrames > 0,
              table.mPrimingFrames >= 0, table.mRemainderFrames >= 0 else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        let timing = PacketTiming(valid: table.mNumberValidFrames, priming: Int64(table.mPrimingFrames),
            remainder: Int64(table.mRemainderFrames), packets: Int64(packets), framesPerPacket: Int64(format.mFramesPerPacket))
        guard timing.valid <= AudioWindowManifest.maximumChunkFrames,
              timing.packets * timing.framesPerPacket == timing.valid + timing.priming + timing.remainder else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        return timing
    }

    // MARK: Validation and files

    private func validateInput(_ input: AudioChunkInput, previous: AudioChunkDescriptor?) throws {
        let frames = Int64(input.pcmData.count / 2)
        guard input.source != .unknown,
              input.pcmData.count.isMultiple(of: 2), (1...AudioWindowManifest.maximumChunkFrames).contains(frames),
              input.origin.timeIntervalSince1970.isFinite, input.origin.timeIntervalSince1970 >= 0,
              input.origin.timeIntervalSince1970 < 32_503_680_000,
              input.startFrame >= 0, input.startFrame <= 1 << 48,
              !input.startFrame.addingReportingOverflow(frames).overflow else { throw AudioChunkMediaStorageError.invalidInput }
        if let previous {
            try validate(previous)
            guard previous.streamID == input.streamID, previous.source == input.source, previous.origin == input.origin,
                  previous.id != input.id, previous.startFrame + previous.frameCount == input.startFrame else {
                throw AudioChunkMediaStorageError.invalidInput
            }
        } else if input.startFrame != 0 { throw AudioChunkMediaStorageError.invalidInput }
    }

    private func validate(_ chunk: AudioChunkDescriptor) throws {
        try AudioChunkMediaValidation.validate(chunk)
        guard chunk.storeID == storeID else { throw AudioChunkMediaStorageError.integrityFailure }
    }
    private func validate(_ window: StoredAudioWindow) throws {
        try AudioChunkMediaValidation.validate(window)
        guard window.manifest.storeID == storeID else { throw AudioChunkMediaStorageError.integrityFailure }
    }
    private func verifyManifest(_ window: StoredAudioWindow) throws {
        try validate(window)
        try rejectDeletion(streamID: window.manifest.streamID, id: window.manifest.id, kind: .window)
        let loaded = try loadWindow(safeURL(window.relativePath), relativePath: window.relativePath)
        guard loaded == window else { throw AudioChunkMediaStorageError.integrityFailure }
    }
    private func loadWindow(_ url: URL, relativePath: String) throws -> StoredAudioWindow {
        let data = try readRegular(url, maximum: Self.maximumManifestBytes)
        let manifest = try JSONDecoder().decode(AudioWindowManifest.self, from: data)
        let window = StoredAudioWindow(manifest: manifest, relativePath: relativePath,
            manifestSHA256: Self.sha(data), manifestBytes: Int64(data.count))
        try validate(window)
        guard try AudioChunkMediaValidation.encodedManifestData(manifest) == data else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        return window
    }
    private func safeURL(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components[0] == "audio", components[1] == "chunk-media",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        let expected = storageRoot.appendingPathComponent(path).standardizedFileURL
        guard expected.path.hasPrefix(storageRoot.path + "/"),
              expected.resolvingSymlinksInPath().standardizedFileURL == expected else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        return expected
    }
    private func createStreamDirectory(_ stream: UUID) throws {
        let path = "audio/chunk-media/\(stream.uuidString.lowercased())"
        let url = try safeURL(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let pending = try safeURL("audio/chunk-media/pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        _ = try safeURL(path)
        try OriginalSpoolFiles.synchronizeDirectory(url)
        try OriginalSpoolFiles.synchronizeDirectory(pending)
        try OriginalSpoolFiles.synchronizeDirectory(url.deletingLastPathComponent())
        try OriginalSpoolFiles.synchronizeDirectory(url.deletingLastPathComponent().deletingLastPathComponent())
        try OriginalSpoolFiles.synchronizeDirectory(storageRoot)
    }
    private func chunkPath(streamID: UUID, id: UUID) -> String {
        AudioChunkMediaValidation.chunkPath(streamID: streamID, id: id)
    }
    private func windowPath(streamID: UUID, id: UUID) -> String {
        AudioChunkMediaValidation.windowPath(streamID: streamID, id: id)
    }
    private func journalURL(streamID: UUID, id: UUID) throws -> URL {
        try safeURL("audio/chunk-media/pending/publish_\(streamID.uuidString.lowercased())_\(id.uuidString.lowercased()).json")
    }
    private func receiptURL(streamID: UUID, id: UUID) throws -> URL {
        try safeURL("audio/chunk-media/\(streamID.uuidString.lowercased())/chunk_\(id.uuidString.lowercased()).json")
    }
    private func encodingURL(streamID: UUID, id: UUID) throws -> URL {
        try safeURL("audio/chunk-media/\(streamID.uuidString.lowercased())/.encoding_\(id.uuidString.lowercased()).m4a")
    }
    private func readRegular(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= maximum else { throw AudioChunkMediaStorageError.integrityFailure }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AudioChunkMediaStorageError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximum + 1), data.count == size.intValue else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        return data
    }
    private struct FileIdentity: Equatable { let device: UInt64, inode: UInt64, size: UInt64, modified: Date }
    private func fileIdentity(_ url: URL) throws -> FileIdentity {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value, size: size.uint64Value, modified: modified)
    }
    private func writeImmutable(_ data: Data, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try readRegular(destination, maximum: max(data.count, 1)) == data else {
                throw AudioChunkMediaStorageError.conflictingIdentity
            }
            return
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".writing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AudioChunkMediaStorageError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try installImmutable(temporary, at: destination)
    }
    private func installImmutable(_ temporary: URL, at destination: URL) throws {
        // link publishes a complete inode atomically without replacing an
        // existing immutable target; rename would overwrite a conflicting file.
        guard link(temporary.path, destination.path) == 0 else { throw AudioChunkMediaStorageError.conflictingIdentity }
        guard unlink(temporary.path) == 0 else { throw AudioChunkMediaStorageError.unavailable }
        try OriginalSpoolFiles.synchronizeDirectory(destination.deletingLastPathComponent())
    }
    private func removeFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard (try FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        try FileManager.default.removeItem(at: url)
        try OriginalSpoolFiles.synchronizeDirectory(url.deletingLastPathComponent())
    }
    private enum DeletionKind: String, Codable { case window, chunk }
    private struct Deletion: Codable, Equatable { let storeID: UUID, streamID: UUID, id: UUID; let kind: DeletionKind }
    private func deletionURL(streamID: UUID, id: UUID, kind: DeletionKind) throws -> URL {
        try safeURL("audio/chunk-media/\(streamID.uuidString.lowercased())/deleted_\(kind.rawValue)_\(id.uuidString.lowercased()).json")
    }
    private func isDeleted(streamID: UUID, id: UUID, kind: DeletionKind) throws -> Bool {
        let url = try deletionURL(streamID: streamID, id: id, kind: kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let value = try JSONDecoder().decode(Deletion.self, from: readRegular(url, maximum: 1_024))
        guard value == Deletion(storeID: storeID, streamID: streamID, id: id, kind: kind) else {
            throw AudioChunkMediaStorageError.integrityFailure
        }
        return true
    }
    private func rejectDeletion(streamID: UUID, id: UUID, kind: DeletionKind) throws {
        guard try !isDeleted(streamID: streamID, id: id, kind: kind) else { throw AudioChunkMediaStorageError.unavailable }
    }
    private func writeDeletion(streamID: UUID, id: UUID, kind: DeletionKind) throws {
        try createStreamDirectory(streamID)
        try writeImmutable(Self.encode(Deletion(storeID: storeID, streamID: streamID, id: id, kind: kind)),
            to: deletionURL(streamID: streamID, id: id, kind: kind))
    }
    private func chunkKey(_ chunk: AudioChunkDescriptor) -> String { rootKey + ":chunk:" + chunk.id.uuidString }
    private func windowKey(_ window: AudioWindowManifest) -> String { rootKey + ":window:" + window.id.uuidString }
    private func readKeys(_ window: StoredAudioWindow) -> Set<String> {
        Set([windowKey(window.manifest)] + window.manifest.ranges.map { chunkKey($0.chunk) })
    }
    private func beginOperation() throws { try checkOpen(); operations += 1 }
    private func endOperation() {
        operations -= 1
        signalClose()
    }
    private func signalClose() {
        if operations == 0 && releasing == 0 && leases.isEmpty {
            let waiters = closeWaiters; closeWaiters.removeAll(); waiters.forEach { $0.resume() }
        }
    }
    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw AudioChunkMediaStorageError.closed }
    }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// Process-wide lifetime ownership is shared by separate writer/playback store
/// instances. Fences remain for the process lifetime; on restart disk tombstones
/// provide the same refusal before any media can be decoded.
private actor AudioChunkMediaReaders {
    static let shared = AudioChunkMediaReaders()
    struct Registration { let id: UUID; let validity: AudioMediaLeaseValidity }
    struct Mutation { let id: UUID; let root: String }
    private struct Reader { let owner: UUID; let keys: Set<String>; let validity: AudioMediaLeaseValidity }
    private struct RemovalWaiter { let keys: Set<String>; let continuation: CheckedContinuation<Void, Never> }
    private struct MutationWaiter { let id: UUID; let continuation: CheckedContinuation<Mutation, Error> }
    private var readers: [UUID: Reader] = [:]
    private var fences: Set<String> = []
    private var removals: [RemovalWaiter] = []
    private var mutations: [String: UUID] = [:]
    private var mutationWaiters: [String: [MutationWaiter]] = [:]

    func beginRead(owner: UUID, keys: Set<String>) throws -> Registration {
        try Task.checkCancellation()
        guard keys.isDisjoint(with: fences) else { throw AudioChunkMediaStorageError.unavailable }
        guard readers.count < 128 else { throw AudioChunkMediaStorageError.queueFull }
        let registration = Registration(id: UUID(), validity: AudioMediaLeaseValidity())
        readers[registration.id] = Reader(owner: owner, keys: keys, validity: registration.validity)
        return registration
    }
    func endRead(_ id: UUID, owner: UUID) {
        guard readers[id]?.owner == owner else { return }
        readers.removeValue(forKey: id)?.validity.revoke()
        resumeRemovals()
    }
    func revokeOwner(_ owner: UUID) {
        for reader in readers.values where reader.owner == owner { reader.validity.revoke() }
    }
    func revokeAndJoin(keys: Set<String>) async {
        fences.formUnion(keys)
        for reader in readers.values where !reader.keys.isDisjoint(with: keys) { reader.validity.revoke() }
        if readers.values.contains(where: { !$0.keys.isDisjoint(with: keys) }) {
            await withCheckedContinuation { removals.append(RemovalWaiter(keys: keys, continuation: $0)) }
        }
    }
    func finishRemoval(keys: Set<String>) { fences.subtract(keys) }
    private func resumeRemovals() {
        var waiting: [RemovalWaiter] = []
        for removal in removals {
            if readers.values.contains(where: { !$0.keys.isDisjoint(with: removal.keys) }) { waiting.append(removal) }
            else { removal.continuation.resume() }
        }
        removals = waiting
    }
    func acquireMutation(_ root: String) async throws -> Mutation {
        try Task.checkCancellation()
        let id = UUID()
        guard mutations[root] != nil else { mutations[root] = id; return Mutation(id: id, root: root) }
        guard mutationWaiters[root, default: []].count < 64 else { throw AudioChunkMediaStorageError.queueFull }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { mutationWaiters[root, default: []].append(MutationWaiter(id: id, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancelMutationWaiter(root: root, id: id) } }
    }
    private func cancelMutationWaiter(root: String, id: UUID) {
        guard let index = mutationWaiters[root]?.firstIndex(where: { $0.id == id }) else { return }
        mutationWaiters[root]?.remove(at: index).continuation.resume(throwing: CancellationError())
        if mutationWaiters[root]?.isEmpty == true { mutationWaiters.removeValue(forKey: root) }
    }
    func releaseMutation(_ mutation: Mutation) {
        guard mutations[mutation.root] == mutation.id else { return }
        if var pending = mutationWaiters[mutation.root], !pending.isEmpty {
            let next = pending.removeFirst()
            mutationWaiters[mutation.root] = pending.isEmpty ? nil : pending
            mutations[mutation.root] = next.id
            next.continuation.resume(returning: Mutation(id: next.id, root: mutation.root))
        } else { mutations.removeValue(forKey: mutation.root) }
    }
}
