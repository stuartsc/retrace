import Foundation
import Database
import Shared

public enum LocalContextSettings {
    public static let foundationModelsKey = "localContextFoundationModelsEnabled"
}

enum LocalContextIntegration {
    static func record(_ metric: LocalContextMetric, database: DatabaseManager) async {
        guard let data = try? JSONEncoder().encode(metric), let metadata = String(data: data, encoding: .utf8) else { return }
        do { try await database.recordMetricEvent(metricType: .localContext, metadata: metadata) }
        catch { Log.warning("Local context metric could not be recorded", category: .app) }
    }
}
