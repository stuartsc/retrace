import Foundation
import Darwin
import Dispatch
import Shared

/// One explicitly configured child. No listener and no mutation of Outlook's host role.
public struct CompanionLocalExecutor: Sendable {
    public let python: URL
    public let scripts: URL
    public let outlook: URL
    public let governor: any BackgroundProcessingProtocol
    public init(python: URL, scripts: URL, outlook: URL, governor: any BackgroundProcessingProtocol) {
        self.python = python; self.scripts = scripts; self.outlook = outlook; self.governor = governor
    }
    public func execute(root: URL, jobID: String, onAdmitted: @escaping @Sendable () async throws -> Void = {}, admission: @escaping @Sendable () throws -> Void = {}) async throws -> Data {
        try CompanionBounds.digest(jobID)
        return try await BackgroundProcessingContext.run(governor: governor, kind: .refinement) {
            let permit = BackgroundProcessingContext.permit!
            try await onAdmitted()
            try BackgroundProcessingContext.checkCancellation()
            let task = Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = python
                process.arguments = ["-m", "retrace_companion.local_job", "--root", root.path,
                    "--job", jobID, "--outlook", outlook.path, "--threads", String(permit.threadCount)]
                var environment = ProcessInfo.processInfo.environment
                environment["PYTHONPATH"] = scripts.path
                environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try admission()
                try process.run()
                let childPID = process.processIdentifier
                guard childPID > 1 else { throw CompanionError.unavailable }
                var cancelled = false
                while process.isRunning {
                    do { try admission() } catch { permit.cancellation.cancel() }
                    if permit.cancellation.isCancelled || Task.isCancelled {
                        cancelled = true
                        // local_job creates its own group before spawning any decoder.
                        _ = Darwin.kill(-process.processIdentifier, SIGTERM); process.terminate()
                        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                        while process.isRunning && ContinuousClock.now < deadline { await Self.waitForGroupTick() }
                        if process.isRunning { _ = Darwin.kill(-process.processIdentifier, SIGKILL); _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                process.waitUntilExit()
                // A decoder may outlive the Python leader; do not release the
                // governor permit until the owned process group has drained.
                let group = -childPID
                if Darwin.kill(group, 0) == 0 {
                    _ = Darwin.kill(group, SIGTERM)
                    let grace = ContinuousClock.now.advanced(by: .seconds(1))
                    while Darwin.kill(group, 0) == 0 && ContinuousClock.now < grace { await Self.waitForGroupTick() }
                    while Darwin.kill(group, 0) == 0 {
                        _ = Darwin.kill(group, SIGKILL)
                        await Self.waitForGroupTick()
                    }
                }
                if cancelled { throw CancellationError() }
                guard process.terminationStatus == 0 else { throw CompanionError.unavailable }
                let path = root.appendingPathComponent("execution-results/\(jobID).json")
                let info = try path.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
                guard info.isSymbolicLink != true, info.isRegularFile == true, let size = info.fileSize,
                      size > 0, size <= 2 * 1024 * 1024 else { throw CompanionError.unsafeStorage }
                return try Data(contentsOf: path)
            }
            return try await withTaskCancellationHandler { try await task.value }
                onCancel: { permit.cancellation.cancel(); task.cancel() }
        }
    }
    private static func waitForGroupTick() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
        }
    }

}
