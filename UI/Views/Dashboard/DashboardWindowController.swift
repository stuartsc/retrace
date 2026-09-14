import AppKit
import SwiftUI
import App
import Shared

private enum DashboardWindowSizing {
    static let defaultWidth = DashboardVoiceLayoutPolicy.defaultWindowWidth
    static let defaultHeight = DashboardVoiceLayoutPolicy.defaultWindowHeight
    static let minWidth = DashboardVoiceLayoutPolicy.minWindowWidth
    static let minHeight = DashboardVoiceLayoutPolicy.minWindowHeight
}

/// Manages the dashboard window as an on-demand window
/// This follows the menu bar app pattern where windows are only created when requested
@MainActor
public class DashboardWindowController: NSObject {

    // MARK: - Singleton

    public static let shared = DashboardWindowController()

    // MARK: - Properties

    private(set) var window: NSWindow?
    private var coordinator: AppCoordinator?
    let navigation = DashboardNavigationState()
    private let notificationCenter: NotificationCenter
    private let windowFactory: (@MainActor (DashboardNavigationState) -> NSWindow)?
    private let presentWindow: @MainActor (NSWindow) -> Void
    private let hideApplication: @MainActor () -> Void
    private var notificationObservers: [NSObjectProtocol] = []

    /// Whether the dashboard window is currently visible
    public private(set) var isVisible = false

    // MARK: - Initialization

    private override convenience init() {
        self.init(notificationCenter: .default)
    }

    /// The native window/presentation boundary keeps routing independently
    /// testable without starting application services or activating a test app.
    init(notificationCenter: NotificationCenter,
         windowFactory: (@MainActor (DashboardNavigationState) -> NSWindow)? = nil,
         presentWindow: @escaping @MainActor (NSWindow) -> Void = { window in
             NSApp.activate(ignoringOtherApps: true)
             window.makeKeyAndOrderFront(nil)
             window.orderFrontRegardless()
         },
         hideApplication: @escaping @MainActor () -> Void = { NSApp.hide(nil) }) {
        self.notificationCenter = notificationCenter
        self.windowFactory = windowFactory
        self.presentWindow = presentWindow
        self.hideApplication = hideApplication
        super.init()
        setupNotifications()
    }

    deinit {
        for observer in notificationObservers { notificationCenter.removeObserver(observer) }
    }

    private func setupNotifications() {
        notificationObservers.append(notificationCenter.addObserver(
            forName: .toggleDashboard,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.toggle()
            }
        })

