import Foundation

/// Locates UI assets for packaged apps and direct SwiftPM runs.
enum AppResourceBundle {
    static let bundle: Bundle = {
#if SWIFT_PACKAGE
        // Keep this fallback lazy: SwiftPM's generated accessor can fatalError
        // in an installed app when its original build directory is absent.
        return resolve(appBundle: .main) { .module }
#else
        return .main
#endif
    }()

    static func resolve(appBundle: Bundle, fallback: () -> Bundle) -> Bundle {
        if let url = appBundle.resourceURL?.appendingPathComponent("Retrace_Retrace.bundle", isDirectory: true),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return fallback()
    }
}
