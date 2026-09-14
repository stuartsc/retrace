import CoreGraphics
import Foundation

public enum ScreenEvidenceExpansionError: String, Error, Codable, Sendable { case invalidLimits, invalidContinuation }

/// Opaque position in one immutable extraction and exact block subset. It grants no access on its own.
public struct ScreenEvidenceExpansionCursor: Codable, Equatable, Sendable {
    fileprivate let formatVersion: Int
    fileprivate let reference: ScreenEvidenceRef
    fileprivate let itemIndex: Int
    fileprivate let utf8Offset: Int
}

public struct ScreenEvidenceExpansionRequest: Sendable {
    public let reference: ScreenEvidenceRef
    public let blockLimit: Int
    public let maximumUTF8Bytes: Int
    public let cursor: ScreenEvidenceExpansionCursor?

    /// Text bytes, not token estimates. Four bytes always admit at least one Unicode scalar.
    public init(reference: ScreenEvidenceRef, blockLimit: Int = 64, maximumUTF8Bytes: Int = 65_536,
                cursor: ScreenEvidenceExpansionCursor? = nil) {
        self.reference = reference; self.blockLimit = blockLimit
        self.maximumUTF8Bytes = maximumUTF8Bytes; self.cursor = cursor
    }

    public func validate() throws {
        guard (1...500).contains(blockLimit), (4...262_144).contains(maximumUTF8Bytes) else {
            throw ScreenEvidenceExpansionError.invalidLimits
        }
        if let cursor {
            guard cursor.formatVersion == 1, cursor.reference == reference,
                  cursor.itemIndex >= 0, cursor.utf8Offset >= 0 else {
                throw ScreenEvidenceExpansionError.invalidContinuation
            }
        }
    }
}

public struct ScreenEvidenceFragmentID: Hashable, Codable, Sendable {
    public let reference: ScreenEvidenceRef
    public let channel: EvidenceTextChannel
    public let blockID: Int?
    public let blockUTF8Offset: Int
}

public struct ScreenEvidenceTextFragment: Sendable, Identifiable {
    public let id: ScreenEvidenceFragmentID
    public var blockID: Int? { id.blockID }
    public var channel: EvidenceTextChannel { id.channel }
    public var blockUTF8Offset: Int { id.blockUTF8Offset }
    public let text: String
    /// Complete channel UTF16 coordinates, including the preceding text of a split block.
    public let utf16Range: EvidenceUTF16Range
    /// Whole original OCR region in top-left frame pixels, never a fabricated fragment rectangle.
    public let blockBounds: CGRect?
    public let isLastFragment: Bool
    public let provenance: EvidenceExtractionProvenance
    public let ownership: EvidenceBlockOwnership
    public let semanticRole: EvidenceBlockSemanticRole

    public init(reference: ScreenEvidenceRef, channel: EvidenceTextChannel, blockID: Int?,
                blockUTF8Offset: Int, text: String, utf16Range: EvidenceUTF16Range, blockBounds: CGRect?,
                isLastFragment: Bool, provenance: EvidenceExtractionProvenance) {
        self.id = .init(reference: reference, channel: channel, blockID: blockID, blockUTF8Offset: blockUTF8Offset)
        self.text = text; self.utf16Range = utf16Range; self.blockBounds = blockBounds
        self.isLastFragment = isLastFragment; self.provenance = provenance
        self.ownership = .unknown; self.semanticRole = .unknown
    }
}

public struct ScreenEvidenceExpansionPage: Sendable {
    public let reference: ScreenEvidenceRef
    public let captureTimestamp: Date
    /// Foreground capture context only. It does not assign ownership to individual blocks.
    public let context: FrameMetadata
    public let width: Int
    public let height: Int
    public let provenance: EvidenceExtractionProvenance
    public let fragments: [ScreenEvidenceTextFragment]
    public let nextCursor: ScreenEvidenceExpansionCursor?
    public var textUTF8Bytes: Int { fragments.reduce(0) { $0 + $1.text.utf8.count } }

    public init(reference: ScreenEvidenceRef, captureTimestamp: Date, context: FrameMetadata,
                width: Int, height: Int, provenance: EvidenceExtractionProvenance,
                fragments: [ScreenEvidenceTextFragment], nextCursor: ScreenEvidenceExpansionCursor? = nil) {
        self.reference = reference; self.captureTimestamp = captureTimestamp; self.context = context
        self.width = width; self.height = height; self.provenance = provenance
        self.fragments = fragments; self.nextCursor = nextCursor
    }
}

