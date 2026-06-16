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
    func insert(text: String, method: DictationInsertionMethod, restoreDelay: TimeInterval) async throws
}

public actor ClipboardDictationInsertionService: DictationInsertionServicing {
    public init() {}

    public func insert(text: String, method: DictationInsertionMethod, restoreDelay: TimeInterval) async throws {
        guard method == .clipboardPaste else {
            throw DictationInsertionError.unsupportedMethod
        }

        try await MainActor.run {
            guard !IsSecureEventInputEnabled() else {
                throw DictationInsertionError.secureInputEnabled
            }

            let pasteboard = NSPasteboard.general
            let snapshot = PasteboardSnapshot.capture(from: pasteboard)

            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            guard let source = CGEventSource(stateID: .hidSystemState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                snapshot.restore(to: pasteboard)
                throw DictationInsertionError.pasteEventFailed
            }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                snapshot.restore(to: pasteboard)
            }
        }
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