        for name in DashboardNavigationState.notificationNames {
            notificationObservers.append(notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                // NotificationCenter's main queue delivers synchronously on
                // main. Admit the destination before any window/view is made.
                MainActor.assumeIsolated {
                    guard let self, (notification.object as? DashboardWindowController) !== self else { return }
                    let shouldShow = self.navigation.receive(notification)
                    self.updateWindowTitle(self.navigation.windowTitle)
                    if shouldShow { self.show() }
                }
            })
        }
    }

    // MARK: - Configuration

    /// Configure with the app coordinator (call once during app launch)
    public func configure(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Show/Hide

    /// Show the dashboard window
    public func show() {
        Log.info("[DashboardWindowController] show requested state=\(windowStateSnapshot())", category: .ui)
        updateWindowTitle(navigation.windowTitle)

        // If window already exists and is visible, just bring it to front
        if let window = window, window.isVisible {
            Log.info("[DashboardWindowController] show routed to bringToFront (window already visible)", category: .ui)
            bringToFront()
            return
        }

        // Create window if needed.
        if window == nil {
            if let windowFactory {
                window = windowFactory(navigation)
            } else if let coordinator {
                Log.info("[DashboardWindowController] creating dashboard window", category: .ui)
                window = createWindow(coordinator: coordinator)
            } else {
                Log.error("[DashboardWindowController] Cannot show - coordinator not configured", category: .ui)
                return
            }
        }

        guard let window = window else { return }
        window.title = navigation.windowTitle

        // Show the window
        presentWindow(window)

        isVisible = true
        Log.info("[DashboardWindowController] show completed state=\(windowStateSnapshot())", category: .ui)

        // Post notification
        notificationCenter.post(name: .dashboardDidOpen, object: nil)
    }

    /// Hide the dashboard window
    public func hide() {
        Log.info("[DashboardWindowController] hide requested state=\(windowStateSnapshot())", category: .ui)
        guard let window = window, isVisible else {
            Log.info("[DashboardWindowController] hide skipped (no visible dashboard)", category: .ui)
            return
        }

        window.orderOut(nil)
        isVisible = false
        Log.info("[DashboardWindowController] hide completed state=\(windowStateSnapshot())", category: .ui)
        hideAppIfNoForegroundWindows(ignoring: window)

        // Post notification
        notificationCenter.post(name: .dashboardDidClose, object: nil)
    }

    /// Toggle dashboard visibility
    /// - If hidden: show and bring to front
    /// - If visible but behind other windows: bring to front
    /// - If visible and frontmost: hide
    public func toggle() {
        if isVisible {
            // Check if window is frontmost (key window and app is active)
            // OR if a modal sheet is attached (sheet becomes key window, not parent window)
            if let window = window, (window.isKeyWindow || window.attachedSheet != nil) && NSApp.isActive {
                hide()
            } else {
                bringToFront()
            }
        } else {
            show()
        }
    }

    /// Bring dashboard window to front if visible
    public func bringToFront() {
        Log.info("[DashboardWindowController] bringToFront requested state=\(windowStateSnapshot())", category: .ui)
        guard let window = window else { return }

        presentWindow(window)
        Log.info("[DashboardWindowController] bringToFront completed state=\(windowStateSnapshot())", category: .ui)
    }

    /// Update the dashboard window title used for metadata/window-list consumers.
    func updateWindowTitle(_ title: String) {
        window?.title = title
    }

    // MARK: - Window Creation

    private func createWindow(coordinator: AppCoordinator) -> NSWindow {
        // Create the SwiftUI view for the dashboard content
        let dashboardContent = DashboardContentView(coordinator: coordinator, navigation: navigation)

        // Create hosting controller
        let hostingController = NSHostingController(rootView: dashboardContent)

        // Create window
        let window = DashboardWindow(contentViewController: hostingController)

        // Configure window properties
        window.title = "Dashboard"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(
            NSSize(
                width: DashboardWindowSizing.defaultWidth,
                height: DashboardWindowSizing.defaultHeight
            )
        )
        window.minSize = NSSize(
            width: DashboardWindowSizing.minWidth,
            height: DashboardWindowSizing.minHeight
        )
        window.center()

        // Set window level and appearance
        window.level = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.backgroundColor = NSColor(named: "retraceBackground") ?? NSColor.windowBackgroundColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Set delegate to handle window events
        window.delegate = self

        return window
    }

    // MARK: - Navigate to View

    /// Navigate to settings view within the dashboard
    @objc public func showSettings() {
        navigation.openSettings()
        // Preserve the existing signal that lets the timeline hide before
        // Settings is shown, without admitting our own request a second time.
        notificationCenter.post(name: .openSettings, object: self)
        show()
    }

    /// Toggle between settings and dashboard views
    /// If on dashboard or window not visible: show settings
    /// If on settings: go back to dashboard
    public func toggleSettings() {
        show()
        notificationCenter.post(name: .toggleSettings, object: nil)
    }

    /// Navigate to changelog view within the dashboard
    public func showChangelog() {
        show()
        notificationCenter.post(
            name: .openDashboard,
            object: nil,
            userInfo: ["target": "changelog"]
        )
    }
}

// MARK: - NSWindowDelegate

