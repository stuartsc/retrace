import Foundation
import Shared

enum RetraceAudioSettingsCommands {
    private struct Update: Decodable {
        let expectedRevision: UUID
        let microphoneEnabled: Bool
        let systemAudioEnabled: Bool
    }

    static func handlers(owner: @escaping @Sendable () async throws -> AudioSessionOwner) -> [RetraceCommandHandler] {
        [
            .init(operation: .audioSettingsRead) { context in
                try context.requireKeys([])
                try await context.authorize()
                let snapshot = try await owner().snapshot()
                try await context.authorize()
                return try .encode(snapshot)
            },
            .init(operation: .audioSettingsUpdate) { context in
                let input: Update = try context.decode(keys: ["expectedRevision", "microphoneEnabled", "systemAudioEnabled"])
                try await context.authorize()
                do {
                    let receipt = try await owner().update(.init(clientID: context.clientID,
                        requestID: context.requestID, expectedRevision: input.expectedRevision,
                        microphoneEnabled: input.microphoneEnabled, systemAudioEnabled: input.systemAudioEnabled),
                        fence: context.mutationFence)
                    return try .encode(receipt)
                } catch AudioSessionError.systemAudioPolicyUnavailable { throw RetraceCommandError.unavailable }
            }
        ]
    }
}
