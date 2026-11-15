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
- Analysis is read-only too: code under `StorageCleaner/Analysis/` and the Core `Duplicates/` and
  `Classifiers/` folders may not write, move or change files, and nothing may turn on network access
  for media requests except the user's "Download iCloud originals" setting.

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
- **Categories**: each item can get a category with a confidence and the reasons behind it:
  - *Chat & app forwards*: WhatsApp/Telegram/Signal/Messenger file names, no camera make/model
    (only the first 1 MB of a photo is read to check), messenger resize sizes, batches of saves.
  - *Screenshots & recordings*: the Photos screenshot/screen-recording flags, screenshot file names
    (English and Portuguese), screen-native sizes without camera info.
  - *Receipts & documents*: Vision document detection, then Vision text recognition (pt-BR and
    en-US) only for likely documents (accurate pass) or bright, paper-like photos (fast pass), scored on Portuguese/BRL and English receipt words, `R$`
    amounts and CNPJ/CPF numbers.
  - *Low quality*: blur (Laplacian variance), too dark or overexposed, ground/pocket shots (almost
    no detail), very short or nearly still videos, very short or nearly silent audio.

  Each category is split into **Likely to delete** (confidence above the category's threshold) and
  **Likely to keep**. Favorites, shared and edited items always go to Likely to keep and are never
  pre-selected. The scoring lives in `StorageCleanerCore/Sources/StorageCleanerCore/Classifiers/`;
  the same read-only and opt-in download rules apply, and results are cached with the signatures.
## Review and trash

- **Dashboard**: storage used per kind, potential savings per category (each opens its review
  screen), and the heaviest items.
- **Review screens**: a grid with size badges for each category (Likely to delete / Likely to
  keep), large files and heaviest items; duplicate groups with a side-by-side compare view. Filter
  by size, date and kind; sort by size or date; tap to override any item; bulk select skips
  favorites, shared and edited items, which are never pre-selected. Tiles are fixed-size squares
  that crop the preview, so no orientation or aspect ratio changes the layout.
- **Why each item is where it is**: every tile states its verdict ("94% sure · needs 85%",
  "Protected · Favorite", "Older than 30 days"); long-press (or hover on macOS) and the viewer show
  the full sentence and the classifier's signals.
- **Viewer**: tap any preview to open it full screen (a sheet on macOS): zoom and pan photos, play
  videos and audio, swipe or use the arrow keys between items, and switch Keep / Move to Trash.
  Previews of iCloud-only items load only when "Download iCloud originals" is on.
- **Review Rules** (Settings, or the slider button on a category screen), stored in
  `ReviewPreferences` and applied to the current results right away:
  - strictness per category: Conservative / Balanced / Aggressive, mapped to the confidence needed
    for "Likely to delete" (Balanced keeps the built-in thresholds);
  - pre-selection on or off per category, including extra duplicate copies;
  - "Always keep receipts newer than N months" and "Screenshots older than N days are likely to
    delete", both off by default.

  Favorites, shared and edited items stay in "Likely to keep" whatever the rules say.
- **Confirm sheet**: shows the exact count and total size, split into Photos (Recently Deleted,
  30 days, with the system's own prompt) and iCloud Drive files (Trash). The confirmation echoes
  those numbers, so a changed selection moves nothing.
- `TrashCoordinator` then calls `TrashService`, opening each iCloud Drive file's folder security
  scope (`FolderAccess`, shared with analysis), drops moved items from the index and results, and
  shows a summary reminding that items stay in Recently Deleted / Trash.
- **Decision log** (optional, off by default): each confirmed action is appended to
  `Application Support/StorageCleaner/decision-log.json` with what moved where and why.

- The dashboard lists everything heaviest first, with a running potential-savings total: large
  files (50 MB+), duplicates suggested for removal and items likely to delete in each category,
  each item counted once.

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

Debug builds accept `-demo` (optionally `-demoScreen grid|videos|duplicates|viewer|confirm|rules`)
to show a generated sample library from the app's temporary folder in an in-memory index; CI uses it
for iOS Simulator screenshots (the `ios-screenshots` artifact). `scripts/make-app-icon.py` renders
the app icon.

To run on a device, pick your team under Signing & Capabilities. The app needs Photos "Full Access".
