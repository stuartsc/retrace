import AppKit
import SwiftUI

/// Native layout establishes initial following on macOS 13/14 too. The local
/// input observer never consumes events or treats programmatic scrolls as reading.
struct LiveContextScrollInteractionObserver: NSViewRepresentable {
    var isActive: @MainActor () -> Bool = { true }
    var shouldInitiallyFollow: (@MainActor () -> Bool)? = nil
    let onScroll: @MainActor () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isActive = isActive
        view.onScroll = onScroll
        view.shouldInitiallyFollow = shouldInitiallyFollow
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.isActive = isActive
        view.onScroll = onScroll
        view.shouldInitiallyFollow = shouldInitiallyFollow
        view.scheduleInitialFollow()
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var isActive: @MainActor () -> Bool = { true }
        var onScroll: (@MainActor () -> Void)?
        var shouldInitiallyFollow: (@MainActor () -> Bool)?
        private var monitor: Any?
        private weak var attachedWindow: NSWindow?
        private var initialFollowWork: DispatchWorkItem?
        private var initialFollowGeneration = UUID()
        private var initialFollowAttempts = 0
        private var initialFollowFinished = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI can move the same representable within its existing
            // window during header/layout updates. That is not owner teardown.
            if let window, attachedWindow === window {
                scheduleInitialFollow()
                return
            }
            stop()
            attachedWindow = window
            guard window != nil else { return }
            initialFollowFinished = false
            initialFollowAttempts = 0
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
                // A retained hidden transcript can overlap the active Settings pane.
                // Ignore its input before touching the pending initial follow.
                guard let self, self.isActive() else { return event }
                if self.isReadingInteraction(event) {
                    self.cancelInitialFollow()
                    self.onScroll?()
                }
                return event
            }
            scheduleInitialFollow()
        }

        override func layout() {
            super.layout()
            scheduleInitialFollow()
        }

        func scheduleInitialFollow() {
            guard window != nil, !initialFollowFinished,
                  shouldInitiallyFollow != nil else { return }
            guard isActive(), shouldInitiallyFollow?() == true else { invalidateInitialFollowWork(); return }
            guard initialFollowWork == nil else { return }
            let generation = initialFollowGeneration
            let work = DispatchWorkItem { [weak self] in self?.initiallyFollow(generation: generation) }
            initialFollowWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: work)
        }

        private func initiallyFollow(generation: UUID) {
            guard generation == initialFollowGeneration, window != nil,
                  !initialFollowFinished else { return }
            guard isActive(), shouldInitiallyFollow?() == true else { invalidateInitialFollowWork(); return }
            initialFollowAttempts += 1
            // The newest end is the top. Older lazy rows can retain estimated
            // heights without moving initial following to an estimated bottom.
            if let scroll = transcriptScrollView(), let document = scroll.documentView,
               scroll.contentView.bounds.height > 0 {
                scroll.layoutSubtreeIfNeeded()
                document.layoutSubtreeIfNeeded()
                let top = document.isFlipped ? document.bounds.minY
                    : max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
                if document.bounds.height > 0, top.isFinite {
                    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: top))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    if abs(scroll.contentView.bounds.minY - top) <= 1 {
                        cancelInitialFollow()
                        return
                    }
                }
            }
            initialFollowWork = nil
            // Attachment can need another layout pass. Never leave an unbounded
            // retry or a delayed move after reading starts.
            if initialFollowAttempts < 6 { scheduleInitialFollow() }
            else { cancelInitialFollow() }
        }

        private func transcriptScrollView() -> NSScrollView? {
            guard let content = window?.contentView else { return nil }
            // Breadth first avoids walking the entire eager document before
            // reaching its enclosing scroll view. Geometry and row ownership
            // together exclude adjacent, parent and nested scroll views.
            var pending = [content], visited = 0
            while visited < pending.count, visited < 5_000 {
                let view = pending[visited]
                visited += 1
                if let scroll = view as? NSScrollView,
                   contains(scroll), hasTranscriptRow(in: scroll) { return scroll }
                pending.append(contentsOf: view.subviews)
            }
            return nil
        }

        private func hasTranscriptRow(in scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView else { return false }
            var pending = [document], visited = 0
            while visited < pending.count, visited < 5_000 {
                let view = pending[visited]
                visited += 1
                if let marker = view as? LiveContextTranscriptRowIdentity.MarkerView,
                   marker.enclosingScrollView === scroll { return true }
                pending.append(contentsOf: view.subviews)
            }
            return false
        }

        private func cancelInitialFollow() {
            initialFollowFinished = true
            invalidateInitialFollowWork()
        }

        private func invalidateInitialFollowWork() {
            // Inactivity is temporary: keep the remaining initial-follow budget
            // so the same populated attachment can become active later. Reading,
            // completion, exhaustion and detachment call cancelInitialFollow.
            initialFollowGeneration = UUID()
            initialFollowWork?.cancel()
            initialFollowWork = nil
        }

        private func isReadingInteraction(_ event: NSEvent) -> Bool {
            guard let window, event.windowNumber == window.windowNumber else { return false }
            switch event.type {
            case .scrollWheel:
                return bounds.contains(convert(event.locationInWindow, from: nil)) && event.scrollingDeltaY != 0
            case .keyDown:
                // Page/Home/End and vertical arrows can move the native scroll view
                // without generating any wheel event. Scope them to its actual
                // first responder, never an unrelated search/name editor.
                guard [UInt16(115), 116, 119, 121, 125, 126, 49].contains(event.keyCode),
                      !event.modifierFlags.contains(.control),
                      let responder = window.firstResponder as? NSView,
                      !(responder is NSControl),
                      !((responder as? NSTextView)?.isEditable ?? false),
                      let scroll = (responder as? NSScrollView) ?? responder.enclosingScrollView else { return false }
                if event.keyCode == 49 && !event.modifierFlags.intersection([.command, .option]).isEmpty { return false }
                return contains(scroll)
            case .leftMouseDown, .leftMouseDragged:
                guard let content = window.contentView else { return false }
                var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
                while let view = hit {
                    if let scroller = view as? NSScroller,
                       let scroll = ancestorScrollView(of: scroller) { return contains(scroll) }
                    hit = view.superview
                }
                return false
            default:
                return false
            }
        }

        private func ancestorScrollView(of view: NSView) -> NSScrollView? {
            // A native scroller is a sibling of the clip view. AppKit's
            // enclosingScrollView is intended for document descendants and
            // need not identify the owner of the scroller itself.
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scroll = candidate as? NSScrollView { return scroll }
                ancestor = candidate.superview
            }
            return nil
        }

        private func contains(_ scroll: NSScrollView) -> Bool {
            let rect = convert(scroll.bounds, from: scroll)
            // The representable is the ScrollView background, rather than a child
            // of its clip view. Compare native geometry to scope sibling views.
            return !rect.isEmpty && bounds.insetBy(dx: -1, dy: -1).contains(rect)
        }

        func stop() {
            attachedWindow = nil
            cancelInitialFollow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            initialFollowWork?.cancel()
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Opaque identity attached to the real row content. It supplies no accessibility
/// label or evidence text and never infers identity from a table index.
struct LiveContextTranscriptRowIdentity: NSViewRepresentable {
    let rowID: String
    func makeNSView(context: Context) -> MarkerView { MarkerView(rowID: rowID) }
    func updateNSView(_ view: MarkerView, context: Context) { view.rowID = rowID }

    final class MarkerView: NSView {
        var rowID: String
        init(rowID: String) { self.rowID = rowID; super.init(frame: .zero) }
        required init?(coder: NSCoder) { return nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Native scroll identity preserves a visible row when lazy heights settle or
/// older speaker turns join the page. macOS 13 retains the same ordered lazy
/// stack and explicit ScrollViewReader following without calling newer APIs.
struct LiveTranscriptScrollTargets: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.scrollTargetLayout() }
        else { content }
    }
}

struct LiveTranscriptScrollPosition: ViewModifier {
    @Binding var position: String?
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.scrollPosition(id: $position) }
        else { content }
    }
}
