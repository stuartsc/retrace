import Foundation

/// One disposable, origin-bound last-good response. File I/O and decoding stay
/// off the UI actor; bounded reads also reject corrupt or unexpectedly large files.
actor FuseIntelSnapshotCache {
    static let maximumPayloadBytes = 2 * 1_024 * 1_024
    struct Entry: Sendable {
        let snapshot: FuseIntelSnapshot
        let receivedAt: Date
    }
    private struct Record: Codable {
        let version: Int
        let origin: String
        let receivedAt: Date
        let payload: Data
    }
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("command-v1.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.retrace.app/FuseIntel", isDirectory: true)
    }

    func store(payload: Data, origin: URL, receivedAt: Date) throws {
        _ = try FuseIntelSnapshot.decode(payload)
        guard receivedAt.timeIntervalSince1970.isFinite else { throw FuseIntelClientError.invalidResponse }
        try Task.checkCancellation()
        let bytes = try JSONEncoder().encode(Record(version: 1, origin: Self.key(origin), receivedAt: receivedAt, payload: payload))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func load(origin: URL) throws -> Entry? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // JSON's base64 representation is larger than the bounded response.
        let limit = Self.maximumPayloadBytes * 2
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw FuseIntelClientError.invalidResponse }
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        guard record.version == 1, record.origin == Self.key(origin),
              record.receivedAt.timeIntervalSince1970.isFinite,
              record.receivedAt <= Date().addingTimeInterval(60) else { return nil }
        return .init(snapshot: try FuseIntelSnapshot.decode(record.payload), receivedAt: record.receivedAt)
    }

    private static func key(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
}
