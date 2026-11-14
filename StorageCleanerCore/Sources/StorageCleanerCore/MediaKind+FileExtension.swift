import Foundation

extension MediaKind {
    private static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "avif",
        "dng", "raw", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw", "pef",
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp", "3g2", "mts", "m2ts", "mpg", "mpeg", "wmv",
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "aifc", "flac", "alac", "ogg", "oga",
        "opus", "caf", "amr", "wma",
    ]

    /// Media kind for a filename extension, or `nil` for anything that is not photo, video or audio.
    public init?(fileExtension: String) {
        let ext = fileExtension.lowercased()
        if Self.photoExtensions.contains(ext) {
            self = .photo
        } else if Self.videoExtensions.contains(ext) {
            self = .video
        } else if Self.audioExtensions.contains(ext) {
            self = .audio
        } else {
            return nil
        }
    }
}
