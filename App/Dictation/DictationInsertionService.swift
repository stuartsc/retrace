import AppKit
import Carbon.HIToolbox
import Foundation
import Shared

public enum DictationInsertionError: Error, LocalizedError, Sendable {
    case secureInputEnabled
    case unsupportedMethod
    case pasteEventFailed

    public var errorDescription: String? {
        switch self {
        case .secureInputEnabled:
            return "Secure keyboard input is enabled"
        case .unsupportedMethod:
            return "Unsupported dictation insertion method"
        case .pasteEventFailed:
            return "Unable to create paste keyboard event"
        }
    }
}

public protocol DictationInsertionServicing: Actor {
    /// Hold admission at the actual paste mutation, after all asynchronous hops.
    func insert(text: String, method: DictationInsertionMethod, restoreDelay: TimeInterval,
                admission: NativeMutationFence) async throws
}

public actor ClipboardDictationInsertionService: DictationInsertionServicing {
    #if DEBUG
    private var beforeMutationForTesting: (@MainActor @Sendable () async -> Void)?
    private var pasteboardNameForTesting: String?
    private var postPasteForTesting: (@MainActor @Sendable () throws -> Void)?

    /// Exercises the real clipboard mutation with an isolated pasteboard and no
    /// global keyboard events. Production always uses the native path below.
    init(testingPasteboardName: String,
         beforeMutation: @escaping @MainActor @Sendable () async -> Void,
         postPaste: @escaping @MainActor @Sendable () throws -> Void) {
        pasteboardNameForTesting = testingPasteboardName
        beforeMutationForTesting = beforeMutation
        postPasteForTesting = postPaste
    }
    #endif

    public init() {}

    public func insert(text: String, method: DictationInsertionMethod, restoreDelay: TimeInterval,
                       admission: NativeMutationFence) async throws {
        guard method == .clipboardPaste else {
            throw DictationInsertionError.unsupportedMethod
        }

        let pasteboardName: String?
        let postPaste: @MainActor @Sendable () throws -> Void
        #if DEBUG
        await beforeMutationForTesting?()
        pasteboardName = pasteboardNameForTesting
        postPaste = postPasteForTesting ?? Self.postNativePaste
        #else
        pasteboardName = nil
        postPaste = Self.postNativePaste
        #endif

        try await MainActor.run {
            guard !IsSecureEventInputEnabled() else {
                throw DictationInsertionError.secureInputEnabled
            }

            let pasteboard = pasteboardName.map { NSPasteboard(name: .init($0)) } ?? .general
            let snapshot = PasteboardSnapshot.capture(from: pasteboard)

            // No suspension between permission validation and posting the paste.
            // Disable waits only for this synchronous mutation, never recognition.
            try admission.withAdmission {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                do { try postPaste() }
                catch { snapshot.restore(to: pasteboard); throw error }

                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                    snapshot.restore(to: pasteboard)
                }
            }
        }
    }

    @MainActor
    private static func postNativePaste() throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw DictationInsertionError.pasteEventFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    private struct Item {
        let typeData: [(NSPasteboard.PasteboardType, Data)]
    }

    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(typeData: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.typeData {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(restoredItems)
    }
}