extension DashboardWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        Log.info("[DashboardWindowController] windowWillClose state(before)=\(windowStateSnapshot())", category: .ui)
        isVisible = false
        Log.info("[DashboardWindowController] windowWillClose state(after)=\(windowStateSnapshot())", category: .ui)
        hideAppIfNoForegroundWindows(ignoring: window)
        notificationCenter.post(name: .dashboardDidClose, object: nil)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        // Post notification so dashboard can refresh its stats
        notificationCenter.post(name: .dashboardDidBecomeKey, object: nil)
    }
}

private extension DashboardWindowController {
    func hideAppIfNoForegroundWindows(ignoring dashboardWindow: NSWindow?) {
        let hasOtherForegroundWindows = NSApp.windows.contains { candidate in
            guard candidate !== dashboardWindow else { return false }
            return candidate.level.rawValue == 0 && candidate.isVisible
        }

        guard !hasOtherForegroundWindows else {
            Log.info("[DashboardWindowController] keeping app active after dashboard hide (other foreground windows visible)", category: .ui)
            return
        }

        Log.info("[DashboardWindowController] hiding app after dashboard hide (no foreground windows visible)", category: .ui)
        hideApplication()
    }

    func windowStateSnapshot() -> String {
        let windowExists = window != nil
        let windowVisible = window?.isVisible ?? false
        let windowKey = window?.isKeyWindow ?? false
        let windowMain = window?.isMainWindow ?? false
        let windowMini = window?.isMiniaturized ?? false

        return "controllerVisible=\(isVisible) windowExists=\(windowExists) windowVisible=\(windowVisible) windowKey=\(windowKey) windowMain=\(windowMain) windowMini=\(windowMini) appHidden=\(NSApp.isHidden) appActive=\(NSApp.isActive)"
    }
}

// MARK: - Dashboard Content View

/// SwiftUI view that wraps the dashboard content
/// This handles navigation between dashboard and settings views
struct DashboardContentView: View {
    let coordinator: AppCoordinator

    /// Wrapper for coordinator to inject as environment object for child views
    @StateObject private var coordinatorWrapper: AppCoordinatorWrapper

    /// Manager for launch on login reminder
    @StateObject private var launchOnLoginReminderManager: LaunchOnLoginReminderManager

    /// Dashboard view model - hoisted here so it persists across tab switches
    @StateObject private var dashboardViewModel: DashboardViewModel

    @ObservedObject var navigation: DashboardNavigationState
    @State private var showFeedbackSheet = false
    @State private var showOnboarding: Bool? = nil
    @State private var hasLoadedDashboard = false
    /// Forces a SwiftUI refresh when global appearance preferences change.
    @State private var appearanceRefreshTick = 0

    init(coordinator: AppCoordinator, navigation: DashboardNavigationState) {
        self.coordinator = coordinator
        self.navigation = navigation
        self._coordinatorWrapper = StateObject(wrappedValue: AppCoordinatorWrapper(coordinator: coordinator))
        self._launchOnLoginReminderManager = StateObject(wrappedValue: LaunchOnLoginReminderManager(coordinator: coordinator))
        self._dashboardViewModel = StateObject(wrappedValue: DashboardViewModel(coordinator: coordinator))
    }

