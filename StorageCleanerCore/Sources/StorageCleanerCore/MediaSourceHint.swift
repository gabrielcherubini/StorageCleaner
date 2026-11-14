import Foundation

/// Cheap, scan-time signals about where an item came from. Analyzers use them later; the scanner
/// only records them.
public enum MediaSourceHint: String, Codable, Sendable, CaseIterable {
    // Photo library origin (PHAssetSourceType)
    case userLibrary
    case cloudShared
    case iTunesSynced

    // PHAssetMediaSubtype and related asset flags
    case screenshot
    case screenRecording
    case livePhoto
    case panorama
    case hdr
    case depthEffect
    case highFrameRate
    case timelapse
    case burst

    // File-level signals
    case iCloudPlaceholder
}
