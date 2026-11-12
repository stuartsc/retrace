import Foundation
import Shared

/// Read adapters over the same owners used by native UI. No read starts a model,
/// companion transport, optional store or filesystem scan.
public enum RetraceOperationsService {
    public static func handlers(coordinator: AppCoordinator) -> [RetraceCommandHandler] {
        [
            .init(operation: .health) { context in
                try context.requireKeys([])
                return try .encode(await coordinator.operationsSnapshot(recordRead: true))
            },
            .init(operation: .backlog) { context in
                try context.requireKeys([])
                return try .encode(await coordinator.operationsSnapshot(recordRead: true))
            },
            .init(operation: .usage) { context in
                try context.requireKeys([])
                return try .encode(await coordinator.resourceUsageSnapshot())
            },
            .init(operation: .storage) { context in
                try context.requireKeys([])
                let snapshot = await coordinator.storageUsageSnapshot()
                return .object(["observedAt": .number(Date().timeIntervalSince1970 * 1_000),
                    "liveLaptop": .bool(true), "isScanning": .bool(snapshot.isScanning), "isClosed": .bool(snapshot.isClosed),
                    "latestReport": try snapshot.latestReport.map(RetraceJSON.encode) ?? .null,
                    "lastCompleteReport": try snapshot.lastCompleteReport.map(RetraceJSON.encode) ?? .null])
            }
        ]
    }
}
