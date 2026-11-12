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
    public let ftsEngine: FTSManager
    public let storage: StorageManager
    public let capture: CaptureManager
    public let audioCapture: AudioCaptureManager
    public let processing: ProcessingManager
    public let audioProcessing: AudioProcessingManager
    public let resourceUsage: ResourceUsageMonitor
    public let storageUsage: StorageUsageService
    public let backgroundProcessing: BackgroundProcessingGovernor
    let manualAudioWork = ManualAudioWorkOwner()
    public let dictation: DictationManager
    public let search: SearchManager
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
    private var markerService: TimelineMarkerService?
    private var voiceMarkerOwner: VoiceMarkerController?
    private var liveTranscriptionOwner: LiveTranscriptionController?
    private var audioSessionOwner: AudioSessionOwner?
    private var markerAudioMedia: MarkerAudioMediaService?
    private var markerAudioPlayback: MarkerAudioPlayback?
    private var companionTurnPlaybackOwner: CompanionTurnPlayback?
    private var companionOwner: CompanionController?
    private var companionSettingsOwner: CompanionSettingsService?
    private var sourceConfigurationOwner: SourceConfigurationService?
    private var liveAudioContextReader: LiveAudioContextReader?
    private var liveAudioContextClosing = false
    private var markerAccessClosed = false

    // MARK: - Configuration

    private let databasePath: String
    private let storageConfig: StorageConfig
    private let captureConfig: CaptureConfig
    private let audioCaptureConfig: AudioCaptureConfig
    private let processingConfig: ProcessingConfig
    private let audioProcessingConfig: AudioProcessingConfig
    private let searchConfig: SearchConfig

    private var isInitialized = false
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
    #endif

    // MARK: - Initialization

    public init(
        databasePath: String = AppPaths.databasePath,
        storageConfig: StorageConfig = .default,
        captureConfig: CaptureConfig = .default,
        audioCaptureConfig: AudioCaptureConfig = .default,
        processingConfig: ProcessingConfig = .default,
        audioProcessingConfig: AudioProcessingConfig = .default,
        searchConfig: SearchConfig = .default
    ) {
        self.databasePath = databasePath
        self.storageConfig = storageConfig
        self.captureConfig = captureConfig
        self.audioCaptureConfig = audioCaptureConfig
        self.processingConfig = processingConfig
        self.audioProcessingConfig = audioProcessingConfig
        self.searchConfig = searchConfig

        // Initialize all managers
        let resourceUsage = ResourceUsageMonitor()
        self.resourceUsage = resourceUsage
        self.backgroundProcessing = BackgroundProcessingGovernor(resourceUsage: resourceUsage)
        self.database = DatabaseManager(databasePath: databasePath)
        self.ftsEngine = FTSManager(databasePath: databasePath)
        // Use the correct storage root (respects custom path setting)
        let storageRootURL = URL(fileURLWithPath: NSString(string: storageConfig.storageRootPath).expandingTildeInPath, isDirectory: true)
        self.storageUsage = StorageUsageService(
            roots: StorageUsageService.roots(native: storageRootURL, includeRelatedLibraries: true), resources: resourceUsage)
        self.storage = StorageManager(storageRoot: storageRootURL)
        self.capture = CaptureManager(config: captureConfig,
            configurationAdmission: ScreenEvidenceAdmissionCoordinator(database: database))
        self.audioCapture = AudioCaptureManager(config: audioCaptureConfig)
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
                modelPath: modelPath,
                modelResidency: .onDemand(idleTimeout: .seconds(45))
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
            governor: backgroundProcessing,
            config: audioProcessingConfig
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
        self.databasePath = sharedMemoryPath
        self.storageConfig = StorageConfig(storageRootPath: testStorageRoot.path)
        self.captureConfig = CaptureConfig()
        self.audioCaptureConfig = .default
        self.processingConfig = .default
        self.audioProcessingConfig = .default
        self.searchConfig = .default

        self.resourceUsage = ResourceUsageMonitor()
        self.backgroundProcessing = BackgroundProcessingGovernor(observeSystem: false)

        self.database = DatabaseManager(databasePath: sharedMemoryPath)
        self.ftsEngine = FTSManager(databasePath: sharedMemoryPath)
        self.storage = StorageManager(storageRoot: testStorageRoot)
        self.storageUsage = StorageUsageService(
            roots: StorageUsageService.roots(native: testStorageRoot, includeRelatedLibraries: false), resources: resourceUsage)
        self.capture = CaptureManager(config: captureConfig,
            configurationAdmission: ScreenEvidenceAdmissionCoordinator(database: database))
        self.audioCapture = AudioCaptureManager()
        self.processing = ProcessingManager()

        // Use mock transcription service in test mode to avoid loading heavy Whisper model
        let transcriptionService: any TranscriptionProtocol = MockTranscriptionService()
        self.transcriptionService = transcriptionService
        let audioWriter = AudioSegmentWriter(storageRoot: testStorageRoot)
        self.audioProcessing = AudioProcessingManager(
            transcriptionService: transcriptionService,
            transcriptionQueries: nil,  // Set during initialization
            audioWriter: audioWriter,
            config: .default
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
        guard !isInitialized else {
            Log.warning("ServiceContainer already initialized", category: .app)
            return
        }

        Log.info("Initializing all services...", category: .app)
        try await backgroundProcessing.reopenAfterJoinedClose()
        try await manualAudioWork.reopen()

        // 1. Initialize database first (creates schema)
        try await database.initialize()
        try Task.checkCancellation()
        if liveAudioContextClosing {
            // A failed startup may be retried after its joined rollback. Old
            // views retain a terminal reader; the reopened store gets a new one.
            liveAudioContextReader = nil
            liveAudioContextClosing = false
        }
        await resourceUsage.start { [database] minute in
            do { try await database.recordResourceUsageMinute(minute) }
            catch { Log.warning("Could not save CPU usage aggregate", category: .app) }
        }
        Log.info("✓ Database initialized", category: .app)
        await storageUsage.start()
        try? await database.recordMetricEvent(metricType: .storageUsage, metadata: "{\"action\":\"started\"}")

        // Historical evidence has an owning policy even while recording is
        // paused. Install it before any remaining service can claim derived work.
        try await capture.initializeConfigurationAdmission()
        try Task.checkCancellation()

        #if DEBUG
        if let initializationRemainderForTesting {
            try await initializationRemainderForTesting()
            try Task.checkCancellation()
            isInitialized = true
            return
        }
        #endif

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
            try await audioProcessing.initialize(
                transcriptionQueries: audioTranscriptionQueries,
                audioWriter: audioWriter
            )
            await dictation.updateSessionStore(dictationSessionQueries)
            Log.info("✓ Audio processing initialized", category: .app)

            // Create backfill manager only if real whisper service is available
            if let service = self.transcriptionService, !(service is MockTranscriptionService) {
                self.audioBackfill = AudioBackfillManager(
                    transcriptionService: BackgroundTranscriptionService(service: service, governor: backgroundProcessing),
                    transcriptionQueries: audioTranscriptionQueries,
                    audioWriter: audioWriter,
                    storageRoot: audioStorageRoot
                )
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

        // Initialize the adapter
        try await adapter.initialize()
        self.dataAdapter = adapter
        if useRewindData {
            do { try await registerRewindSourceIfEnabled() }
            catch is CancellationError { throw CancellationError() }
            catch { Log.warning("[ServiceContainer] Rewind source unavailable; native recording remains available", category: .app) }
        }
        try Task.checkCancellation()
        Log.info("✓ DataAdapter initialized", category: .app)

        // 10. Start retention manager (runs periodic cleanup based on user settings)
        await retentionManager.start()
        try Task.checkCancellation()
        Log.info("✓ Retention manager started", category: .app)

        // Capture is initialized when startCapture() is called

        isInitialized = true
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
            let processingRef = self.audioProcessing
            await refinement.setPass1ActiveCheck {
                await processingRef.isTranscribing
            }
            self.audioRefinement = refinement
            Log.info("✓ Audio refinement manager initialized (turbo model loads on demand)", category: .app)
        }

        if audioContextualRefinement == nil {
            self.audioContextualRefinement = AudioContextualRefinementManager(
                transcriptionService: turboService,
                transcriptionQueries: audioTranscriptionQueries,
                audioWriter: audioWriter,
                storageRoot: audioStorageRoot
            )
            Log.info("✓ Audio contextual refinement manager initialized", category: .app)
        }

        return true
    }

    /// Shared owner for the existing locally selected Rewind source. Reading it
    /// opens no library or device; connection is an explicit previewed command.
    public func sourceConfiguration() throws -> SourceConfigurationService {
        guard !markerAccessClosed else { throw SourceConfigurationError.closed }
        guard let adapter = dataAdapter else { throw DataAdapterError.notInitialized }
        if let sourceConfigurationOwner { return sourceConfigurationOwner }
        let owner = SourceConfigurationService(backend: .init(observe: { [weak self] in
            guard let self else { throw SourceConfigurationError.closed }
            return try await self.sourceConfigurationEnvironment(adapter: adapter)
        }, connect: { [weak self] fingerprint, fences in
            guard let self else { throw SourceConfigurationError.closed }
            try await self.configureRewindSource(adapter: adapter, expectedFingerprint: fingerprint, fences: fences)
        }, disconnectAndDrain: {
            await adapter.disconnectRewind()
            await MainActor.run {
                NotificationCenter.default.post(name: Notification.Name("dataSourceDidChange"), object: nil)
            }
        }, commitPreference: { enabled, expectedFingerprint in
            guard SourceConfigurationSelectionIdentity.fingerprint(databasePath: AppPaths.rewindDBPath) == expectedFingerprint else {
                throw SourceConfigurationError.stalePreview
            }
            let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
            defaults.set(enabled, forKey: "useRewindData")
            guard defaults.synchronize(), defaults.bool(forKey: "useRewindData") == enabled else {
                throw SourceConfigurationError.persistenceFailed
            }
        }))
        sourceConfigurationOwner = owner
        return owner
    }

    private func sourceConfigurationEnvironment(adapter: DataAdapter) async throws -> SourceConfigurationEnvironment {
        guard !markerAccessClosed, dataAdapter === adapter else { throw SourceConfigurationError.closed }
        let available = await adapter.isSourceAvailable(.rewind)
        guard !markerAccessClosed, dataAdapter === adapter else { throw SourceConfigurationError.closed }
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return .init(configuredEnabled: defaults.bool(forKey: "useRewindData"), effectiveEnabled: available,
            selectionFingerprint: SourceConfigurationSelectionIdentity.fingerprint(databasePath: AppPaths.rewindDBPath))
    }

    /// Register an existing opt-in after startup/onboarding, without pretending a
    /// missing or unreadable source connected successfully.
    public func registerRewindSourceIfEnabled() async throws {
        let owner = try sourceConfiguration(), state = try await owner.read()
        guard state.configuredEnabled, !state.effectiveEnabled else { return }
        _ = try await setRewindSourceEnabled(true)
    }

    @discardableResult
    public func setRewindSourceEnabled(_ enabled: Bool) async throws -> SourceConfigurationReceipt {
        let owner = try sourceConfiguration(), state = try await owner.read()
        let preview = try await owner.preview(clientID: "local-settings", expectedRevision: state.revision, enabled: enabled)
        return try await owner.apply(clientID: "local-settings", requestID: UUID(), previewID: preview.id)
    }

    /// A native Settings folder choice, never a remote path-setting operation.
    public func changeLocalRewindLocation(_ folder: String?) async throws -> SourceConfigurationSnapshot {
        if let folder {
            guard folder.hasPrefix("/"), !folder.contains("\0"), folder.utf8.count <= 16_384 else {
                throw SourceConfigurationError.invalidRequest
            }
        }
        let owner = try sourceConfiguration()
        return try await owner.changeLocalSelection {
            let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
            if let folder { defaults.set(folder, forKey: "customRewindDBLocation") }
            else { defaults.removeObject(forKey: "customRewindDBLocation") }
            guard defaults.synchronize(), defaults.string(forKey: "customRewindDBLocation") == folder else {
                throw SourceConfigurationError.persistenceFailed
            }
        }
    }

    /// Opening/decryption uses the already selected local path. The exact file
    /// identity and command fences are checked again at adapter publication.
    private func configureRewindSource(adapter: DataAdapter, expectedFingerprint: String,
                                       fences: [NativeMutationFence]) async throws {
        guard !markerAccessClosed, dataAdapter === adapter else { throw SourceConfigurationError.closed }
        let path = NSString(string: AppPaths.rewindDBPath).expandingTildeInPath
        guard SourceConfigurationSelectionIdentity.fingerprint(databasePath: path) == expectedFingerprint else {
            throw SourceConfigurationError.stalePreview
        }
        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &raw, flags, nil) == SQLITE_OK, let db = raw else {
            if let raw { sqlite3_close_v2(raw) }
            throw SourceConfigurationError.connectionFailed
        }
        var transferred = false
        defer { if !transferred { sqlite3_close_v2(db) } }
        guard sqlite3_db_readonly(db, "main") == 1, sqlite3_busy_timeout(db, 1_000) == SQLITE_OK else {
            throw SourceConfigurationError.connectionFailed
        }
        let rewindPassword = "soiZ58XZJhdka55hLUp18yOtTUTDXz7Diu7Z4JzuwhRwGG13N6Z9RTVU1fGiKkuF"
        let keySQL = "PRAGMA key = '\(rewindPassword)'"
        guard sqlite3_exec(db, keySQL, nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA cipher_compatibility = 4", nil, nil, nil) == SQLITE_OK else {
            throw SourceConfigurationError.connectionFailed
        }
        // Fully finalize verification before handing the owned connection over.
        try {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('frame','segment','video')", -1, &statement, nil) == SQLITE_OK else {
                throw SourceConfigurationError.connectionFailed
            }
            var tables: Set<String> = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 0) { tables.insert(String(cString: name)) }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE, tables == ["frame", "segment", "video"] else {
                throw SourceConfigurationError.connectionFailed
            }
        }()
        let connection = SQLCipherConnection(takingOwnershipOf: db)
        transferred = true
        let directory = (path as NSString).deletingLastPathComponent
        let chunks = directory + "/chunks"
        let cutoff = Date(timeIntervalSince1970: 1766217600)
        let config = DatabaseConfig(dateFormatter: DatabaseConfig.rewind.dateFormatter,
            storageRoot: chunks, source: .rewind, cutoffDate: cutoff)
        try await adapter.configureRewindChecked(connection: connection, config: config,
            imageExtractor: AVAssetExtractor(storageRoot: chunks), cutoffDate: cutoff,
            fences: fences, selectionIsCurrent: {
                guard SourceConfigurationSelectionIdentity.fingerprint(databasePath: AppPaths.rewindDBPath) == expectedFingerprint,
                      let opened = connection.getConnection() else { return false }
                // Also bind the actual open handle. A path swapped away and back
                // during decryption must not publish a different library.
                var moved: Int32 = 0
                return sqlite3_file_control(opened, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK && moved == 0
            })
        await MainActor.run {
            NotificationCenter.default.post(name: Notification.Name("dataSourceDidChange"), object: nil)
        }
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

        let realService = WhisperCppTranscriptionService(modelPath: modelURL.path,
            modelResidency: .onDemand(idleTimeout: .seconds(45)))
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
                transcriptionService: BackgroundTranscriptionService(service: realService, governor: backgroundProcessing),
                transcriptionQueries: audioTranscriptionQueries,
                audioWriter: audioWriter,
                storageRoot: audioStorageRoot
            )
            Log.info("[ServiceContainer] Audio backfill manager created after transcription upgrade", category: .app)
        }
    }

    /// Shutdown all services gracefully
    public func shutdown() async throws {
        markerAccessClosed = true
        liveAudioContextClosing = true
        await liveTranscriptionOwner?.close()
        await liveAudioContextReader?.close()
        // A failed drain keeps both owners and their databases available for a
        // joined cleanup retry. No processor/context close may pass it.
        try await audioSessionOwner?.close()
        sourceConfigurationOwner?.invalidate()
        await sourceConfigurationOwner?.close()
        companionOwner?.invalidate()
        await companionTurnPlaybackOwner?.close()
        // Failed companion cleanup preserves its reader and canonical writer for a retry.
        try await companionSettingsOwner?.close()
        await markerAudioPlayback?.close()
        await voiceMarkerOwner?.close()
        await initializationLifecycle.beginShutdown()
        #if DEBUG
        shutdownRequestForTesting?()
        #endif
        try await initializationLifecycle.stop(onRequest: { [capture, backgroundProcessing] in
            await backgroundProcessing.cancelAutomaticWork()
            // Establish the policy fence before joining a late initialization.
            // Teardown below retries this close and finishes other resources even
            // if this first attempt fails; both errors remain in the task result.
            try await capture.shutdownConfigurationAdmission()
        }, operation: { [self] in
            try await shutdownServices()
        })
    }

    private func shutdownServices() async throws {
        isInitialized = false
        // Startup rollback also reaches this path without public shutdown().
        liveAudioContextClosing = true
        await liveTranscriptionOwner?.close()
        await liveAudioContextReader?.close()
        var failures: [any Error] = []
        Log.info("Shutting down all services...", category: .app)
        await backgroundProcessing.cancelAutomaticWork()

        // Partial startup and paused recording still have an owning policy.
        do { try await capture.shutdownConfigurationAdmission() }
        catch { failures.append(error) }

        do { try await capture.stopCapture() }
        catch { failures.append(error) }
        do { try await audioCapture.stopCapture() }
        catch { failures.append(error) }

        await audioProcessing.stopProcessing()
        await manualAudioWork.close()

        // Stop processing queue workers
        await processingQueue?.stopWorkers()
        processingQueue = nil
        Log.info("✓ Processing queue workers stopped", category: .app)

        // Wait for processing queue to drain (legacy OCR queue)
        await processing.waitForQueueDrain()
        Log.info("✓ Processing queue drained", category: .app)

        await backgroundProcessing.close()
        await storageUsage.close()
        await resourceUsage.close()

        // Audio ingestion, native work and metric delivery are joined above.
        Log.info("✓ Audio processing drained", category: .app)

        // Stop retention manager
        await retentionManager.stop()
        Log.info("✓ Retention manager stopped", category: .app)

        // Marker operations include their canonical metric tails. A failed release keeps
        // the adapter/writer available for an explicit cleanup retry and admission stays closed.
        do { try await markerService?.close() }
        catch {
            failures.append(error)
            if failures.count == 1 { throw error }
            throw ServiceCleanupFailure(failures: failures)
        }

        // Release the container's adapter after shutting down its state.
        await dataAdapter?.shutdown()
        dataAdapter = nil
        Log.info("✓ DataAdapter shutdown", category: .app)

        // Close database connections
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

        if failures.count == 1 { throw failures[0] }
        if !failures.isEmpty { throw ServiceCleanupFailure(failures: failures) }
        Log.info("All services shutdown successfully", category: .app)
    }

    // MARK: - Service Access

    public func getLiveAudioContextReader() throws -> LiveAudioContextReader {
        guard !markerAccessClosed, !liveAudioContextClosing else { throw AudioContextReadError.closed }
        if let liveAudioContextReader { return liveAudioContextReader }
        let reader = LiveAudioContextReader(database: database)
        liveAudioContextReader = reader
        return reader
    }

    /// Check if services are initialized
    public var initialized: Bool {
        isInitialized
    }

    /// Returns the shared lazy owner. Getting it does not open or create a context database.
    public func timelineMarkers() throws -> TimelineMarkerService {
        guard !markerAccessClosed else { throw ContextStoreError.closed }
        guard isInitialized, let adapter = dataAdapter else { throw DataAdapterError.notInitialized }
        if let markerService { return markerService }
        let canonicalDatabase = database
        let owner = TimelineMarkerService(
            storageRoot: URL(fileURLWithPath: storageConfig.expandedStorageRootPath, isDirectory: true),
            nativeStoreID: { try await adapter.evidenceStoreID(source: .native) },
            metrics: { action, outcome in
                let metadata = "{\"action\":\"\(action.rawValue)\",\"outcome\":\"\(outcome.rawValue)\"}"
                try? await canonicalDatabase.recordMetricEvent(metricType: .timelineMarkerAction, metadata: metadata)
            })
        markerService = owner
        return owner
    }

    /// Recognition is App-owned and remains dormant unless recording and enabled rules both permit it.
    public func voiceMarkers() async throws -> VoiceMarkerController {
        guard !markerAccessClosed else { throw ContextStoreError.closed }
        if let voiceMarkerOwner { return voiceMarkerOwner }
        let marker = try timelineMarkers()
        guard let adapter = dataAdapter else { throw DataAdapterError.notInitialized }
        let resource = resourceUsage
        let owner = VoiceMarkerController(markers: marker,
            nativeStoreID: { try await adapter.evidenceStoreID(source: .native) },
            underPressure: {
                let snapshot = await resource.snapshot()
                return ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical ||
                    (snapshot.isCurrent && (snapshot.systemFiveSecondCPUPercent ?? 0) > 85)
            })
        voiceMarkerOwner = owner
        let media = MarkerAudioMediaService(
            storageRoot: URL(fileURLWithPath: storageConfig.expandedStorageRootPath, isDirectory: true),
            markers: marker, nativeStoreID: { try await adapter.evidenceStoreID(source: .native) })
        markerAudioMedia = media
        let installed = await audioProcessing.setPersistedBatchHandler { receipt in
            if receipt.sourceMappingIncomplete { await owner.markMediaMappingIncomplete() }
            guard !receipt.sourceRanges.isEmpty else { return }
            do { try await media.register(receipt) }
            catch { await owner.markMediaMappingIncomplete(); throw error }
        }
        if !installed { await owner.markMediaMappingIncomplete() }
        await owner.start()
        return owner
    }

    /// Trial is independent of voice rules; merely viewing status never creates a recognizer.
    public func liveTranscription() async -> LiveTranscriptionController {
        if let liveTranscriptionOwner { return liveTranscriptionOwner }
        guard !markerAccessClosed else {
            let closed = LiveTranscriptionController(); await closed.close(); return closed
        }
        let resource = resourceUsage
        let owner = LiveTranscriptionController(underPressure: {
            let snapshot = await resource.snapshot()
            return ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical ||
                (snapshot.isCurrent && (snapshot.systemFiveSecondCPUPercent ?? 0) > 85)
        })
        liveTranscriptionOwner = owner
        await owner.setEnabled(UserDefaults.standard.bool(forKey: "liveMicrophoneDraftTrialEnabled"))
        return owner
    }

    public func liveTranscriptionSnapshot() async -> LiveTranscriptionSnapshot {
        await liveTranscriptionOwner?.snapshot() ?? LiveTranscriptionSnapshot()
    }

    public func setLiveTranscriptionEnabled(_ enabled: Bool) async {
        guard !markerAccessClosed else { return }
        UserDefaults.standard.set(enabled, forKey: "liveMicrophoneDraftTrialEnabled")
        let owner = await liveTranscription()
        await owner.setEnabled(enabled)
    }

    public func pauseVoiceMarkers() async { await voiceMarkerOwner?.setRecording(false) }

    func audioSession(pipeline: AudioSessionOwner.Pipeline) async throws -> AudioSessionOwner {
        guard !markerAccessClosed else { throw AudioSessionError.closed }
        if let audioSessionOwner { return audioSessionOwner }
        let store = try await timelineMarkers().audioSessionSettingsStore()
        guard !markerAccessClosed else { throw AudioSessionError.closed }
        if let audioSessionOwner { return audioSessionOwner }
        let owner = AudioSessionOwner(store: store, baseConfig: audioCaptureConfig, pipeline: pipeline)
        audioSessionOwner = owner
        return owner
    }

    func pauseAudioSession() async throws {
        try await audioSessionOwner?.setRecordingRequested(false)
    }

    /// Cheap status only; unlike voiceMarkers(), this never initializes recognition.
    public func existingVoiceMarkerStatus() async -> VoiceMarkerStatus? {
        await voiceMarkerOwner?.status()
    }

    public func markerMedia() async throws -> MarkerAudioMediaService {
        guard !markerAccessClosed else { throw ContextStoreError.closed }
        _ = try await voiceMarkers()
        guard !markerAccessClosed, let markerAudioMedia else { throw ContextStoreError.closed }
        return markerAudioMedia
    }

    public func markerPlayback() async throws -> MarkerAudioPlayback {
        guard !markerAccessClosed else { throw ContextStoreError.closed }
        if let markerAudioPlayback { return markerAudioPlayback }
        let media = try await markerMedia()
        guard !markerAccessClosed else { throw ContextStoreError.closed }
        if let markerAudioPlayback { return markerAudioPlayback }
        let owner = MarkerAudioPlayback(media: media, markers: try timelineMarkers())
        markerAudioPlayback = owner
        return owner
    }

    func companionTurnPlayback(controller: CompanionController) async throws -> CompanionTurnPlayback {
        guard !markerAccessClosed, companionOwner === controller else { throw CompanionError.closed }
        if let companionTurnPlaybackOwner { return companionTurnPlaybackOwner }
        let media = try await markerMedia()
        guard !markerAccessClosed, companionOwner === controller else { throw CompanionError.closed }
        if let companionTurnPlaybackOwner { return companionTurnPlaybackOwner }
        // Register a stable controller drain before publishing any player. Every
        // competing initializer installs the same semantics, so a losing candidate
        // cannot replace retention's callback with a different player instance.
        await retentionManager.setSourceMutationDrain { [weak controller] in await controller?.drainSpeakerOutput() }
        guard !markerAccessClosed, companionOwner === controller else { throw CompanionError.closed }
        if let companionTurnPlaybackOwner { return companionTurnPlaybackOwner }
        let owner = CompanionTurnPlayback(controller: controller, media: media)
        companionTurnPlaybackOwner = owner
        return owner
    }

    /// Called by the coordinator's coalesced initializer. Neither construction nor settings reads
    /// activate remote delivery; only restoring an explicit saved configuration does so.
    func companionOwners(recall: ProgressiveRecallService,
                         policy: @escaping @Sendable () async throws -> Void) async throws
        -> (CompanionController, CompanionSettingsService) {
        guard !markerAccessClosed, let adapter = dataAdapter else { throw ContextStoreError.closed }
        if let companionOwner, let companionSettingsOwner { return (companionOwner, companionSettingsOwner) }
        let media = try await markerMedia()
        let nativeID = try await adapter.evidenceStoreID(source: .native)
        guard !markerAccessClosed else { throw ContextStoreError.closed }
        if let companionOwner, let companionSettingsOwner { return (companionOwner, companionSettingsOwner) }
        let database = self.database
        let owner = CompanionController(
            storageRoot: URL(fileURLWithPath: storageConfig.expandedStorageRootPath, isDirectory: true)
                .appendingPathComponent("context/companion", isDirectory: true),
            nativeStoreID: nativeID, databasePath: databasePath, adapter: adapter, recall: recall,
            markers: try timelineMarkers(), verifiedBytes: { try await media.verifiedBytes(for: $0) }, policy: policy,
            metric: { action, outcome in
                // Action/outcome originate from fixed App enums/literals; never retain evidence or credentials.
                guard ["configured", "operation", "speaker_correction"].contains(action),
                      ["ready", "succeeded", "saved"].contains(outcome) else { return }
                let bytes = try? JSONEncoder().encode(["action": action, "outcome": outcome])
                if let bytes, let metadata = String(data: bytes, encoding: .utf8) {
                    try? await database.recordMetricEvent(metricType: .companionAction, metadata: metadata)
                }
            })
        let settings = CompanionSettingsService(controller: owner, nativeStoreID: nativeID)
        // Writer callbacks only revoke a cheap transmission epoch. They never perform a read,
        // enqueue inference, or enter an App actor while SQLite owns its connection mutex.
        try await database.setSourceMutationObserver { [weak owner] change in owner?.sourceChanged(change) }
        try await ftsEngine.setSourceMutationObserver { [weak owner] change in owner?.sourceChanged(change) }
        let installed = await audioProcessing.setCommittedBatchHandler { receipt in
            guard receipt.source == .microphone else { return }
            // The durable enrollment/candidate ledger owns delivery. This callback
            // accelerates it; a missed callback cannot lose eligible saved speech.
            owner.textCommitted()
        }
        guard installed, !markerAccessClosed else {
            try await settings.close()
            throw CompanionError.unavailable
        }
        companionOwner = owner; companionSettingsOwner = settings
        return (owner, settings)
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
        if let saved = CaptureSettingsPersistence.application.load() { return saved }
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
            captureOnWindowChange: captureOnWindowChange
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
