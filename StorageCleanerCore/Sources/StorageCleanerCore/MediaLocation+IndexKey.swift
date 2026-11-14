import Foundation

extension MediaLocation {
    private static let photoPrefix = "photo:"
    private static let filePrefix = "file:"

    /// Stable string identity used as the unique key in the on-device index.
    public var indexKey: String {
        switch self {
        case let .photoLibrary(localIdentifier):
            return Self.photoPrefix + localIdentifier
        case let .file(url):
            return Self.filePrefix + url.standardizedFileURL.path
        }
    }

    public init?(indexKey: String) {
        if indexKey.hasPrefix(Self.photoPrefix) {
            let id = String(indexKey.dropFirst(Self.photoPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .photoLibrary(localIdentifier: id)
        } else if indexKey.hasPrefix(Self.filePrefix) {
            let path = String(indexKey.dropFirst(Self.filePrefix.count))
            guard path.hasPrefix("/") else { return nil }
            self = .file(URL(fileURLWithPath: path))
        } else {
            return nil
        }
    }
}
