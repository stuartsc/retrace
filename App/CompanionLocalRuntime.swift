import Foundation
import Shared

/// Release workers run reviewed code shipped inside the signed application,
/// never an arbitrary checkout. Existing Outlook dependencies remain read-only.
enum CompanionLocalRuntime {
    static func wrap(_ remote: CompanionHTTPTransport, root: URL, nativeStoreID: UUID,
                     governor: any BackgroundProcessingProtocol) -> any CompanionTransport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let outlook = home.appendingPathComponent("outlook", isDirectory: true)
        let python = outlook.appendingPathComponent(".venv/bin/python")
        let scripts: URL
        #if DEBUG
        scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts", isDirectory: true)
        #else
        guard let resources = Bundle.main.resourceURL else { return remote }
        scripts = resources.appendingPathComponent("AudioWorker", isDirectory: true)
        #endif
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: scripts.appendingPathComponent("retrace_companion/local_job.py").path) else {
            Log.warning("Local quality worker unavailable; remote processing and saved drafts remain available", category: .app)
            return remote
        }
        let executor = CompanionLocalExecutor(python: python, scripts: scripts, outlook: outlook, governor: governor)
        return CompanionFallbackTransport(remote: remote, root: root, nativeStoreID: nativeStoreID, local: executor)
    }
}
