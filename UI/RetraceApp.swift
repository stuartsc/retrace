import SwiftUI
import App
import Shared
import SQLCipher
import Darwin
import IOKit.ps

/// Main app entry point
@main
struct RetraceApp: App {

    // MARK: - Properties

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Body

    var body: some Scene {
        // Menu bar app - no WindowGroup, use Settings for menu commands only
        Settings {
            EmptyView()
        }
        .commands {
            appCommands
        }
    }

    // MARK: - Commands

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            // Remove "New Window" since we're a menu bar app
        }

        // Add Dashboard and Timeline to the app menu (top left, after "About Retrace")
        CommandGroup(after: .appInfo) {
            Button("Open Dashboard") {
                DashboardWindowController.shared.show()
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict

            Button("Open Timeline") {
                TimelineWindowController.shared.toggle()
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict

            Divider()
        }

        CommandMenu("View") {
            Button("Dashboard") {
                DashboardWindowController.shared.show()
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Timeline") {
                // Open fullscreen timeline overlay
                TimelineWindowController.shared.toggle()
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict

            Divider()

            Button("Settings") {
                DashboardWindowController.shared.toggleSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Recording") {
            Button("Start/Stop Recording") {
                Task {
                    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                        try? await appDelegate.toggleRecording()
                    }
                }
            }
            // Note: Global hotkey is registered via HotkeyManager from saved settings
            // Don't add a static .keyboardShortcut here as it would conflict
        }
    }

}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var menuBarManager: MenuBarManager?
    private var coordinatorWrapper: AppCoordinatorWrapper?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var powerSettingsApplyTask: Task<Void, Never>?
    private var wasRecordingBeforeSleep = false
    private var lastKnownPowerSource: PowerStateMonitor.PowerSource?
    private var isHandlingSystemSleep = false
    private var isHandlingSystemWake = false
    private var pendingDeeplinkURLs: [URL] = []
    private var shouldShowDashboardAfterInitialization = false
    private var isActivationRevealInFlight = false
    private var isInitialized = false
    private var isTerminationFlushInProgress = false
    private static let devDeeplinkEnvKey = "RETRACE_DEV_DEEPLINK_URL"
    private static let externalDashboardRevealNotification = Notification.Name("io.retrace.app.externalDashboardReveal")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt user to move app to Applications folder if not already there
        AppMover.moveToApplicationsFolderIfNecessary()
        setupExternalDashboardRevealObserver()

        // CRITICAL FIX: Ensure bundle identifier is set
        // When running from Xcode/SPM, the bundle ID might not be set correctly
        if Bundle.main.bundleIdentifier == nil {
            // Set activation policy to accessory (menu bar app, no dock icon)
            // This is required when running without a proper bundle ID
            NSApp.setActivationPolicy(.accessory)
        }

        // Check if another instance is already running (skip if this is a relaunch)
        let isRelaunch = UserDefaults.standard.bool(forKey: "isRelaunching")
        if isRelaunch {
            Log.info("[AppDelegate] App relaunched successfully", category: .app)
            UserDefaults.standard.removeObject(forKey: "isRelaunching")
        } else if isAnotherInstanceRunning() {
            Log.info("[AppDelegate] Another instance already running, activating it", category: .app)
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

        // Configure app appearance
        configureAppearance()

        // Initialize the Sparkle updater for automatic updates
        UpdaterManager.shared.initialize()

        // Start main thread hang detection (writes emergency diagnostics if main thread freezes)
        MainThreadHangDetector.shared.start()

        // Initialize the app coordinator and UI
        Task { @MainActor in
            await initializeApp()

            // Record app launch metric
            if let coordinator = coordinatorWrapper?.coordinator {
                DashboardViewModel.recordAppLaunch(coordinator: coordinator)
            }
        }

        // Note: Permissions are now handled in the onboarding flow
    }

    @MainActor
    private func initializeApp() async {
        // Pre-flight check: Ensure custom storage path is accessible (if set)
        if !(await checkStoragePathAvailable()) {
            return // User chose to quit or we're waiting for them to reconnect
        }

        do {
            let wrapper = AppCoordinatorWrapper()
            self.coordinatorWrapper = wrapper
            try await wrapper.initialize()
            Log.info("[AppDelegate] Coordinator initialized successfully", category: .app)

            configureWatchdogAutoQuit()

            // Start the main thread watchdog to detect UI freezes
            MainThreadWatchdog.shared.start()

            // Setup menu bar icon
            let menuBar = MenuBarManager(
                coordinator: wrapper.coordinator,
                onboardingManager: wrapper.coordinator.onboardingManager
            )
            menuBar.setup()
            self.menuBarManager = menuBar

            // Configure the timeline window controller
            TimelineWindowController.shared.configure(coordinator: wrapper.coordinator)

            // Configure the dashboard window controller
            DashboardWindowController.shared.configure(coordinator: wrapper.coordinator)

            // Configure the pause reminder window controller
            PauseReminderWindowController.shared.configure(coordinator: wrapper.coordinator)

            // Setup sleep/wake observers to properly handle segment tracking
            setupSleepWakeObservers()

            // Setup power settings change observer
            setupPowerSettingsObserver()

            Log.info("[AppDelegate] Menu bar and window controllers initialized", category: .app)

            // Mark as initialized before processing pending deeplinks
            isInitialized = true

            // Process any deeplinks that arrived before initialization completed
            var didHandleInitialDeeplink = false
            if !pendingDeeplinkURLs.isEmpty {
                Log.info("[AppDelegate] Processing \(pendingDeeplinkURLs.count) pending deeplink(s)", category: .app)
                for url in pendingDeeplinkURLs {
                    handleDeeplink(url)
                }
                pendingDeeplinkURLs.removeAll()
                didHandleInitialDeeplink = true
            }

            // Dev-only startup deeplink simulation from terminal:
            // RETRACE_DEV_DEEPLINK_URL='retrace://search?...' swift run Retrace
            if processDevDeeplinkFromEnvironment() {
                didHandleInitialDeeplink = true
            }

            if shouldShowDashboardAfterInitialization {
                requestDashboardReveal(source: "pendingExternalDashboardReveal")
                shouldShowDashboardAfterInitialization = false
            } else if !didHandleInitialDeeplink {
                // Show dashboard on first launch (only if no deeplinks)
                DashboardWindowController.shared.show()
            }

        } catch {
            Log.error("[AppDelegate] Failed to initialize: \(error)", category: .app)
        }
    }

    private func configureWatchdogAutoQuit() {
        MainThreadWatchdog.shared.setAutoQuitHandler { blockedSeconds in
            let blockedFor = String(format: "%.1f", blockedSeconds)
            Log.critical("[Watchdog] Auto-quit threshold reached (\(blockedFor)s). Capturing diagnostics and attempting graceful termination.", category: .ui)
            EmergencyDiagnostics.capture(trigger: "watchdog_auto_quit")

            // If main is still responsive enough, request normal app termination first.
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }

            // Fallback: if graceful termination cannot run (main frozen), force-exit.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
                Log.critical("[Watchdog] Graceful termination did not complete after auto-quit trigger. Force exiting.", category: .ui)
                Darwin.exit(0)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in menu bar even when window is closed
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            Log.info("[LaunchSurface] applicationShouldHandleReopen hasVisibleWindows=\(flag) state=\(launchSurfaceStateSnapshot())", category: .app)
            requestDashboardReveal(source: "applicationShouldHandleReopen")
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            let shouldReveal = shouldRevealDashboardForActivation()
            Log.info("[LaunchSurface] applicationDidBecomeActive shouldReveal=\(shouldReveal) state=\(launchSurfaceStateSnapshot())", category: .app)

            guard shouldReveal, !isActivationRevealInFlight else { return }

            isActivationRevealInFlight = true
            requestDashboardReveal(source: "applicationDidBecomeActive")
            isActivationRevealInFlight = false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminationFlushInProgress {
            return .terminateNow
        }

        isTerminationFlushInProgress = true

        // Save timeline state (filters, search) for cross-session persistence.
        TimelineWindowController.shared.saveStateForTermination()

        // Flush active timeline metrics asynchronously with a bounded timeout.
        // Use terminateLater to avoid blocking the main thread during shutdown.
        Task { @MainActor [weak self] in
            _ = await TimelineWindowController.shared.forceRecordSessionMetrics(timeoutMs: 350)
            self?.isTerminationFlushInProgress = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    // MARK: - Storage Path Validation

    /// Pre-flight check to ensure custom storage path is accessible
    /// Returns true if app should continue, false if user chose to quit
    @MainActor
    private func checkStoragePathAvailable() async -> Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard

        // Only check if user has set a custom path (not new users)
        guard let customPath = defaults.string(forKey: "customRetraceDBLocation") else {
            return true // Using default path, always available
        }

        let fm = FileManager.default
        let expandedPath = NSString(string: customPath).expandingTildeInPath

        // Check if the custom path itself exists
        // User explicitly set this path, so we should verify it's there
        if fm.fileExists(atPath: expandedPath) {
            return true // Custom path exists
        }

        // Custom path doesn't exist - determine the appropriate message
        let parentDir = (expandedPath as NSString).deletingLastPathComponent
        let isDriveDisconnected = !fm.fileExists(atPath: parentDir)

        Log.warning("[AppDelegate] Custom storage path not found: \(expandedPath) (drive disconnected: \(isDriveDisconnected))", category: .app)

        let alert = NSAlert()
        if isDriveDisconnected {
            alert.messageText = "Storage Drive Not Found"
            alert.informativeText = """
                Retrace is configured to store data at:
                \(customPath)

                This location is not accessible. The drive may be disconnected.

                What would you like to do?
                """
        } else {
            alert.messageText = "Database Folder Not Found"
            alert.informativeText = """
                Retrace is configured to store data at:
                \(customPath)

                This folder no longer exists. It may have been moved or deleted.

                What would you like to do?
                """
        }
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Browse for Folder")
        alert.addButton(withTitle: "Reset to Default Location")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Browse for folder - open at parent of the missing path
            if let newPath = await browseForDatabaseFolder(startingAt: parentDir) {
                defaults.set(newPath, forKey: "customRetraceDBLocation")
                defaults.synchronize()
                Log.info("[AppDelegate] User selected new storage location: \(newPath)", category: .app)
                return true
            } else {
                // User cancelled - show dialog again
                return await checkStoragePathAvailable()
            }

        case .alertSecondButtonReturn:
            // Reset to default location
            defaults.removeObject(forKey: "customRetraceDBLocation")
            defaults.synchronize()
            Log.info("[AppDelegate] Reset to default storage location", category: .app)
            return true

        default:
            // Quit
            Log.info("[AppDelegate] User chose to quit", category: .app)
            NSApp.terminate(nil)
            return false
        }
    }

    /// Shows folder picker for selecting database location
    /// Returns the selected path if valid, nil if cancelled or invalid
    @MainActor
    private func browseForDatabaseFolder(startingAt directory: String?) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for the Retrace database"
        panel.prompt = "Select"

        // Open at the specified directory if it exists
        if let dir = directory, FileManager.default.fileExists(atPath: dir) {
            panel.directoryURL = URL(fileURLWithPath: dir)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        let selectedPath = url.path
        let validationResult = await validateRetraceFolderSelection(at: selectedPath)

        switch validationResult {
        case .valid:
            return selectedPath

        case .missingChunks:
            let alert = NSAlert()
            alert.messageText = "Missing Chunks Folder"
            alert.informativeText = "The selected folder has retrace.db but is missing the 'chunks' folder with video files.\n\nRetrace may not be able to load existing video frames.\n\nDo you want to continue anyway?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue Anyway")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() != .alertFirstButtonReturn {
                // User cancelled - let them pick again
                return await browseForDatabaseFolder(startingAt: directory)
            }
            return selectedPath

        case .invalidFolder:
            let alert = NSAlert()
            alert.messageText = "Invalid Folder Selection"
            alert.informativeText = "The selected folder contains other files but is not a valid Retrace database folder.\n\nPlease select either:\n• An existing Retrace folder (with retrace.db)\n• An empty folder for a new database"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Let them pick again
            return await browseForDatabaseFolder(startingAt: directory)

        case .invalidDatabase(let error):
            let alert = NSAlert()
            alert.messageText = "Invalid Retrace Database"
            alert.informativeText = error
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Let them pick again
            return await browseForDatabaseFolder(startingAt: directory)
        }
    }

    private enum RetraceFolderValidationResult: Sendable {
        case valid
        case missingChunks
        case invalidFolder
        case invalidDatabase(error: String)
    }

    private func validateRetraceFolderSelection(at selectedPath: String) async -> RetraceFolderValidationResult {
        await Task.detached(priority: .userInitiated) {
            Self.validateRetraceFolderSelectionSync(at: selectedPath)
        }.value
    }

    private static func validateRetraceFolderSelectionSync(at selectedPath: String) -> RetraceFolderValidationResult {
        let fm = FileManager.default
        let dbPath = "\(selectedPath)/retrace.db"
        let chunksPath = "\(selectedPath)/chunks"
        let hasDatabase = fm.fileExists(atPath: dbPath)
        let hasChunks = fm.fileExists(atPath: chunksPath)

        if hasDatabase {
            let verification = verifyRetraceDatabase(at: dbPath)
            guard verification.isValid else {
                return .invalidDatabase(error: verification.error ?? "The selected folder contains a retrace.db file that is not a valid Retrace database.")
            }
            return hasChunks ? .valid : .missingChunks
        }

        let contents = (try? fm.contentsOfDirectory(atPath: selectedPath)) ?? []
        let visibleContents = contents.filter { !$0.hasPrefix(".") }
        return visibleContents.isEmpty ? .valid : .invalidFolder
    }

    /// Verifies that a file is a valid Retrace database (unencrypted SQLite with expected tables)
    private static func verifyRetraceDatabase(at path: String) -> (isValid: Bool, error: String?) {
        var db: OpaquePointer?

        // Try to open the database
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            return (false, "Failed to open database: \(errorMsg)")
        }

        // Verify we can read from sqlite_master (confirms it's a valid SQLite database)
        var testStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK,
              sqlite3_step(testStmt) == SQLITE_ROW else {
            sqlite3_finalize(testStmt)
            sqlite3_close(db)
            return (false, "File is not a valid SQLite database.")
        }
        sqlite3_finalize(testStmt)

        // Check for Retrace-specific tables (frame, segment, video)
        let requiredTables = ["frame", "segment", "video"]
        for table in requiredTables {
            var stmt: OpaquePointer?
            let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='\(table)'"
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else {
                sqlite3_finalize(stmt)
                sqlite3_close(db)
                return (false, "Database is missing required '\(table)' table. This may not be a Retrace database.")
            }
            sqlite3_finalize(stmt)
        }

        sqlite3_close(db)
        return (true, nil)
    }

    // MARK: - Sleep/Wake Handling

    private func setupSleepWakeObservers() {
        guard sleepWakeObservers.isEmpty else {
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSystemSleep()
            }
        }
        sleepWakeObservers.append(sleepObserver)

        let wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSystemWake()
            }
        }
        sleepWakeObservers.append(wakeObserver)

        // Power source change detection - coalesced with sleep/wake observers
        // NSWorkspace doesn't have a direct power change notification, but we can:
        // 1. Check power state on wake (covers most plug/unplug during sleep)
        // 2. Use IOKit's power source notification for real-time detection
        setupPowerSourceMonitoring()

        Log.info("[AppDelegate] Sleep/wake observers registered", category: .app)
    }

    /// Setup IOKit-based power source monitoring for AC/battery changes
    private func setupPowerSourceMonitoring() {
        guard powerSourceRunLoopSource == nil else {
            return
        }

        // Create a run loop source for power source notifications
        let context = Unmanaged.passUnretained(self).toOpaque()

        if let runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                await delegate.handlePowerSourceChange()
            }
        }, context)?.takeRetainedValue() {
            powerSourceRunLoopSource = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            let initialSource = PowerStateMonitor.shared.getCurrentPowerSource()
            lastKnownPowerSource = initialSource
            Log.info("[AppDelegate] Power source monitoring registered (initial: \(initialSource))", category: .app)
        }
    }

    @MainActor
    private func handlePowerSourceChange() async {
        guard coordinatorWrapper != nil else { return }

        let newSource = PowerStateMonitor.shared.getCurrentPowerSource()
        if let lastKnownPowerSource, lastKnownPowerSource == newSource {
            return
        }
        lastKnownPowerSource = newSource

        Log.info("[AppDelegate] Power source changed to: \(newSource)", category: .app)
        schedulePowerSettingsApply()

        // Notify UI to update power status display
        NotificationCenter.default.post(name: NSNotification.Name("PowerSourceDidChange"), object: newSource)
    }

    @MainActor
    private func schedulePowerSettingsApply() {
        powerSettingsApplyTask?.cancel()
        powerSettingsApplyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }

            guard let self, let wrapper = self.coordinatorWrapper else { return }
            await wrapper.coordinator.applyPowerSettings()
            self.powerSettingsApplyTask = nil
        }
    }

    /// Setup observer for power settings changes from Settings UI
    private func setupPowerSettingsObserver() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PowerSettingsDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let wrapper = self?.coordinatorWrapper else { return }
                Log.info("[AppDelegate] Power settings changed, applying...", category: .app)
                await wrapper.coordinator.applyPowerSettings()
            }
        }
    }

    @MainActor
    private func handleSystemSleep() async {
        guard let wrapper = coordinatorWrapper else { return }
        guard !isHandlingSystemSleep else { return }
        isHandlingSystemSleep = true
        defer { isHandlingSystemSleep = false }

        wasRecordingBeforeSleep = await wrapper.coordinator.isCapturing()

        if wasRecordingBeforeSleep {
            Log.info("[AppDelegate] System going to sleep - stopping pipeline to finalize current segment", category: .app)
            do {
                try await wrapper.coordinator.stopPipeline(persistState: false)
            } catch {
                Log.error("[AppDelegate] Failed to stop pipeline on sleep: \(error)", category: .app)
            }
        }
    }

    @MainActor
    private func handleSystemWake() async {
        guard let wrapper = coordinatorWrapper else { return }
        guard !isHandlingSystemWake else { return }
        guard wasRecordingBeforeSleep else { return }
        isHandlingSystemWake = true
        wasRecordingBeforeSleep = false
        defer { isHandlingSystemWake = false }

        if await wrapper.coordinator.isCapturing() {
            await wrapper.refreshStatus()
            return
        }

        Log.info("[AppDelegate] System woke from sleep - resuming pipeline", category: .app)
        do {
            try await wrapper.coordinator.startPipeline()
            await wrapper.refreshStatus()
        } catch {
            Log.error("[AppDelegate] Failed to resume pipeline on wake: \(error)", category: .app)
        }
    }

    // MARK: - Recording Control

    func toggleRecording() async throws {
        guard let wrapper = coordinatorWrapper else { return }
        let isCapturing = await wrapper.coordinator.isCapturing()
        if isCapturing {
            try await wrapper.stopPipeline()
        } else {
            try await wrapper.startPipeline()
        }
    }

    // MARK: - Single Instance Check

    private func isAnotherInstanceRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        let myPID = ProcessInfo.processInfo.processIdentifier

        let retraceApps = runningApps.filter { app in
            let isRetrace = app.bundleIdentifier?.contains("retrace") == true ||
                           app.localizedName?.contains("Retrace") == true
            return isRetrace && app.processIdentifier != myPID
        }

        return !retraceApps.isEmpty
    }

    private func activateExistingInstance() {
        let runningApps = NSWorkspace.shared.runningApplications
        if let existingApp = runningApps.first(where: { app in
            (app.bundleIdentifier?.contains("retrace") == true ||
             app.localizedName?.contains("Retrace") == true) &&
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) {
            Log.info("[LaunchSurface] Forwarding duplicate launch to existing instance pid=\(existingApp.processIdentifier) hidden=\(existingApp.isHidden) active=\(existingApp.isActive)", category: .app)
            existingApp.activate(options: .activateIgnoringOtherApps)
            DistributedNotificationCenter.default().postNotificationName(
                Self.externalDashboardRevealNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            Log.info("[LaunchSurface] Posted external dashboard reveal notification", category: .app)
        } else {
            Log.warning("[LaunchSurface] Duplicate launch detected but no existing instance was found", category: .app)
        }
    }

    @MainActor
    private func requestDashboardReveal(source: String) {
        if isInitialized {
            Log.info("[LaunchSurface] requestDashboardReveal source=\(source) before state=\(launchSurfaceStateSnapshot())", category: .app)

            let wasHidden = NSApp.isHidden
            if wasHidden {
                Log.info("[LaunchSurface] Unhiding app before reveal source=\(source)", category: .app)
                NSApp.unhide(nil)
            }

            let dashboard = DashboardWindowController.shared
            if dashboard.isVisible {
                dashboard.bringToFront()
                Log.info("[LaunchSurface] Brought dashboard to front source=\(source) appWasHidden=\(wasHidden) after state=\(launchSurfaceStateSnapshot())", category: .app)
            } else {
                dashboard.show()
                Log.info("[LaunchSurface] Called dashboard.show source=\(source) appWasHidden=\(wasHidden) after state=\(launchSurfaceStateSnapshot())", category: .app)
            }
        } else {
            shouldShowDashboardAfterInitialization = true
            Log.info("[LaunchSurface] Queued dashboard reveal until initialization source=\(source) state=\(launchSurfaceStateSnapshot())", category: .app)
        }
    }

    private func setupExternalDashboardRevealObserver() {
        Log.info("[LaunchSurface] Registering external dashboard reveal observer", category: .app)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalDashboardRevealNotification(_:)),
            name: Self.externalDashboardRevealNotification,
            object: nil
        )
    }

    @objc private func handleExternalDashboardRevealNotification(_ notification: Notification) {
        Task { @MainActor in
            Log.info("[LaunchSurface] Received external dashboard reveal notification state=\(launchSurfaceStateSnapshot())", category: .app)
            requestDashboardReveal(source: "externalDashboardRevealNotification")
        }
    }

    @MainActor
    private func launchSurfaceStateSnapshot() -> String {
        let dashboard = DashboardWindowController.shared
        let window = dashboard.window
        let windowVisible = window?.isVisible ?? false
        let windowKey = window?.isKeyWindow ?? false
        let windowMini = window?.isMiniaturized ?? false
        let windowMain = window?.isMainWindow ?? false

        return "initialized=\(isInitialized) appHidden=\(NSApp.isHidden) appActive=\(NSApp.isActive) dashboardVisible=\(dashboard.isVisible) windowVisible=\(windowVisible) windowKey=\(windowKey) windowMain=\(windowMain) windowMini=\(windowMini)"
    }

    @MainActor
    private func shouldRevealDashboardForActivation() -> Bool {
        guard isInitialized else { return false }
        guard !TimelineWindowController.shared.isVisible else { return false }
        guard !DashboardWindowController.shared.isVisible else { return false }

        let hasVisibleForegroundWindow = NSApp.windows.contains { window in
            window.level.rawValue == 0 && window.isVisible
        }
        return !hasVisibleForegroundWindow
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers {
            workspaceCenter.removeObserver(observer)
        }
        sleepWakeObservers.removeAll()
        powerSettingsApplyTask?.cancel()
        powerSettingsApplyTask = nil
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            self.powerSourceRunLoopSource = nil
        }
        DistributedNotificationCenter.default().removeObserver(self)

        Log.info("[AppDelegate] Application terminating", category: .app)
    }

    // MARK: - URL Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        Log.info("[AppDelegate] Received URLs: \(urls), isInitialized: \(isInitialized)", category: .app)
        for url in urls {
            if isInitialized {
                Task { @MainActor in
                    self.handleDeeplink(url)
                }
            } else {
                // Queue the URL to be processed after initialization
                Log.info("[AppDelegate] Queuing deeplink for later: \(url)", category: .app)
                pendingDeeplinkURLs.append(url)
            }
        }
    }

    @MainActor
    private func handleDeeplink(_ url: URL) {
        guard let route = DeeplinkHandler.route(for: url) else {
            return
        }

        switch route {
        case let .timeline(timestamp):
            Log.info("[AppDelegate] Opening timeline deeplink at timestamp: \(String(describing: timestamp))", category: .app)
            if let timestamp {
                TimelineWindowController.shared.showAndNavigate(to: timestamp)
            } else {
                TimelineWindowController.shared.show()
            }

        case let .search(query, timestamp, appBundleID):
            Log.info("[AppDelegate] Opening search deeplink: query=\(query ?? "nil"), timestamp=\(String(describing: timestamp)), app=\(appBundleID ?? "nil")", category: .app)
            TimelineWindowController.shared.showSearch(
                query: query,
                timestamp: timestamp,
                appBundleID: appBundleID,
                source: "AppDelegate.openURLs"
            )
        }
    }

    /// Process a dev deeplink URL from environment for local interactive testing.
    /// Example:
    /// RETRACE_DEV_DEEPLINK_URL='retrace://search?q=test&app=com.google.Chrome&t=1704067200000' swift run Retrace
    @MainActor
    private func processDevDeeplinkFromEnvironment() -> Bool {
        guard let rawValue = ProcessInfo.processInfo.environment[Self.devDeeplinkEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return false
        }

        guard let url = URL(string: rawValue) else {
            Log.warning("[AppDelegate] Ignoring invalid \(Self.devDeeplinkEnvKey): \(rawValue)", category: .app)
            return false
        }

        Log.info("[AppDelegate] Processing dev deeplink from env: \(url)", category: .app)
        handleDeeplink(url)
        return true
    }

    // MARK: - Permissions

    private func requestPermissions() {
        // Request screen recording permission
        // This will show a system dialog on first run
        CGRequestScreenCaptureAccess()

        // Request accessibility permission
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Appearance

    private func configureAppearance() {
        // Force dark mode - the app UI is designed for dark theme
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

// MARK: - URL Handling

extension RetraceApp {
    /// Handle URL scheme: retrace://
    func onOpenURL(_ url: URL) {
        Log.info("[RetraceApp] Handling URL: \(url)", category: .app)
        // URL handling is done in ContentView via .onOpenURL
    }
}