    var body: some View {
        ZStack {
            if let showOnboarding = showOnboarding {
                if showOnboarding {
                    // Show onboarding flow
                    OnboardingView(coordinator: coordinator) {
                        withAnimation {
                            self.showOnboarding = false
                            // Sync menu bar recording status after onboarding completes
                            MenuBarManager.shared?.syncWithCoordinator()
                        }
                    }
                } else {
                    // Main content based on selected view
                    // Persistent background prevents titlebar flash during tab transitions
                    Color.retraceBackground
                        .ignoresSafeArea()

                    selectedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .animation(.easeInOut(duration: 0.2), value: navigation.selectedView)
                }
            } else {
                // Loading state
                Color.retraceBackground
                    .ignoresSafeArea()
            }
        }
        .frame(
            minWidth: DashboardWindowSizing.minWidth,
            minHeight: DashboardWindowSizing.minHeight
        )
        .task {
            await checkOnboarding()
        }
        .onAppear {
            updateDashboardWindowTitle()
        }
        .onChange(of: navigation.selectedView) { _ in updateDashboardWindowTitle() }
        .onChange(of: navigation.currentSettingsTabTitle) { _ in updateDashboardWindowTitle() }
        .onReceive(NotificationCenter.default.publisher(for: .colorThemeDidChange)) { _ in
            appearanceRefreshTick &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .fontStyleDidChange)) { _ in
            appearanceRefreshTick &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFeedback)) { _ in
            showFeedbackSheet = true
            DashboardWindowController.shared.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSystemMonitor)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                navigation.selectedView = .monitor
            }
            DashboardWindowController.shared.show()
            updateDashboardWindowTitle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSystemMonitor)) { _ in
            if navigation.selectedView == .monitor,
               DashboardWindowController.shared.isVisible,
               let window = DashboardWindowController.shared.window,
               (window.isKeyWindow || window.attachedSheet != nil) && NSApp.isActive {
                // Already showing monitor and frontmost — toggle monitor off by hiding window
                DashboardWindowController.shared.hide()
            } else {
                // Show system monitor
                withAnimation(.easeInOut(duration: 0.2)) {
                    navigation.selectedView = .monitor
                }
                DashboardWindowController.shared.show()
                updateDashboardWindowTitle()
            }
        }
        .sheet(isPresented: $showFeedbackSheet) {
            FeedbackFormView()
                .environmentObject(coordinatorWrapper)
        }
    }

    private var selectedContent: some View {
        DashboardDestinationView(
            navigation: navigation,
            dashboard: {
                DashboardView(
                    viewModel: dashboardViewModel,
                    coordinator: coordinator,
                    launchOnLoginReminderManager: launchOnLoginReminderManager,
                    hasLoadedInitialData: $hasLoadedDashboard
                )
            },
            settings: { destination in
                SettingsView(
                    initialTab: destination.tab,
                    initialScrollTargetID: destination.scrollTargetID,
                    navigationRevision: destination.revision,
                    launchOnLoginReminderManager: launchOnLoginReminderManager
                )
                .environmentObject(coordinatorWrapper)
            },
            changelog: { ChangelogView().frame(maxWidth: .infinity, maxHeight: .infinity) },
            monitor: { SystemMonitorView(coordinator: coordinator).frame(maxWidth: .infinity, maxHeight: .infinity) }
        )
    }

    private func checkOnboarding() async {
        let shouldShow = await coordinator.onboardingManager.shouldShowOnboarding()
        await MainActor.run {
            showOnboarding = shouldShow
        }
    }

    private func updateDashboardWindowTitle() {
        DashboardWindowController.shared.updateWindowTitle(navigation.windowTitle)
    }
}

struct DashboardSettingsDestination: Equatable {
    var tab: SettingsTab?
    var scrollTargetID: String?
    var revision: UInt64 = 0
}

/// Navigation outlives any individual SwiftUI destination or native window.
@MainActor
final class DashboardNavigationState: ObservableObject {
    @Published var selectedView: DashboardSelectedView = .dashboard
    @Published private(set) var settingsDestination = DashboardSettingsDestination()
    @Published var currentSettingsTabTitle = SettingsTab.general.rawValue

    static let notificationNames: [Notification.Name] = [
        .openDashboard, .dashboardShowSettings, .toggleSettings, .openSettings,
        .openSettingsAppearance, .openSettingsPower, .openSettingsTags,
        .openSettingsPauseReminderInterval, .openSettingsPowerOCRCard,
        .openSettingsPowerOCRPriority, .openSettingsTimelineScrollOrientation, .settingsSelectedTabDidChange
    ]

    var windowTitle: String {
        switch selectedView {
        case .dashboard: return "Dashboard"
        case .settings: return "Settings - \(currentSettingsTabTitle)"
        case .changelog: return "Changelog"
        case .monitor: return "System Monitor"
        }
    }

