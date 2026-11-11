import Foundation
import Shared
import Database
import Storage
import Capture
import Processing
import Search
import Migration
import SQLCipher

/// Dependency injection container for all app services
/// Owner: APP integration
public actor ServiceContainer {

    // MARK: - Services

    public let database: DatabaseManager
    public let audioHistory: AudioHistoryOwner
    public let ftsEngine: FTSManager
    public let storage: StorageManager
    public let capture: CaptureManager
    public let audioCapture: AudioCaptureManager
    public let processing: ProcessingManager
    public let resourceUsage: ResourceUsageMonitor
    public let storageUsage: StorageUsageService
    public let backgroundProcessing: BackgroundProcessingGovernor
    public let audioProcessing: AudioProcessingManager
    public let dictation: DictationManager
    public let search: SearchManager
    public let localRecall: LocalRecallController
    public let jobs: JobIntegration
    public let migration: MigrationManager
    public let modelManager: ModelManager
    nonisolated public let onboardingManager: OnboardingManager
    public let retentionManager: RetentionManager
    public var dataAdapter: DataAdapter?
    public var processingQueue: FrameProcessingQueue?
    public var audioBackfill: AudioBackfillManager?
    public var audioRefinement: AudioRefinementManager?
    public var audioContextualRefinement: AudioContextualRefinementManager?
    private var transcriptionService: (any TranscriptionProtocol)?
    private var chunkMedia: AudioChunkMediaStore?
    private var audioPlaybackOwner: AudioMediaPlaybackOwner?

    // MARK: - Configuration

    private let databasePath: String
    private let storageConfig: StorageConfig
    private let captureConfig: CaptureConfig
    private let audioCaptureConfig: AudioCaptureConfig
    private let processingConfig: ProcessingConfig
    private let audioProcessingConfig: AudioProcessingConfig
    private let searchConfig: SearchConfig

    private var isInitialized = false
    private var servicesShutdownRequested = false
    private var localContextOwner: LocalContextService?
    private var localContextClosing = false
    private let initializationLifecycle = RecordingLifecycle()

    #if DEBUG
    // Owned test initialization opens only its private SQLite writer. The hook
    // replaces unrelated native/audio/storage setup, not policy ownership.
    private var initializationRequestForTesting: (@Sendable () -> Void)?
    private var initializationRemainderForTesting: (@Sendable () async throws -> Void)?
    private var shutdownRequestForTesting: (@Sendable () -> Void)?
    private var beforeDatabaseCloseForTesting: (@Sendable () async throws -> Void)?

    func setInitializationBoundaryForTesting(request: (@Sendable () -> Void)? = nil,
        shutdownRequest: (@Sendable () -> Void)? = nil,
        remainder: @escaping @Sendable () async throws -> Void) {
        initializationRequestForTesting = request
        shutdownRequestForTesting = shutdownRequest
        initializationRemainderForTesting = remainder
    }

    func setBeforeDatabaseCloseForTesting(_ receipt: @escaping @Sendable () async throws -> Void) {
        beforeDatabaseCloseForTesting = receipt
    }
    func audioChunkMediaForTesting() async throws -> any AudioChunkMediaStoreProtocol {
        try await audioChunkMediaStore()
    }
    #endif

    // MARK: - Initialization

    public init(
        databasePath: String = AppPaths.databasePath,
        storageConfig: StorageConfig = .default,
        captureConfig: CaptureConfig = .default,
        audioCaptureConfig: AudioCaptureConfig = .default,
        processingConfig: ProcessingConfig = .default,
        audioProcessingConfig: AudioProcessingConfig = .default,
        searchConfig: SearchConfig = .default,
        jobObservationConfig: JobObservationConfig = .default
    ) {
        let resourceUsage = ResourceUsageMonitor()
        self.resourceUsage = resourceUsage
        let backgroundProcessing = BackgroundProcessingGovernor(resourceUsage: resourceUsage)
        self.backgroundProcessing = backgroundProcessing
        self.databasePath = databasePath
        self.storageConfig = storageConfig
        self.captureConfig = captureConfig
        self.audioCaptureConfig = audioCaptureConfig
        self.processingConfig = processingConfig
        self.searchConfig = searchConfig

        // Initialize all managers
        self.database = DatabaseManager(databasePath: databasePath)
        self.audioHistory = AudioHistoryOwner(factory: { [database] in
            try await database.makeAudioEvidenceStore()
        })
        self.ftsEngine = FTSManager(databasePath: databasePath)
        // Use the correct storage root (respects custom path setting)
        let storageRootURL = URL(fileURLWithPath: NSString(string: storageConfig.storageRootPath).expandingTildeInPath, isDirectory: true)
        self.storage = StorageManager(storageRoot: storageRootURL)
        self.storageUsage = StorageUsageService(
            roots: StorageUsageService.roots(native: storageRootURL,
                includeRelatedLibraries: storageRootURL.path == AppPaths.expandedStorageRoot),
            resources: resourceUsage)
        self.localRecall = LocalRecallController(database: database,
            cacheRoot: storageRootURL.appendingPathComponent("model-cache/semantic", isDirectory: true),
            governor: backgroundProcessing,
            acknowledgeConfiguration: { selected in
                let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
                if let selected { defaults.set(selected.path, forKey: LocalRecallSettings.modelPackagePathKey) }
                else { defaults.removeObject(forKey: LocalRecallSettings.modelPackagePathKey) }
            })
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let configuredJobs = defaults.object(forKey: JobIntegration.defaultsKey) == nil ? jobObservationConfig :
            JobObservationConfig(enabled: defaults.bool(forKey: JobIntegration.defaultsKey))
        let jobOwner = JobIntegration(store: database, configuration: configuredJobs, metric: { [database] action in
            try? await database.recordMetricEvent(metricType: .jobEvent, metadata: JobIntegration.metricMetadata(action))
        })
        self.jobs = jobOwner
        let captureOwner = CaptureManager(config: captureConfig,
            configurationAdmission: ScreenEvidenceAdmissionCoordinator(database: database, jobs: jobOwner), groupJournal: database)
        self.capture = captureOwner
        let configuredAudio = defaults.object(forKey: MeetingIntegration.defaultsKey) == nil ? audioCaptureConfig :
            audioCaptureConfig.withMeetingEvidenceComparisonEnabled(defaults.bool(forKey: MeetingIntegration.defaultsKey))
        let audioOwner = AudioCaptureManager(config: configuredAudio,
            meetingCaptureConfig: { await captureOwner.meetingCapturePolicySnapshot() })
        self.audioCapture = audioOwner
        var selectedAudioProcessingConfig = audioProcessingConfig
        if defaults.object(forKey: "chunkedAudioCaptureCandidateEnabled") != nil {
            selectedAudioProcessingConfig.chunkedAudioEnabled = defaults.bool(forKey: "chunkedAudioCaptureCandidateEnabled")
        }
        let linkedAudioProcessingConfig = MeetingIntegration.processingConfiguration(selectedAudioProcessingConfig, audio: audioOwner)
        self.audioProcessingConfig = linkedAudioProcessingConfig
        self.processing = ProcessingManager(config: processingConfig)

        // Audio processing: load model path from config or use default
        let modelPath = WhisperConfigLoader.getModelPath()
        if WhisperConfigLoader.loadConfig() != nil {
            Log.info("Using whisper.cpp config from: \(WhisperConfigLoader.defaultConfigPath)", category: .app)
            Log.info("Model: \(modelPath)", category: .app)
            if WhisperConfigLoader.isCoreMLEnabled() {
                Log.info("CoreML acceleration: enabled", category: .app)
            }
        } else {
            Log.warning("whisper_config.json not found, using default model path", category: .app)
            Log.info("Model: \(modelPath)", category: .app)
        }

        // Use real transcription service if model exists, otherwise mock.
        // The whisper.cpp dylib is built with Metal-only (no CoreML) so no companion model is needed.
        let transcriptionService: any TranscriptionProtocol
        let expandedModelPath = NSString(string: modelPath).expandingTildeInPath
        let modelExists = FileManager.default.fileExists(atPath: expandedModelPath)

        if modelExists {
            transcriptionService = WhisperCppTranscriptionService(
                modelPath: modelPath
            )
        } else {
            Log.warning("Whisper model not found at \(expandedModelPath), using mock transcription service (audio will be recorded but not transcribed)", category: .app)
            transcriptionService = MockTranscriptionService()
        }

        // Audio storage writer
        let audioWriter = AudioSegmentWriter(storageRoot: storageRootURL)

        // Store transcription service for backfill manager
        self.transcriptionService = transcriptionService

        self.audioProcessing = AudioProcessingManager(
            transcriptionService: transcriptionService,
            transcriptionQueries: nil,  // Set during initialization
            audioWriter: audioWriter,
            config: linkedAudioProcessingConfig,
            governor: backgroundProcessing
        )
        self.dictation = DictationManager(transcriptionService: transcriptionService)

        // FTS-only search manager
        self.search = SearchManager(
            database: database,
            ftsEngine: ftsEngine
        )

        // Migration depends on database and processing
        self.migration = MigrationManager(
            database: database,
            processing: processing
        )

        // Model and onboarding managers
        self.modelManager = ModelManager()
        self.onboardingManager = OnboardingManager()

        // Retention manager for data cleanup
        self.retentionManager = RetentionManager(
            database: database,
            storage: storage,
            search: search
        )

        Log.info("ServiceContainer created", category: .app)
    }

    /// Convenience initializer for in-memory/testing
    public init(inMemory: Bool) {
        // This unique URI keeps tests off disk. Tests needing the same writer
        // inject its connection; bundled SQLCipher may omit shared-cache support.
        let sharedMemoryPath = "file:memdb_test_\(UUID().uuidString)?mode=memory&cache=shared"
        let testStorageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace-services-\(UUID().uuidString)", isDirectory: true)
        self.resourceUsage = ResourceUsageMonitor()
        self.backgroundProcessing = BackgroundProcessingGovernor(observeSystem: false)
        self.databasePath = sharedMemoryPath
        self.storageConfig = StorageConfig(storageRootPath: testStorageRoot.path)
        self.captureConfig = CaptureConfig()
        self.audioCaptureConfig = .default
        self.processingConfig = .default
        self.searchConfig = .default

        self.database = DatabaseManager(databasePath: sharedMemoryPath)
        self.audioHistory = AudioHistoryOwner(factory: { [database] in
            try await database.makeAudioEvidenceStore()
        })
        self.ftsEngine = FTSManager(databasePath: sharedMemoryPath)
        self.storage = StorageManager(storageRoot: testStorageRoot)
        self.storageUsage = StorageUsageService(
            roots: [.init(id: "native", url: testStorageRoot.resolvingSymlinksInPath(), classifyNativeLibrary: true)],
            resources: resourceUsage)
        self.localRecall = LocalRecallController(database: database,
            cacheRoot: testStorageRoot.appendingPathComponent("model-cache/semantic", isDirectory: true))
        // Private in-memory fixtures never inherit a live user's opt-in setting.
        let jobOwner = JobIntegration(store: database, metric: { [database] action in
            try? await database.recordMetricEvent(metricType: .jobEvent, metadata: JobIntegration.metricMetadata(action))
        })
        self.jobs = jobOwner
        let captureOwner = CaptureManager(config: captureConfig,
            configurationAdmission: ScreenEvidenceAdmissionCoordinator(database: database, jobs: jobOwner), groupJournal: database)
        self.capture = captureOwner
        let audioOwner = AudioCaptureManager(meetingCaptureConfig: { await captureOwner.meetingCapturePolicySnapshot() })
        self.audioCapture = audioOwner
        let linkedAudioProcessingConfig = MeetingIntegration.processingConfiguration(.default, audio: audioOwner)
        self.audioProcessingConfig = linkedAudioProcessingConfig
        self.processing = ProcessingManager()

        // Use mock transcription service in test mode to avoid loading heavy Whisper model
        let transcriptionService: any TranscriptionProtocol = MockTranscriptionService()
        self.transcriptionService = transcriptionService
        let audioWriter = AudioSegmentWriter(storageRoot: testStorageRoot)
        self.audioProcessing = AudioProcessingManager(
            transcriptionService: transcriptionService,
            transcriptionQueries: nil,  // Set during initialization
            audioWriter: audioWriter,
            config: linkedAudioProcessingConfig
        )
        self.dictation = DictationManager(transcriptionService: transcriptionService)

        // FTS-only search manager
        self.search = SearchManager(
            database: database,
            ftsEngine: ftsEngine
        )

        self.migration = MigrationManager(
            database: database,
            processing: processing
        )

        // Model and onboarding managers
        self.modelManager = ModelManager(modelsDirectory: testStorageRoot.appendingPathComponent("models"))
        self.onboardingManager = OnboardingManager()

        // Retention manager for data cleanup
        self.retentionManager = RetentionManager(
            database: database,
            storage: storage,
            search: search
        )

        Log.info("ServiceContainer created (in-memory mode)", category: .app)
    }

    // MARK: - Lifecycle

    /// Initialize all services in the correct order
    public func initialize() async throws {
        #if DEBUG
        initializationRequestForTesting?()
        #endif
        // Every caller crosses the terminal fence, including an already-open
        // container. Duplicate requests join the same owning startup task.
        try await initializationLifecycle.start(operation: { [self] in
            try await initializeServices()
        }, rollback: { [self] in
            // A cancelled startup still owns cleanup. Its rollback must not
            // inherit cancellation at a late native/database boundary.
            try await Task { try await self.shutdownServices() }.value
        })
    }

    private func initializeServices() async throws {
        try Task.checkCancellation()
        guard !servicesShutdownRequested else { throw RecordingLifecycleError.shuttingDown }
        try await backgroundProcessing.reopenAfterJoinedClose()
        try await audioHistory.reopenAfterJoinedClose()
        try await jobs.reopenAfterJoinedClose()
        try await localRecall.reopenAfterJoinedClose()
        try Task.checkCancellation()
        guard !servicesShutdownRequested else { throw RecordingLifecycleError.shuttingDown }
        localContextClosing = false
        guard !isInitialized else {
            Log.warning("ServiceContainer already initialized", category: .app)
            return
        }

        Log.info("Initializing all services...", category: .app)

        // 1. Initialize database first (creates schema)
        try await database.initialize()
        try Task.checkCancellation()
        Log.info("✓ Database initialized", category: .app)

        // Historical evidence has an owning policy even while recording is
        // paused. Install it before any remaining service can claim derived work.
        try await capture.initializeConfigurationAdmission()
        try Task.checkCancellation()
        await audioCapture.setMeetingOutcomeHandler { [database] outcome in
            await MeetingIntegration.record(outcome, database: database)
        }

        #if DEBUG
        if let initializationRemainderForTesting {
            try await initializationRemainderForTesting()
            try Task.checkCancellation()
            isInitialized = true
            return
        }
        #endif

        await resourceUsage.start { [database] minute in
            do { try await database.recordResourceUsageMinute(minute) }
            catch { Log.warning("Resource usage aggregate could not be saved", category: .app) }
        }
        await storageUsage.start()
        try? await database.recordMetricEvent(metricType: .storageUsage,
                                             metadata: "{\"action\":\"periodicStarted\"}")

        // 2. Initialize FTS engine (shares same database)
        try await ftsEngine.initialize()
        try Task.checkCancellation()
        Log.info("✓ FTS engine initialized", category: .app)

        // 3. Initialize storage (creates directories, loads encryption key)
        try await storage.initialize(config: storageConfig)
        try Task.checkCancellation()
        Log.info("✓ Storage initialized", category: .app)

        // DIAGNOSTIC: Log critical paths for troubleshooting database/storage mismatches
        Log.info("=== Storage Configuration ===", category: .app)
        Log.info("Storage Root: \(AppPaths.storageRoot)", category: .app)
        Log.info("Expanded Root: \(AppPaths.expandedStorageRoot)", category: .app)
        Log.info("Database Path: \(AppPaths.databasePath)", category: .app)
        let fm = FileManager.default
        let chunksPath = "\(AppPaths.expandedStorageRoot)/chunks"
        let dbPath = NSString(string: AppPaths.databasePath).expandingTildeInPath
        Log.info("Database exists: \(fm.fileExists(atPath: dbPath))", category: .app)
        Log.info("Chunks folder exists: \(fm.fileExists(atPath: chunksPath))", category: .app)

        // SAFETY: If database exists but chunks folder is missing, clear processing queue
        // This prevents infinite retry loops from orphaned frame records
        if fm.fileExists(atPath: dbPath) && !fm.fileExists(atPath: chunksPath) {
            Log.error("⚠️ CRITICAL: Database exists but chunks folder missing!", category: .app)
            Log.warning("Clearing processing queue to prevent failures...", category: .app)

            // Clear processing queue - frames can't be processed without video files
            // Note: WAL is relative to storageRoot so it's already at the correct location
            try await database.clearProcessingQueue()

            Log.info("✓ Cleared processing queue (frames have no video files)", category: .app)
        }
        Log.info("============================", category: .app)

        // 4. Initialize processing (sets config)
        try await processing.initialize(config: processingConfig)
        try Task.checkCancellation()
        Log.info("✓ Processing initialized", category: .app)

        // 5. Initialize audio processing (loads whisper.cpp model and connects to database)
        do {
            guard let audioDbPointer = await database.getConnection() else {
                throw ServiceError.databaseNotReady
            }
            let audioTranscriptionQueries = AudioTranscriptionQueries(db: audioDbPointer)
            let dictationSessionQueries = DictationSessionQueries(db: audioDbPointer)
            let audioStorageRoot = await storage.getStorageDirectory()
            let audioWriter = AudioSegmentWriter(storageRoot: audioStorageRoot)
            let chunkMedia = try await audioChunkMediaStore()
            await audioProcessing.setChunkMediaStore(chunkMedia)
            try await audioProcessing.initialize(
                transcriptionQueries: audioTranscriptionQueries,
                audioWriter: audioWriter
            )
            await dictation.updateSessionStore(dictationSessionQueries)
            Log.info("✓ Audio processing initialized", category: .app)

            // Create backfill manager only if real whisper service is available
            if let service = self.transcriptionService, !(service is MockTranscriptionService) {
                self.audioBackfill = AudioBackfillManager(
                    transcriptionService: service,
                    transcriptionQueries: audioTranscriptionQueries,
                    audioWriter: audioWriter,
                    storageRoot: audioStorageRoot,
                    governor: backgroundProcessing
                )
                await self.audioBackfill?.setChunkMediaStore(chunkMedia)
                Log.info("✓ Audio backfill manager initialized", category: .app)
            }

            _ = try await installAudioRefinementManagersIfAvailable()
        } catch {
            Log.warning("Audio processing initialization failed (will record without transcription): \(error)", category: .app)
        }
        try Task.checkCancellation()

        // 6. Initialize search manager
        try await search.initialize(config: searchConfig)
        try Task.checkCancellation()
        Log.info("✓ Search initialized", category: .app)

        // 7. Initialize processing queue (workers started after full initialization)
        let queue = FrameProcessingQueue(
            database: database,
            storage: storage,
            processing: processing,
            search: search,
            config: .default,
            extractionCommitted: { [localRecall] in await localRecall.refresh() },
            governor: backgroundProcessing
        )
        self.processingQueue = queue
        Log.info("✓ Processing queue initialized", category: .app)

        // 8. Migration doesn't need explicit initialization
        Log.info("✓ Migration ready", category: .app)

        // 9. Initialize DataAdapter with connections directly
        // Create connections and config for Retrace
        let retraceConnection = try await database.makeRecallReadConnection()
        let retraceConfig = DatabaseConfig(dateFormatter: nil,
            storageRoot: await storage.getStorageDirectory().path, source: .native, cutoffDate: nil)
        let retraceImageExtractor = HEVCStorageExtractor(storageManager: storage)

        let adapter = DataAdapter(
            retraceConnection: retraceConnection,
            retraceConfig: retraceConfig,
            retraceImageExtractor: retraceImageExtractor,
            database: database
        )

        // Register Rewind source if user opted in
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let useRewindData = defaults.bool(forKey: "useRewindData")
        Log.info("Checking Rewind source during initialization: useRewindData=\(useRewindData)", category: .app)

        if useRewindData {
            await configureRewindSource(adapter: adapter)
        } else {
            Log.info("⊘ Rewind source not registered during initialization (useRewindData is false)", category: .app)
        }

        // Initialize the adapter
        try await adapter.initialize()
        self.dataAdapter = adapter
        try Task.checkCancellation()
        Log.info("✓ DataAdapter initialized", category: .app)

        // Optional local meaning search has independent readiness. A missing or
        // altered package leaves lexical search usable and clears its saved opt-in.
        if let modelPath = defaults.string(forKey: LocalRecallSettings.modelPackagePathKey),
           !modelPath.isEmpty {
            do { try await localRecall.configure(modelPackageURL: URL(fileURLWithPath: modelPath)) }
            catch is CancellationError { throw CancellationError() }
            catch { Log.warning("Local meaning search is unavailable", category: .search) }
            try Task.checkCancellation()
        }

        // 10. Start retention manager (runs periodic cleanup based on user settings)
        await retentionManager.start()
        try Task.checkCancellation()
        Log.info("✓ Retention manager started", category: .app)

        // Capture is initialized when startCapture() is called

        isInitialized = true
        try? await database.recordMetricEvent(metricType: .backgroundProcessing, metadata: "{\"action\":\"automaticPolicyStarted\"}")
        Log.info("All services initialized successfully", category: .app)

        // AppCoordinator starts workers after WAL/interrupted-claim recovery.
        // Starting here lets recovery mistake this process's live claims for
        // interrupted work and reset them while OCR is still running.
    }

    /// Install pass-2/pass-3 audio refinement managers once the turbo Whisper model is available.
    /// This is idempotent so startup and post-download installation use the same path.
    @discardableResult
    public func installAudioRefinementManagersIfAvailable() async throws -> Bool {
        guard audioRefinement == nil || audioContextualRefinement == nil else {
            return true
        }

        guard let turboPath = await modelManager.getWhisperTurboModelPath() else {
            return false
        }

        guard let audioDbPointer = await database.getConnection() else {
            throw ServiceError.databaseNotReady
        }

        let audioTranscriptionQueries = AudioTranscriptionQueries(db: audioDbPointer)
        let audioStorageRoot = await storage.getStorageDirectory()
        let audioWriter = AudioSegmentWriter(storageRoot: audioStorageRoot)
        let turboNativeService = WhisperCppTranscriptionService(
            modelPath: turboPath.path,
            samplingStrategy: .beamSearch(beamSize: 5),
            modelResidency: .onDemand(idleTimeout: .seconds(45))
        )

        let turboService = BackgroundTranscriptionService(service: turboNativeService, governor: backgroundProcessing)

        if audioRefinement == nil {
            let refinement = AudioRefinementManager(
                transcriptionService: turboService,
                transcriptionQueries: audioTranscriptionQueries,
                audioWriter: audioWriter,
                storageRoot: audioStorageRoot
            )
            // The governor serializes native work; a recording-session flag would
            // block explicit refinement for the entire time recording is enabled.
            self.audioRefinement = refinement
            await refinement.setChunkMediaStore(try await audioChunkMediaStore())
            Log.info("✓ Audio refinement manager initialized (turbo model loads on demand)", category: .app)
        }

        if audioContextualRefinement == nil {
            self.audioContextualRefinement = AudioContextualRefinementManager(
                transcriptionService: turboService,
                transcriptionQueries: audioTranscriptionQueries,
                audioWriter: audioWriter,
                storageRoot: audioStorageRoot
            )
            await self.audioContextualRefinement?.setChunkMediaStore(try await audioChunkMediaStore())
            Log.info("✓ Audio contextual refinement manager initialized", category: .app)
        }

        return true
    }

    /// Register Rewind data source if user has opted in
    /// Can be called after initialization (e.g., after onboarding completes)
    public func registerRewindSourceIfEnabled() async throws {
        guard isInitialized else {
            Log.warning("Cannot register Rewind source - ServiceContainer not initialized", category: .app)
            return
        }

        guard let adapter = dataAdapter else {
            Log.warning("Cannot register Rewind source - DataAdapter not available", category: .app)
            return
        }

        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let useRewindData = defaults.bool(forKey: "useRewindData")
        Log.info("Checking if Rewind source should be registered: useRewindData=\(useRewindData)", category: .app)

        if useRewindData {
            // Check if already registered
            let sources = await adapter.registeredSources
            if sources.contains(.rewind) {
                Log.info("Rewind source already registered, skipping", category: .app)
                return
            }

            await configureRewindSource(adapter: adapter)
            Log.info("✓ Rewind source registered and connected after initialization", category: .app)
        } else {
            Log.info("⊘ Rewind source not registered (useRewindData is false)", category: .app)
        }
    }

    /// Set Rewind data source enabled/disabled and update connection accordingly
    /// - Parameter enabled: Whether to connect or disconnect Rewind data
    public func setRewindSourceEnabled(_ enabled: Bool) async {
        guard isInitialized else {
            Log.warning("Cannot change Rewind source - ServiceContainer not initialized", category: .app)
            return
        }

        guard let adapter = dataAdapter else {
            Log.warning("Cannot change Rewind source - DataAdapter not available", category: .app)
            return
        }

        // Save preference
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        defaults.set(enabled, forKey: "useRewindData")

        if enabled {
            // Connect Rewind source if not already connected
            let sources = await adapter.registeredSources
            if sources.contains(.rewind) {
                Log.info("Rewind source already connected", category: .app)
                return
            }
            await configureRewindSource(adapter: adapter)
            Log.info("✓ Rewind source connected", category: .app)
        } else {
            // Disconnect Rewind source
            await adapter.disconnectRewind()
            Log.info("✓ Rewind source disconnected", category: .app)
        }
    }

    /// Helper to configure Rewind source on DataAdapter
    private func configureRewindSource(adapter: DataAdapter) async {
        let rewindDBPath = NSString(string: AppPaths.rewindDBPath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: rewindDBPath) else {
            Log.warning("Rewind database not found at: \(rewindDBPath)", category: .app)
            return
        }

        // Open encrypted database in serialized mode for safe concurrent reads.
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(rewindDBPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            Log.error("[ServiceContainer] Failed to open Rewind database: \(errorMsg)", category: .app)
            return
        }

        // Set encryption key
        let rewindPassword = "soiZ58XZJhdka55hLUp18yOtTUTDXz7Diu7Z4JzuwhRwGG13N6Z9RTVU1fGiKkuF"
        let keySQL = "PRAGMA key = '\(rewindPassword)'"
        var keyError: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, keySQL, nil, nil, &keyError) != SQLITE_OK {
            let error = keyError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(keyError)
            Log.error("[ServiceContainer] Failed to set Rewind encryption key: \(error)", category: .app)
            sqlite3_close(db)
            return
        }

        // Set cipher compatibility (Rewind uses SQLCipher 4)
        var compatError: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, "PRAGMA cipher_compatibility = 4", nil, nil, &compatError) != SQLITE_OK {
            let error = compatError.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(compatError)
            Log.error("[ServiceContainer] Failed to set cipher compatibility: \(error)", category: .app)
            sqlite3_close(db)
            return
        }

        // Verify connection
        var testStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &testStmt, nil) == SQLITE_OK,
              sqlite3_step(testStmt) == SQLITE_ROW else {
            sqlite3_finalize(testStmt)
            sqlite3_close(db)
            Log.error("[ServiceContainer] Failed to verify Rewind encryption", category: .app)
            return
        }
        sqlite3_finalize(testStmt)

        // Create connection and config
        let rewindConnection = SQLCipherConnection(db: db)
        let rewindConfig = DatabaseConfig.rewind
        // Chunks directory is always in the same parent directory as the database
        let rewindDBDir = (rewindDBPath as NSString).deletingLastPathComponent
        let rewindChunksPath = "\(rewindDBDir)/chunks"
        let rewindImageExtractor = AVAssetExtractor(storageRoot: rewindChunksPath)
        let cutoffDate = Date(timeIntervalSince1970: 1766217600) // Dec 20, 2025 00:00:00 UTC

        await adapter.configureRewind(
            connection: rewindConnection,
            config: rewindConfig,
            imageExtractor: rewindImageExtractor,
            cutoffDate: cutoffDate
        )
        Log.info("✓ Rewind source configured during initialization", category: .app)
    }

    /// Upgrade from MockTranscriptionService to real WhisperCppTranscriptionService
    /// Called after whisper model is downloaded at runtime
    public func upgradeToRealTranscription() async throws {
        guard transcriptionService is MockTranscriptionService else {
            Log.info("[ServiceContainer] Already using real transcription service, skipping upgrade", category: .app)
            return
        }

        guard let modelURL = await modelManager.getWhisperModelPath() else {
            Log.warning("[ServiceContainer] Cannot upgrade transcription: whisper model not found", category: .app)
            return
        }

        let realService = WhisperCppTranscriptionService(modelPath: modelURL.path)
        try await realService.initialize()
        self.transcriptionService = realService

        // Hot-swap the service in the audio processing manager
        await audioProcessing.updateTranscriptionService(realService)
        await dictation.updateTranscriptionService(realService)
        Log.info("[ServiceContainer] Upgraded to real WhisperCppTranscriptionService", category: .app)

        // Create backfill manager if not already present
        if self.audioBackfill == nil {
            guard let audioDbPointer = await database.getConnection() else {
                Log.warning("[ServiceContainer] Cannot create backfill manager: database not ready", category: .app)
                return
            }
            let audioTranscriptionQueries = AudioTranscriptionQueries(db: audioDbPointer)
            let audioStorageRoot = await storage.getStorageDirectory()
            let audioWriter = AudioSegmentWriter(storageRoot: audioStorageRoot)
            self.audioBackfill = AudioBackfillManager(
                transcriptionService: realService,
                transcriptionQueries: audioTranscriptionQueries,
                audioWriter: audioWriter,
                storageRoot: audioStorageRoot,
                governor: backgroundProcessing
            )
            await self.audioBackfill?.setChunkMediaStore(try await audioChunkMediaStore())
            Log.info("[ServiceContainer] Audio backfill manager created after transcription upgrade", category: .app)
        }
    }

    /// Shutdown all services gracefully
    public func shutdown() async throws {
        servicesShutdownRequested = true
        localContextClosing = true
        await initializationLifecycle.beginShutdown()
        #if DEBUG
        shutdownRequestForTesting?()
        #endif
        await backgroundProcessing.cancelAutomaticWork()
        try await initializationLifecycle.stop(onRequest: { [self, capture, localRecall, jobs] in
            // Retire command observation and every callback before policy/writer teardown.
            try await jobs.shutdown()
            await stopLocalContext()
            await audioPlaybackOwner?.close()
            await audioHistory.close()
            // Fence query/start admission immediately, then join canonical claim
            // cleanup while its writer capability still exists. A failed cleanup
            // retains that owner and database for the joined teardown retry.
            try await localRecall.shutdown()
            try await capture.shutdownConfigurationAdmission()
        }, operation: { [self] in
            try await shutdownServices()
        })
    }

    private func shutdownServices() async throws {
        await backgroundProcessing.cancelAutomaticWork()
        localContextClosing = true
        await stopLocalContext()
        await audioPlaybackOwner?.close()
        await audioHistory.close()
        isInitialized = false
        var failures: [any Error] = []
        Log.info("Shutting down all services...", category: .app)

        var canCloseWriter = true
        do { try await jobs.shutdown() }
        catch { canCloseWriter = false; failures.append(error) }
        do { try await localRecall.shutdown() }
        catch { canCloseWriter = false; failures.append(error) }

        // Partial startup and paused recording still have an owning policy.
        if canCloseWriter {
            do { try await capture.shutdownConfigurationAdmission() }
            catch { failures.append(error) }
        }

        do { try await capture.stopCapture() }
        catch { failures.append(error) }
        if let error = await RecordingLifecycle.stopCapturedAudio(
            stopSource: { [audioCapture] in try await audioCapture.stopCapture() },
            finishInput: { [audioProcessing] in await audioProcessing.finishCapturedInput() }) {
            failures.append(error)
        }

        // Stop processing queue workers
        await processingQueue?.stopWorkers()
        processingQueue = nil
        Log.info("✓ Processing queue workers stopped", category: .app)

        // Wait for processing queue to drain (legacy OCR queue)
        await processing.waitForQueueDrain()
        Log.info("✓ Processing queue drained", category: .app)

        // Audio ingestion and held callbacks joined above, including a reported
        // native stop error, before the media store or writer can close.
        await chunkMedia?.close()
        chunkMedia = nil
        audioPlaybackOwner = nil
        audioBackfill = nil
        audioRefinement = nil
        audioContextualRefinement = nil
        await backgroundProcessing.close()
        await storageUsage.close()
        await resourceUsage.close()
        Log.info("✓ Audio processing drained", category: .app)

        // Stop retention manager
        await retentionManager.stop()
        Log.info("✓ Retention manager stopped", category: .app)

        // Release the container's adapter after shutting down its state.
        await dataAdapter?.shutdown()
        dataAdapter = nil
        Log.info("✓ DataAdapter shutdown", category: .app)

        // Close database connections
        if canCloseWriter {
            do { try await ftsEngine.close() }
            catch { failures.append(error) }
        #if DEBUG
        if let receipt = beforeDatabaseCloseForTesting {
            beforeDatabaseCloseForTesting = nil
            do { try await receipt() }
            catch { failures.append(error) }
        }
        #endif
            do { try await database.close() }
            catch { failures.append(error) }
        }

        if failures.count == 1 { throw failures[0] }
        if !failures.isEmpty { throw ServiceCleanupFailure(failures: failures) }
        Log.info("All services shutdown successfully", category: .app)
    }

    // MARK: - Service Access

    private func audioChunkMediaStore() async throws -> AudioChunkMediaStore {
        guard !localContextClosing, !servicesShutdownRequested else { throw AudioChunkMediaError.closed }
        if let chunkMedia { return chunkMedia }
        // The canonical actor validates its connection before reading the shared
        // native store UUID. Never retain a borrowed SQLite pointer across shutdown.
        let storeID = try await database.originalStoreID()
        let root = await storage.getStorageDirectory()
        guard !localContextClosing, !servicesShutdownRequested else { throw AudioChunkMediaError.closed }
        if let chunkMedia { return chunkMedia }
        let media = AudioChunkMediaStore(storageRoot: root, storeID: storeID)
        chunkMedia = media
        return media
    }

    public func acquireAudioPlayback(_ reference: AudioEvidenceRef) async throws -> AudioPlaybackLease {
        guard !localContextClosing else { throw AudioChunkMediaError.closed }
        let media = try await audioChunkMediaStore()
        guard !localContextClosing else { throw AudioChunkMediaError.closed }
        let owner: AudioMediaPlaybackOwner
        if let audioPlaybackOwner { owner = audioPlaybackOwner }
        else {
            owner = AudioMediaPlaybackOwner(evidence: audioHistory, media: media,
                configuration: { [capture] in await capture.getConfig() })
            audioPlaybackOwner = owner
        }
        return try await owner.acquire(reference)
    }

    public func invalidateAudioPlayback() async { await audioPlaybackOwner?.invalidate() }

    /// Lazy owner: no model or evidence work begins until a workspace request.
    public func localContextService(evidence: ProgressiveRecallService) throws -> LocalContextService {
        guard isInitialized, !localContextClosing else { throw LocalContextError.stopped }
        if let localContextOwner { return localContextOwner }
        let database = database
        let owner = LocalContextService(database: database, evidence: evidence, governor: backgroundProcessing,
            recordMetric: { await LocalContextIntegration.record($0, database: database) })
        localContextOwner = owner
        return owner
    }

    private func stopLocalContext() async { await localContextOwner?.stop() }

    /// Check if services are initialized
    public var initialized: Bool {
        isInitialized
    }

    /// Get database statistics
    public func getDatabaseStats() async throws -> DatabaseStatistics {
        try await database.getStatistics()
    }

    /// Get app session count (distinct from video segment count)
    public func getAppSessionCount() async throws -> Int {
        try await database.getAppSessionCount()
    }

    /// Get quick database statistics (single query, for feedback diagnostics)
    public func getDatabaseStatsQuick() async throws -> (frameCount: Int, sessionCount: Int) {
        try await database.getStatisticsQuick()
    }

    /// Get search statistics
    public func getSearchStats() async -> SearchStatistics {
        await search.getStatistics()
    }

    /// Get capture statistics
    public func getCaptureStats() async -> CaptureStatistics {
        await capture.getStatistics()
    }

    /// Get processing statistics
    public func getProcessingStats() async -> ProcessingStatistics {
        await processing.getStatistics()
    }
}

