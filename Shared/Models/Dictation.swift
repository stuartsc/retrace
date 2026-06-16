import Foundation

// MARK: - Dictation Models

public enum DictationInsertionMethod: String, Codable, Sendable, CaseIterable {
    case clipboardPaste = "clipboard_paste"

    public var displayName: String {
        switch self {
        case .clipboardPaste:
            return "Clipboard Paste"
        }
    }
}

public enum DictationInsertionStatus: String, Codable, Sendable, CaseIterable {
    case capturing
    case transcribing
    case inserted
    case empty
    case failed
    case cancelled
    case blockedSecureInput = "blocked_secure_input"
    case blockedFocusChanged = "blocked_focus_changed"
}

public struct DictationTargetContext: Codable, Sendable, Equatable {
    public let bundleID: String?
    public let appName: String?
    public let windowTitle: String?

    public init(bundleID: String?, appName: String?, windowTitle: String?) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
    }

    public func isCompatibleInsertionTarget(with current: DictationTargetContext?) -> Bool {
        guard let expectedBundleID = normalized(bundleID), !expectedBundleID.isEmpty else {
            return true
        }
        guard let currentBundleID = normalized(current?.bundleID), !currentBundleID.isEmpty else {
            return false
        }
        guard expectedBundleID == currentBundleID else {
            return false
        }

        guard let expectedTitle = normalized(windowTitle), !expectedTitle.isEmpty,
              let currentTitle = normalized(current?.windowTitle), !currentTitle.isEmpty else {
            return true
        }

        return expectedTitle == currentTitle
    }

    private func normalized(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public struct DictationConfig: Codable, Sendable, Equatable {
    public let isEnabled: Bool
    public let shortcut: ShortcutConfig
    public let preRollSeconds: TimeInterval
    public let postRollSeconds: TimeInterval
    public let restoreClipboardDelaySeconds: TimeInterval
    public let insertionMethod: DictationInsertionMethod

    public init(
        isEnabled: Bool = true,
        shortcut: ShortcutConfig = .defaultDictation,
        preRollSeconds: TimeInterval = 0.15,
        postRollSeconds: TimeInterval = 0.20,
        restoreClipboardDelaySeconds: TimeInterval = 0.20,
        insertionMethod: DictationInsertionMethod = .clipboardPaste
    ) {
        self.isEnabled = isEnabled
        self.shortcut = shortcut
        self.preRollSeconds = preRollSeconds
        self.postRollSeconds = postRollSeconds
        self.restoreClipboardDelaySeconds = restoreClipboardDelaySeconds
        self.insertionMethod = insertionMethod
    }

    public static let `default` = DictationConfig()
}

public struct DictationSession: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let insertedAt: Date?
    public let text: String
    public let status: DictationInsertionStatus
    public let targetContext: DictationTargetContext?
    public let insertionMethod: DictationInsertionMethod
    public let errorMessage: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date?,
        insertedAt: Date?,
        text: String,
        status: DictationInsertionStatus,
        targetContext: DictationTargetContext?,
        insertionMethod: DictationInsertionMethod,
        errorMessage: String?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.insertedAt = insertedAt
        self.text = text
        self.status = status
        self.targetContext = targetContext
        self.insertionMethod = insertionMethod
        self.errorMessage = errorMessage
    }

    public func updated(
        endedAt: Date? = nil,
        insertedAt: Date? = nil,
        text: String? = nil,
        status: DictationInsertionStatus,
        errorMessage: String? = nil
    ) -> DictationSession {
        DictationSession(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt ?? self.endedAt,
            insertedAt: insertedAt ?? self.insertedAt,
            text: text ?? self.text,
            status: status,
            targetContext: targetContext,
            insertionMethod: insertionMethod,
            errorMessage: errorMessage
        )
    }
}
