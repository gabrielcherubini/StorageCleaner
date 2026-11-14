import Foundation

/// Persistent access to user-picked folders on both macOS (sandboxed) and iOS.
enum SecurityScopedBookmark {
    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = [.minimalBookmark]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    struct Resolved: Sendable {
        let url: URL
        let isStale: Bool
    }

    /// Creates a bookmark for a URL returned by the folder picker.
    static func make(for url: URL) throws -> Data {
        try withAccess(to: url) {
            try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    static func resolve(_ bookmark: Data) throws -> Resolved {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: resolutionOptions, relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return Resolved(url: url, isStale: isStale)
    }

    /// Runs `body` while holding security-scoped access to `url`. Proceeds without a scope when the
    /// URL is not security scoped (for example in unsandboxed builds).
    static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    static func withAccess<T>(to url: URL, _ body: () async throws -> T) async rethrows -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try await body()
    }
}