// MARK: - Default Configurations

extension StorageConfig {
    public static var `default`: StorageConfig {
        // Read settings from UserDefaults (synced with Settings UI)
        // Defaults: retention = forever (0/nil), storage = unlimited (500GB max)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 0
        let maxStorageGB = defaults.object(forKey: "maxStorageGB") as? Double ?? 500.0

        return StorageConfig(
            storageRootPath: AppPaths.storageRoot,
            retentionDays: retentionDays == 0 ? nil : retentionDays, // 0 = forever
            maxStorageGB: maxStorageGB,
            segmentDurationSeconds: 300  // 5 minutes
        )
    }
}

extension CaptureConfig {
    public static var `default`: CaptureConfig {
        // Read settings from UserDefaults (synced with Settings UI)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let captureIntervalSeconds = defaults.object(forKey: "captureIntervalSeconds") as? Double ?? 2.0
        // TODO: Re-enable once private window detection is more reliable
        // Currently disabled because detection has false positives and doesn't reliably detect incognito
        let excludePrivateWindows = defaults.object(forKey: "excludePrivateWindows") as? Bool ?? false
        // excludeCursor = true means hide cursor, so showCursor = !excludeCursor
        let excludeCursor = defaults.object(forKey: "excludeCursor") as? Bool ?? false
        let showCursor = !excludeCursor
        // Delete duplicate frames setting controls adaptive capture (deduplication)
        // Default to true - deduplication enabled by default
        let deleteDuplicateFrames = defaults.object(forKey: "deleteDuplicateFrames") as? Bool ?? true
        // Deduplication threshold - how similar frames must be to be considered duplicates
        let deduplicationThreshold = defaults.object(forKey: "deduplicationThreshold") as? Double ?? CaptureConfig.defaultDeduplicationThreshold

        // Parse excluded apps from settings (stored as JSON array of ExcludedAppInfo)
        var excludedBundleIDs: Set<String> = ["com.apple.loginwindow"] // Always exclude login screen
        if let excludedAppsString = defaults.string(forKey: "excludedApps"),
           !excludedAppsString.isEmpty,
           let data = excludedAppsString.data(using: .utf8) {
            // Decode the JSON array and extract bundle IDs
            struct ExcludedAppInfo: Codable {
                let bundleID: String
            }
            if let apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) {
                for app in apps {
                    excludedBundleIDs.insert(app.bundleID)
                }
            }
        }

