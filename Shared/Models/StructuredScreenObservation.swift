import CoreGraphics
import Foundation

/// Existing OCR text channels. Chrome is a positional extraction channel, not a semantic role.
public enum EvidenceTextChannel: String, Codable, Sendable { case main, chrome }

/// UTF16 coordinates in the complete main or chrome text channel, never within a fragment.
public struct EvidenceUTF16Range: Codable, Hashable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

public struct EvidenceExtractionProvenance: Codable, Equatable, Sendable {
    /// OCR means the canonical OCR publication path, without claiming a particular engine/version.
    public enum Origin: String, Codable, Sendable { case ocr, unknown, legacyUnknown }
    public let origin: Origin
    /// Nil explicitly means the extractor identity/version was not recorded.
    public let extractorIdentifier: String?
    public let extractorVersion: String?
    public init(origin: Origin, extractorIdentifier: String? = nil, extractorVersion: String? = nil) {
        self.origin = origin; self.extractorIdentifier = extractorIdentifier; self.extractorVersion = extractorVersion
    }
}

/// Foreground capture context does not establish ownership of each visible OCR region.
public enum EvidenceBlockOwnership: String, Codable, Sendable { case unknown }
public enum EvidenceBlockSemanticRole: String, Codable, Sendable { case unknown }

public struct EvidenceTextBlock: Codable, Equatable, Sendable, Identifiable {
    /// Original main-then-chrome ordinal used by ScreenEvidenceRef.blockIDs.
    public let id: Int
    public let channel: EvidenceTextChannel
    public let text: String
    public let utf16Range: EvidenceUTF16Range
    /// Whole-region frame pixels, top-left origin. Nil means geometry is not verified.
    public let bounds: CGRect?
    public let ownership: EvidenceBlockOwnership
    public let semanticRole: EvidenceBlockSemanticRole
}

/// Exact saved channel text whose OCR regions do not provide a coherent representation.
/// It deliberately has no block ordinal, range-to-region mapping, ownership or geometry.
public struct EvidenceUnstructuredText: Codable, Equatable, Sendable {
    public let channel: EvidenceTextChannel
    public let text: String
}

public struct StructuredScreenObservation: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let provenance: EvidenceExtractionProvenance
    public let blocks: [EvidenceTextBlock]
    public let unstructuredText: [EvidenceUnstructuredText]

    public var mainText: String { text(in: .main) }
    public var chromeText: String { text(in: .chrome) }

    private func text(in channel: EvidenceTextChannel) -> String {
        if let fallback = unstructuredText.first(where: { $0.channel == channel }) { return fallback.text }
        return blocks.filter { $0.channel == channel }.map(\.text).joined(separator: " ")
    }

    /// Projects exact stored text. A mismatched channel remains flat; other coherent channels retain their ordinals.
    /// Old payload callers pass legacyUnknown and geometryVerified=false without rewriting their records.
    public static func project(text: ExtractedText?, width: Int, height: Int,
                               provenance: EvidenceExtractionProvenance,
                               geometryVerified: Bool) -> StructuredScreenObservation {
        var blocks: [EvidenceTextBlock] = []
        var fallback: [EvidenceUnstructuredText] = []
        if let text {
            func append(_ channel: EvidenceTextChannel, regions: [TextRegion], flat: String, ordinal: Int) {
                // String equality is canonically equivalent; ranges require identical code units.
                guard flat.utf8.elementsEqual(regions.map(\.text).joined(separator: " ").utf8) else {
                    fallback.append(EvidenceUnstructuredText(channel: channel, text: flat))
                    return
                }
                var location = 0
                for (index, region) in regions.enumerated() {
                    let length = region.text.utf16.count
                    let box = region.bounds
                    let valid = geometryVerified && region.frameID == text.frameID && width > 0 && height > 0
                        && !box.isNull && !box.isInfinite && box.minX.isFinite && box.minY.isFinite
                        && box.width.isFinite && box.height.isFinite && box.width > 0 && box.height > 0
                        && box.minX >= 0 && box.minY >= 0 && box.maxX <= CGFloat(width) && box.maxY <= CGFloat(height)
                    blocks.append(EvidenceTextBlock(id: ordinal + index, channel: channel, text: region.text,
                        utf16Range: .init(location: location, length: length), bounds: valid ? box : nil,
                        ownership: .unknown, semanticRole: .unknown))
                    location += length + 1 // The canonical flat representation inserts one space between regions.
                }
            }
            append(.main, regions: text.regions, flat: text.fullText, ordinal: 0)
            append(.chrome, regions: text.chromeRegions, flat: text.chromeText, ordinal: text.regions.count)
        }
        return StructuredScreenObservation(width: width, height: height, provenance: provenance,
            blocks: blocks, unstructuredText: fallback)
    }
}
