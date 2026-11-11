import Foundation
import Shared

/// Bundled tokenizer only. The large model remains an explicit local selection;
/// the runtime verifies both artifacts against the pinned descriptor before use.
public enum LocalEmbeddingResources {
    public static func tokenizerURL() throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: LocalEmbeddingResourceAnchor.self)
        #endif
        guard let url = bundle.url(forResource: "tokenizer", withExtension: "json", subdirectory: "MiniLM") else {
            throw LocalEmbeddingError.artifactUnavailable
        }
        return url
    }
}

private final class LocalEmbeddingResourceAnchor: NSObject { }
