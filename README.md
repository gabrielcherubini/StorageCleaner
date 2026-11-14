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
