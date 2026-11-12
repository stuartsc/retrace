import Foundation
import Storage

/// One immutable choice for every writer owned by a ServiceContainer. Only new
/// AAC output is compacted; existing media is never opened by this policy.
struct AudioWriterPolicy: Sendable {
    static let rollbackDefaultsKey = "audioContainerPaddingCompactionDisabled"
    let compactContainerPadding: Bool

    /// Read once when the production container is constructed. Restart applies
    /// rollback consistently to capture, backfill and later model upgrades.
    static func production(defaults: UserDefaults = .standard) -> Self {
        .init(compactContainerPadding: !defaults.bool(forKey: rollbackDefaultsKey))
    }

    /// Private fixtures keep the library's conservative writer default unless
    /// their test explicitly selects the production policy.
    static let isolatedTest = Self(compactContainerPadding: false)

    func makeWriter(storageRoot: URL) -> AudioSegmentWriter {
        AudioSegmentWriter(storageRoot: storageRoot, compactContainerPadding: compactContainerPadding)
    }
}