    /// Returns whether this notification also requests a visible window.
    func receive(_ notification: Notification) -> Bool {
        switch notification.name {
        case .openDashboard:
            selectedView = notification.userInfo?["target"] as? String == "changelog" ? .changelog : .dashboard
            return false
        case .dashboardShowSettings:
            selectedView = .settings
            return false
        case .toggleSettings:
            selectedView = selectedView == .settings ? .dashboard : .settings
            return false
        case .openSettings:
            openSettings()
        case .openSettingsAppearance:
            openSettings(tab: .general)
        case .openSettingsPower:
            openSettings(tab: .power)
        case .openSettingsTags:
            openSettings(tab: .tags)
        case .openSettingsPauseReminderInterval:
            openSettings(tab: .capture, scrollTargetID: SettingsView.pauseReminderIntervalTargetID)
        case .openSettingsPowerOCRCard:
            openSettings(tab: .power, scrollTargetID: SettingsView.powerOCRCardTargetID)
        case .openSettingsPowerOCRPriority:
            openSettings(tab: .power, scrollTargetID: SettingsView.powerOCRPriorityTargetID)
        case .openSettingsTimelineScrollOrientation:
            openSettings(tab: .general, scrollTargetID: SettingsView.timelineScrollOrientationTargetID)
        case .settingsSelectedTabDidChange:
            if let title = notification.userInfo?["tab"] as? String, !title.isEmpty {
                currentSettingsTabTitle = title
            }
            return false
        default:
            return false
        }
        return true
    }

    func openSettings(tab: SettingsTab? = nil, scrollTargetID: String? = nil) {
        if let tab { currentSettingsTabTitle = tab.rawValue }
        else if selectedView != .settings { currentSettingsTabTitle = SettingsTab.general.rawValue }
        settingsDestination = DashboardSettingsDestination(
            tab: tab, scrollTargetID: scrollTargetID, revision: settingsDestination.revision &+ 1
        )
        selectedView = .settings
    }
}

/// The actual destination switch is independently hostable with inert content;
/// routing tests therefore never instantiate live Settings or app services.
struct DashboardDestinationView<Dashboard: View, Settings: View, Changelog: View, Monitor: View>: View {
    @ObservedObject var navigation: DashboardNavigationState
    var dashboard: () -> Dashboard
    var settings: (DashboardSettingsDestination) -> Settings
    var changelog: () -> Changelog
    var monitor: () -> Monitor

    var body: some View {
        Group {
            switch navigation.selectedView {
            case .dashboard: dashboard()
            case .settings: settings(navigation.settingsDestination)
            case .changelog: changelog()
            case .monitor: monitor()
            }
        }
    }
}

// MARK: - Dashboard Selected View

enum DashboardSelectedView {
    case dashboard
    case settings
    case changelog
    case monitor
}

/// Dashboard window that restores native maximize/restore behavior
/// when double-clicking the title bar area.
private final class DashboardWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if shouldToggleZoom(for: event) {
            zoom(nil)
            return
        }

        super.sendEvent(event)
    }

    private func shouldToggleZoom(for event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 2 else { return false }
        guard styleMask.contains(.titled), styleMask.contains(.resizable) else { return false }

        return isPointInTitleBar(event.locationInWindow)
    }

    private func isPointInTitleBar(_ point: NSPoint) -> Bool {
        let titleBarMinY = contentLayoutRect.maxY
        return point.y >= titleBarMinY
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let dashboardDidOpen = Notification.Name("dashboardDidOpen")
    static let dashboardDidClose = Notification.Name("dashboardDidClose")
    static let dashboardShowSettings = Notification.Name("dashboardShowSettings")
    static let dashboardDidBecomeKey = Notification.Name("dashboardDidBecomeKey")
    static let toggleSettings = Notification.Name("toggleSettings")
    static let settingsSelectedTabDidChange = Notification.Name("settingsSelectedTabDidChange")
}