        let redactWindowTitlePatterns = parseRedactionPatterns(defaults.string(forKey: "redactWindowTitlePatterns"))
        let redactBrowserURLPatterns = parseRedactionPatterns(defaults.string(forKey: "redactBrowserURLPatterns"))

        // Capture on window change - instantly capture when switching apps/windows
        let captureOnWindowChange = defaults.object(forKey: "captureOnWindowChange") as? Bool ?? true

        return CaptureConfig(
            captureIntervalSeconds: captureIntervalSeconds,
            adaptiveCaptureEnabled: deleteDuplicateFrames, // Controlled by "Delete duplicate frames" setting
            deduplicationThreshold: deduplicationThreshold, // Controlled by "Similarity threshold" slider in settings
            maxResolution: .uhd4K,
            excludedAppBundleIDs: excludedBundleIDs,
            excludePrivateWindows: excludePrivateWindows,
            showCursor: showCursor,
            redactWindowTitlePatterns: redactWindowTitlePatterns,
            redactBrowserURLPatterns: redactBrowserURLPatterns,
            captureOnWindowChange: captureOnWindowChange,
            backend: defaults.string(forKey: "captureBackend").flatMap(CaptureBackend.init(rawValue:)) ?? .legacy,
            displayPolicy: defaults.string(forKey: "captureDisplayPolicy").flatMap(CaptureDisplayPolicy.init(rawValue:)) ?? .allDisplays,
            captureVisibleTextEnabled: defaults.bool(forKey: "captureVisibleTextEnabled"),
            captureGroupReceiptsEnabled: defaults.bool(forKey: "captureGroupReceiptsEnabled")
        )
    }

    private static func parseRedactionPatterns(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension ProcessingConfig {
    public static var `default`: ProcessingConfig {
        ProcessingConfig(
            accessibilityEnabled: false,  // Disabled - reads live screen, not video frames
            ocrAccuracyLevel: .accurate,
            recognitionLanguages: ["en-US"],
            minimumConfidence: 0.5
        )
    }
}

extension SearchConfig {
    public static var `default`: SearchConfig {
        SearchConfig(
            semanticSearchEnabled: false,  // Semantic search disabled
            defaultResultLimit: 50,
            minimumRelevanceScore: 0.1
        )
    }
}


// MARK: - Errors

private struct ServiceCleanupFailure: Error {
    let failures: [any Error]
}

enum ServiceError: Error {
    case databaseNotReady
}
