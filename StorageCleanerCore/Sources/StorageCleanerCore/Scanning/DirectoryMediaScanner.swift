import Foundation

/// One item found by a scanner, with the fingerprint used for incremental rescans.
public struct ScannedItem: Hashable, Sendable {
    public let item: MediaItem
    public let fingerprint: ScanFingerprint

    public init(item: MediaItem, fingerprint: ScanFingerprint) {
        self.item = item
        self.fingerprint = fingerprint
    }

    public var indexKey: String { item.location.indexKey }
}

/// Walks a folder and reports photo, video and audio files with their size and dates.
///
/// Strictly read-only: it reads directory listings and file metadata, never media contents, so it
/// does not trigger iCloud downloads. The only file it opens is the tiny local `.icloud` placeholder
/// stub that older iCloud Drive versions leave in place of files that are not downloaded.
/// Callers are responsible for security-scoped access to `root`.
public struct DirectoryMediaScanner: Sendable {
    public init() {}

    private static var resourceKeys: [URLResourceKey] {
        var keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey,
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        ]
        #if canImport(Darwin)
        keys += [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        #endif
        return keys
    }

    /// Calls `body` for every media file under `root`, depth first. Hidden folders and package
    /// contents (for example a `.photoslibrary` bundle) are skipped. Throwing from `body` stops the
    /// walk, which is how callers cancel.
    public func scan(root: URL, _ body: (ScannedItem) throws -> Void) rethrows {
        let keys = Self.resourceKeys
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }

        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent

            if values?.isDirectory == true {
                if name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }

            if let realName = ICloudPlaceholder.realName(forPlaceholderName: name) {
                if let file = Self.placeholderFile(url: url, realName: realName, values: values) {
                    try body(file)
                }
                continue
            }
            if name.hasPrefix(".") { continue }
            guard let kind = MediaKind(fileExtension: url.pathExtension) else { continue }

            let size = Int64(values?.fileSize ?? 0)
            let item = MediaItem(
                location: .file(url),
                kind: kind,
                byteSize: size,
                filename: name,
                creationDate: values?.creationDate,
                modificationDate: values?.contentModificationDate,
                isLocallyAvailable: Self.isLocallyAvailable(values)
            )
            try body(ScannedItem(
                item: item,
                fingerprint: ScanFingerprint(byteSize: size, modificationDate: values?.contentModificationDate)
            ))
        }
    }

    /// Convenience that collects every file. Prefer `scan(root:_:)` for large folders.
    public func scanAll(root: URL) -> [ScannedItem] {
        var files: [ScannedItem] = []
        scan(root: root) { files.append($0) }
        return files
    }

    private static func placeholderFile(url: URL, realName: String, values: URLResourceValues?) -> ScannedItem? {
        guard let kind = MediaKind(fileExtension: (realName as NSString).pathExtension) else { return nil }
        let stubSize = Int64(values?.fileSize ?? 0)
        let logicalSize = ICloudPlaceholder.logicalSize(ofPlaceholderAt: url, stubSize: stubSize) ?? 0
        let item = MediaItem(
            location: .file(url),
            kind: kind,
            byteSize: logicalSize,
            filename: realName,
            creationDate: values?.creationDate,
            modificationDate: values?.contentModificationDate,
            isLocallyAvailable: false,
            hints: [.iCloudPlaceholder]
        )
        return ScannedItem(
            item: item,
            fingerprint: ScanFingerprint(byteSize: stubSize, modificationDate: values?.contentModificationDate)
        )
    }

    private static func isLocallyAvailable(_ values: URLResourceValues?) -> Bool? {
        #if canImport(Darwin)
        if values?.isUbiquitousItem == true {
            guard let status = values?.ubiquitousItemDownloadingStatus else { return nil }
            return status != .notDownloaded
        }
        #endif
        return values == nil ? nil : true
    }
}

/// iCloud Drive's `.Name.ext.icloud` stand-ins for files that are not downloaded.
public enum ICloudPlaceholder {
    private static let maxStubSize: Int64 = 64 * 1024

    /// `".IMG_0001.HEIC.icloud"` becomes `"IMG_0001.HEIC"`; anything else returns `nil`.
    public static func realName(forPlaceholderName name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let inner = name.dropFirst().dropLast(".icloud".count)
        return inner.isEmpty ? nil : String(inner)
    }

    /// Reads the size of the real file from the stub's property list.
    public static func logicalSize(ofPlaceholderAt url: URL, stubSize: Int64) -> Int64? {
        guard stubSize > 0, stubSize <= maxStubSize,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        if let size = plist["NSURLFileSizeKey"] as? Int64 { return size }
        if let size = plist["NSURLFileSizeKey"] as? Int { return Int64(size) }
        if let size = plist["NSURLFileSizeKey"] as? NSNumber { return size.int64Value }
        return nil
    }
}
