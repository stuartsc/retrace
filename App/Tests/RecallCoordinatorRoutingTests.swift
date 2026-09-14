import XCTest
import Foundation
import Shared
import Database
import Storage
@testable import App

final class RecallCoordinatorRoutingTests: XCTestCase {
    func testUnavailableUnifiedSourceDoesNotSubstituteNativeFallbackEvidence() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("RecallRouting-\(UUID())")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let services = ServiceContainer(databasePath: rootURL.appendingPathComponent("test.db").path,
            storageConfig: StorageConfig(storageRootPath: rootURL.path))
        let database = await services.database
        try await database.initialize()
        let fts = await services.ftsEngine
        try await fts.initialize()
        let search = await services.search
        try await search.initialize(config: SearchConfig())
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = try await database.insertSegment(bundleID: "com.test.recall", startDate: date, endDate: date,
            windowName: "Cedar", browserUrl: nil, type: 0)
        let id = FrameID(value: try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: date,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: .empty)))
        _ = try await database.commitFrameOCR(frameID: id, text: ExtractedText(frameID: id, timestamp: date,
            regions: [TextRegion(frameID: id, text: "cedar", bounds: CGRect(x: 1, y: 1, width: 50, height: 20))]), frameWidth: 100, frameHeight: 100)
        let fallback = try await search.search(text: "cedar", limit: 10)
        XCTAssertEqual(fallback.results.count, 1, "Real fallback evidence exists to expose accidental substitution")
        let root = FileManager.default.temporaryDirectory.path
        let adapter = DataAdapter(retraceConnection: SQLiteConnection(db: await database.getConnection()),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root), database: database)
        try await adapter.initialize()
        await services.installRecallRoutingAdapter(adapter)
        await adapter.shutdown()
        do {
            _ = try await AppCoordinator(services: services).search(query: SearchQuery(text: "cedar"))
            XCTFail("A source failure must be visible; substituting native evidence is not an answer")
        } catch DataAdapterError.notInitialized {
            // Exact source readiness is retained across the integration layer.
        } catch { XCTFail("Source failure was replaced: \(type(of: error))") }
        try await fts.close()
        try await database.close()
    }
}

private extension ServiceContainer {
    func installRecallRoutingAdapter(_ adapter: DataAdapter) { dataAdapter = adapter }
}
