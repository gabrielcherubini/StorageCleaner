# StorageCleaner

A native SwiftUI app for macOS 14+ and iOS 17+ that finds heavy, duplicate and throwaway media in
iCloud Photos and iCloud Drive and helps you clear it out.

## Safety model

StorageCleaner never deletes anything permanently.

- `StorageCleaner/Services/TrashService.swift` is the only code that can remove media. Photos go to
  **Recently Deleted** (`PHAssetChangeRequest.deleteAssets`, kept 30 days, with the system's own
  confirmation dialog); files go to the **Trash** (`FileManager.trashItem`).
- `TrashService` only accepts a `ConfirmedTrashPlan`, which can only be created by confirming a
  `TrashPlan` with the exact item count and total size the user saw on the confirm sheet.
- `scripts/check-no-permanent-delete.sh` fails CI (and the Xcode build, as a pre-build phase) if
  any permanent-deletion API appears anywhere, or if trash APIs appear outside `TrashService`.
  `scripts/test-safety-guard.sh` checks the guard itself.
- Scanning is read-only. The guard also fails if code under `StorageCleaner/Scanning/` or
  `StorageCleanerCore/Sources/StorageCleanerCore/Scanning/` writes, moves or changes files, changes
  the photo library, or requests iCloud downloads.

## Scanning

- **iCloud Photos**: PhotoKit, read-only metadata (size of all resources, dimensions, duration,
  dates, favorite/edited/shared flags, subtype hints such as screenshots and Live Photos).
- **iCloud Drive**: the user picks a folder (normally iCloud Drive) with the system folder picker
  on macOS and iOS; access is kept with a security-scoped bookmark. Files that are not downloaded
  are indexed from metadata or their `.icloud` placeholder without downloading them.
- **Index**: results are cached in SwiftData. Rescans compare a cheap fingerprint (modification
  date, plus size for files) and only re-read new or changed items; rows for items that vanished are
  dropped from the index.
- **Duplicates**: exact copies are found by size first, then SHA-256. Similar photos are compared
  with Vision feature prints within a 15-minute window, similar videos by duration plus keyframe
  hashes, and similar audio by duration plus a loudness curve. The suggested keeper is a favorite,
  then the highest resolution, then the oldest copy; favorites, shared and edited items are never
  suggested for removal. Analysis only reads data, caches its results in the index, and skips
  iCloud-only items unless "Download iCloud originals for analysis" is turned on.
- The overview lists everything heaviest first, with a running potential-savings total (for now,
  non-protected files of 50 MB or more; later analyzers add more categories).

## Layout

| Path | What |
| --- | --- |
| `StorageCleaner/` | Multiplatform SwiftUI app target (macOS + iOS) |
| `StorageCleanerTests/` | App unit tests (hosted) |
| `StorageCleanerCore/` | Pure-Swift package with models, scoring and grouping logic; builds and tests on Linux |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec for `StorageCleaner.xcodeproj` |
| `scripts/` | Safety guard and its self-test |

## Development

```sh
# Core logic (macOS or Linux)
cd StorageCleanerCore && swift test

# Safety guard
scripts/test-safety-guard.sh && scripts/check-no-permanent-delete.sh

# App (macOS with Xcode)
open StorageCleaner.xcodeproj
```

`StorageCleaner.xcodeproj` is generated from `project.yml`. After adding targets or changing build
settings, run `xcodegen generate` (`brew install xcodegen`) and commit both files; CI fails if they
drift. Adding or removing Swift files under existing folders also needs a regenerate.

To run on a device, pick your team under Signing & Capabilities. The app needs Photos "Full Access".