extension ScreenEvidenceSnapshot {
    /// Pure bounded projection. The caller must validate current source, privacy and deletion state on every page.
    public func expansionPage(for request: ScreenEvidenceExpansionRequest) throws -> ScreenEvidenceExpansionPage {
        try Task.checkCancellation()
        try request.validate()
        // The persistence reader returns the unselected payload; the request supplies its exact subset.
        let expected = ScreenEvidenceRef(storeID: ref.storeID, source: ref.source, observationID: ref.observationID,
            frameID: ref.frameID, extractionRevision: ref.extractionRevision, blockIDs: request.reference.blockIDs)
        guard expected == request.reference else { throw ScreenEvidenceExpansionError.invalidContinuation }
        guard frame.id == ref.frameID, frame.source == ref.source,
              text == nil || text?.frameID == ref.frameID else { throw EvidenceUnavailableReason.integrityFailure }
        let observation = self.observation
        let selected = Set(request.reference.blockIDs)
        guard request.reference.blockIDs.count <= 500, selected.count == request.reference.blockIDs.count,
              selected.isEmpty || (highlightsVerified && selected.isSubset(of: Set(observation.blocks.map(\.id)))) else {
            throw EvidenceUnavailableReason.extractionUnavailable
        }
        var items: [ScreenExpansionItem] = []
        for channel in [EvidenceTextChannel.main, .chrome] {
            if selected.isEmpty, let flat = observation.unstructuredText.first(where: { $0.channel == channel }) {
                items.append(.init(channel: channel, blockID: nil, text: flat.text, channelUTF16Start: 0, bounds: nil))
            } else {
                items += observation.blocks.filter { $0.channel == channel && (selected.isEmpty || selected.contains($0.id)) }
                    .map { .init(channel: channel, blockID: $0.id, text: $0.text,
                        channelUTF16Start: $0.utf16Range.location, bounds: $0.bounds) }
            }
        }
        var index = request.cursor?.itemIndex ?? 0
        var offset = request.cursor?.utf8Offset ?? 0
        if request.cursor != nil, index >= items.count { throw ScreenEvidenceExpansionError.invalidContinuation }
        var fragments: [ScreenEvidenceTextFragment] = []
        var remaining = request.maximumUTF8Bytes
        while index < items.count && fragments.count < request.blockLimit {
            try Task.checkCancellation()
            let item = items[index]
            let bytes = Array(item.text.utf8)
            guard offset <= bytes.count, bytes.isEmpty || offset < bytes.count,
                  offset == bytes.count || bytes[offset] & 0xc0 != 0x80 else {
                throw ScreenEvidenceExpansionError.invalidContinuation
            }
            var end = offset + min(bytes.count - offset, remaining)
            // Scalar boundaries preserve valid UTF8 and make progress even for a grapheme larger than a page.
            while end < bytes.count && end > offset && bytes[end] & 0xc0 == 0x80 { end -= 1 }
            if end == offset && !bytes.isEmpty { break }
            let text = String(decoding: bytes[offset..<end], as: UTF8.self)
            let prefixLength = String(decoding: bytes.prefix(offset), as: UTF8.self).utf16.count
            let last = end == bytes.count
            fragments.append(ScreenEvidenceTextFragment(reference: request.reference, channel: item.channel,
                blockID: item.blockID, blockUTF8Offset: offset, text: text,
                utf16Range: .init(location: item.channelUTF16Start + prefixLength, length: text.utf16.count),
                blockBounds: item.bounds, isLastFragment: last, provenance: observation.provenance))
            remaining -= end - offset
            if last { index += 1; offset = 0 }
            else { offset = end; break }
        }
        let cursor: ScreenEvidenceExpansionCursor?
        if index < items.count {
            guard !fragments.isEmpty else { throw ScreenEvidenceExpansionError.invalidContinuation }
            cursor = .init(formatVersion: 1, reference: request.reference, itemIndex: index, utf8Offset: offset)
        } else { cursor = nil }
        try Task.checkCancellation()
        return ScreenEvidenceExpansionPage(reference: request.reference, captureTimestamp: frame.timestamp,
            context: frame.metadata, width: width, height: height, provenance: observation.provenance,
            fragments: fragments, nextCursor: cursor)
    }
}

private struct ScreenExpansionItem {
    let channel: EvidenceTextChannel
    let blockID: Int?
    let text: String
    let channelUTF16Start: Int
    let bounds: CGRect?
}
