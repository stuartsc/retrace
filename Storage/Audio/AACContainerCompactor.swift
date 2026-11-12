import Foundation

/// Removes padding from the narrow, non-fragmented M4A shape emitted by our
/// native AAC writer. This never decodes, re-encodes or reconstructs sample
/// tables. Unknown shapes are declined, leaving the original file untouched.
enum AACContainerCompactor {
    /// Only called by a writer before publishing a newly encoded file. Existing
    /// recordings and receipts must never be passed here. Atomic replacement
    /// retains the original if staging cannot complete. Unknown profiles are a
    /// no-op. An optional optimisation failure is harmless only when readback
    /// verifies the complete original or complete candidate still exists.
    static func compactNewFile(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 2 * 1_024 * 1_024 else { return }
        let original = try Data(contentsOf: url)
        guard let compacted = compact(original) else { return }
        do {
            try compacted.write(to: url, options: .atomic)
        } catch {
            // Foundation may report an error either before replacement or after
            // publishing it. Do not turn valid saved audio into an orphan merely
            // because a nonessential space optimisation could not complete.
            let retained = try Data(contentsOf: url)
            guard retained == original || retained == compacted else { throw error }
        }
    }

    private struct Box {
        let type: String
        let start: Int
        let size: Int
        let header: Int
        var payload: Int { start + header }
        var end: Int { start + size }
    }

    /// nil means unsupported or no removable padding. All allocations are
    /// bounded by the same two-MiB limit as a ten-second chunk publication.
    static func compact(_ original: Data) -> Data? {
        guard original.startIndex == 0, original.count <= 2 * 1_024 * 1_024,
              let top = boxes(original, start: 0, end: original.count),
              top.count == 4, top.map(\.type) == ["ftyp", "moov", "free", "mdat"] else { return nil }
        let moov = top[1], padding = top[2], media = top[3]
        guard padding.size > 8, original[padding.payload..<padding.end].allSatisfy({ $0 == 0 }),
              let movie = boxes(original, start: moov.payload, end: moov.end),
              movie.map(\.type) == ["mvhd", "trak", "udta"],
              let track = movie.first(where: { $0.type == "trak" }),
              let trackChildren = boxes(original, start: track.payload, end: track.end),
              trackChildren.map(\.type) == ["tkhd", "mdia"],
              let mdia = trackChildren.last,
              let mediaChildren = boxes(original, start: mdia.payload, end: mdia.end),
              mediaChildren.map(\.type) == ["mdhd", "hdlr", "minf"],
              let handler = mediaChildren.first(where: { $0.type == "hdlr" }),
              handler.size >= handler.header + 12,
              original.subdata(in: handler.payload + 8..<handler.payload + 12) == Data("soun".utf8),
              let minf = mediaChildren.last,
              let information = boxes(original, start: minf.payload, end: minf.end),
              information.map(\.type) == ["smhd", "dinf", "stbl"],
              let dinf = information.first(where: { $0.type == "dinf" }),
              hasLocalDataReference(original, dinf),
              let stbl = information.last,
              let tables = boxes(original, start: stbl.payload, end: stbl.end),
              tables.count == 5, Array(tables.prefix(4)).map(\.type) == ["stsd", "stts", "stsc", "stsz"],
              let offsets = tables.last, ["stco", "co64"].contains(offsets.type),
              let descriptions = tables.first, hasSingleAACDescription(original, descriptions),
              let metadata = movie.last, hasInlineMetadata(original, metadata) else { return nil }

        // FullBox version/flags stay zero; each chunk must point into this mdat.
        guard offsets.size >= offsets.header + 8,
              uint(original, offsets.payload, bytes: 4) == 0,
              let count = uint(original, offsets.payload + 4, bytes: 4), count > 0, count <= 1_024 else { return nil }
        let width = offsets.type == "stco" ? 4 : 8
        guard Int(count) * width == offsets.size - offsets.header - 8 else { return nil }
        var result = original
        var previous: UInt64 = 0
        for index in 0..<Int(count) {
            let position = offsets.payload + 8 + index * width
            guard let offset = uint(original, position, bytes: width),
                  offset >= UInt64(media.payload), offset < UInt64(media.end),
                  index == 0 || offset > previous else { return nil }
            previous = offset
            put(offset - UInt64(padding.size), in: &result, at: position, bytes: width)
        }
        result.removeSubrange(padding.start..<padding.end)
        return result
    }

    private static func boxes(_ data: Data, start: Int, end: Int) -> [Box]? {
        guard start >= 0, end >= start, end <= data.count else { return nil }
        var result: [Box] = [], cursor = start
        while cursor < end {
            guard result.count < 64, end - cursor >= 8,
                  let small = uint(data, cursor, bytes: 4), small != 0 else { return nil }
            let header = small == 1 ? 16 : 8
            let size = small == 1 ? uint(data, cursor + 8, bytes: 8) : small
            guard let size, size >= UInt64(header), size <= UInt64(end - cursor),
                  let type = String(data: data.subdata(in: cursor + 4..<cursor + 8), encoding: .ascii) else { return nil }
            result.append(Box(type: type, start: cursor, size: Int(size), header: header))
            cursor += Int(size)
        }
        return result
    }

    private static func hasLocalDataReference(_ data: Data, _ dinf: Box) -> Bool {
        guard let children = boxes(data, start: dinf.payload, end: dinf.end), children.count == 1,
              let dref = children.first, dref.type == "dref", dref.size == dref.header + 20,
              uint(data, dref.payload, bytes: 4) == 0,
              uint(data, dref.payload + 4, bytes: 4) == 1,
              let entries = boxes(data, start: dref.payload + 8, end: dref.end), entries.count == 1,
              let entry = entries.first, entry.type == "url ", entry.size == 12,
              uint(data, entry.payload, bytes: 4) == 1 else { return false }
        return true
    }

    private static func hasSingleAACDescription(_ data: Data, _ stsd: Box) -> Bool {
        guard stsd.size >= stsd.header + 8,
              uint(data, stsd.payload, bytes: 4) == 0, uint(data, stsd.payload + 4, bytes: 4) == 1,
              let entries = boxes(data, start: stsd.payload + 8, end: stsd.end), entries.count == 1,
              let entry = entries.first, entry.type == "mp4a", entry.size >= entry.header + 28,
              uint(data, entry.payload + 6, bytes: 2) == 1 else { return false }
        return true
    }

    private static func hasInlineMetadata(_ data: Data, _ udta: Box) -> Bool {
        guard let children = boxes(data, start: udta.payload, end: udta.end), children.count == 1,
              let meta = children.first, meta.type == "meta", meta.size >= meta.header + 4,
              uint(data, meta.payload, bytes: 4) == 0,
              let metadata = boxes(data, start: meta.payload + 4, end: meta.end),
              metadata.map(\.type) == ["hdlr", "ilst"], let list = metadata.last,
              let values = boxes(data, start: list.payload, end: list.end),
              values.allSatisfy({ $0.type == "----" }) else { return false }
        // This native profile stores the gapless iTunSMPB metadata inline. Do not
        // admit generic item-location/encryption/fragment offset structures.
        return true
    }

    private static func uint(_ data: Data, _ offset: Int, bytes: Int) -> UInt64? {
        guard offset >= 0, bytes <= data.count, offset <= data.count - bytes else { return nil }
        return data[offset..<offset + bytes].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func put(_ value: UInt64, in data: inout Data, at offset: Int, bytes: Int) {
        for byte in 0..<bytes { data[offset + byte] = UInt8(truncatingIfNeeded: value >> ((bytes - byte - 1) * 8)) }
    }
}
