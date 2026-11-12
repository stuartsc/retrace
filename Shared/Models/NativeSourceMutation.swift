import Foundation

/// Process-local native recording dependencies. Never an evidence/disclosure grant
/// and deliberately not Codable: batch paths must not enter exported UI payloads.
public enum NativeSourceTarget: Hashable, Sendable {
    case frame(Int64)
    case segment(Int64)
    case audioRow(Int64)
    // The V23 latest-pass predicate groups non-word rows by path, across sources.
    case audioBatch(String)
    case observation(UUID)
    case comment(Int64)
}

public struct NativeSourceDependencies: Equatable, Sendable {
    public let targets: Set<NativeSourceTarget>
    public let all: Bool
    public static let unknown = Self(targets: [], all: true)
    public static let none = Self(targets: [])
    public init(targets: Set<NativeSourceTarget>, all: Bool = false) {
        self.all = all || targets.count > 4096
        self.targets = self.all ? [] : targets
    }
    public func merging(_ other: Self) -> Self {
        if all || other.all { return .unknown }
        return Self(targets: targets.union(other.targets))
    }
}

/// Bounded writer notification. Even an empty target set revokes in-flight read
/// and transmission epochs; only cached presentation invalidation is selective.
public struct NativeSourceMutation: Equatable, Sendable {
    public let dependencies: NativeSourceDependencies
    public static let all = Self(.unknown)
    public static let indexOnly = Self(.none)
    public init(_ dependencies: NativeSourceDependencies) {
        self.dependencies = dependencies.targets.count > 256 ? .unknown : dependencies
    }
    public func affects(_ retained: NativeSourceDependencies) -> Bool {
        dependencies.all || (!dependencies.targets.isEmpty && (retained.all || !dependencies.targets.isDisjoint(with: retained.targets)))
    }
    public func merging(_ other: Self) -> Self { Self(dependencies.merging(other.dependencies)) }
}
