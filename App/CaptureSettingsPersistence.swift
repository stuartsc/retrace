import Foundation
import Shared

/// App-owned settings storage. Tests inject a private suite; constructing private
/// services never writes the installed application's preferences.
public final class CaptureSettingsPersistence: @unchecked Sendable {
    static let key = "nativeCaptureSettingsV1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    public init(defaults: UserDefaults) { self.defaults = defaults }
    static var application: CaptureSettingsPersistence {
        .init(defaults: UserDefaults(suiteName: "io.retrace.app") ?? .standard)
    }

    func load() -> CaptureConfig? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.key), data.count <= 262_144,
              let config = try? JSONDecoder().decode(CaptureConfig.self, from: data),
              (try? Self.validate(config)) != nil else { return nil }
        return config
    }

    func save(_ config: CaptureConfig) throws {
        try Self.validate(config)
        let data = try JSONEncoder().encode(config)
        lock.lock(); defer { lock.unlock() }
        // This single value is authoritative on restart. Legacy keys remain the
        // view bindings, updated only after the capture owner accepts the change.
        defaults.set(data, forKey: Self.key)
        defaults.set(config.captureIntervalSeconds, forKey: "captureIntervalSeconds")
        defaults.set(config.adaptiveCaptureEnabled, forKey: "deleteDuplicateFrames")
        defaults.set(config.deduplicationThreshold, forKey: "deduplicationThreshold")
        defaults.set(config.captureOnWindowChange, forKey: "captureOnWindowChange")
        defaults.set(config.redactWindowTitlePatterns.joined(separator: "\n"), forKey: "redactWindowTitlePatterns")
        defaults.set(config.redactBrowserURLPatterns.joined(separator: "\n"), forKey: "redactBrowserURLPatterns")
        struct AppLabel: Codable { let bundleID: String; let name: String; let iconPath: String? }
        let old = defaults.string(forKey: "excludedApps").flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([AppLabel].self, from: $0) } ?? []
        let labels = config.excludedAppBundleIDs.filter { $0 != "com.apple.loginwindow" }.sorted().map { id in
            old.first { $0.bundleID == id } ?? AppLabel(bundleID: id, name: id, iconPath: nil)
        }
        defaults.set(String(data: try JSONEncoder().encode(labels), encoding: .utf8), forKey: "excludedApps")
    }

    static func validate(_ config: CaptureConfig) throws {
        guard config.captureIntervalSeconds.isFinite, (1...60).contains(config.captureIntervalSeconds),
              config.deduplicationThreshold.isFinite, (0...1).contains(config.deduplicationThreshold),
              config.excludedAppBundleIDs.count <= 256,
              config.excludedAppBundleIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              config.redactWindowTitlePatterns.count <= 128, config.redactBrowserURLPatterns.count <= 128,
              (config.redactWindowTitlePatterns + config.redactBrowserURLPatterns).allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") && !$0.contains("\n")
              }) else { throw RetraceCommandError.invalidArguments }
    }
}
