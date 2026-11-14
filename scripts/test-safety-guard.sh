#!/usr/bin/env bash
# Self-test for check-no-permanent-delete.sh: builds throwaway fixture trees and checks
# that the guard accepts safe code and rejects each kind of violation.
set -euo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-no-permanent-delete.sh"
WORK="$(mktemp -d)"
trap 'rm -r "$WORK"' EXIT

failures=0

fixture() {
  local name="$1" path="$2" body="$3"
  local root="$WORK/$name"
  mkdir -p "$root/StorageCleaner/Services" "$(dirname "$root/$path")"
  printf 'struct Placeholder {}\n' > "$root/StorageCleaner/Services/TrashService.swift"
  printf '%s\n' "$body" > "$root/$path"
  echo "$root"
}

expect() {
  local expected="$1" name="$2" path="$3" body="$4"
  local root
  root="$(fixture "$name" "$path" "$body")"
  if "$GUARD" "$root" > /dev/null 2>&1; then actual=pass; else actual=fail; fi
  if [[ "$actual" == "$expected" ]]; then
    echo "ok   - $name ($expected)"
  else
    echo "FAIL - $name: expected $expected, got $actual"
    failures=$((failures + 1))
  fi
}

expect pass clean            StorageCleaner/Foo.swift  'let size = items.reduce(0) { $0 + $1.byteSize }'
expect pass swiftdata-delete StorageCleaner/Index.swift 'modelContext.delete(record)'
expect pass array-remove     StorageCleaner/Foo.swift  'selection.remove(at: 0); set.remove(item)'
expect pass trash-in-service StorageCleaner/Services/TrashService.swift 'try FileManager.default.trashItem(at: url, resultingItemURL: nil)
PHAssetChangeRequest.deleteAssets(assets)'

expect fail remove-item          StorageCleaner/Foo.swift 'try FileManager.default.removeItem(at: url)'
expect fail remove-item-path     StorageCleanerCore/Sources/X.swift 'try fm.removeItem(atPath: path)'
expect fail remove-in-service    StorageCleaner/Services/TrashService.swift 'try FileManager.default.removeItem(at: url)'
expect fail unlink               StorageCleaner/Foo.swift 'unlink(path)'
expect fail objc-remove          StorageCleaner/Legacy.m '[fm removeItemAtPath:path error:nil];'
expect fail c-remove             StorageCleaner/Foo.swift '_ = Darwin.remove(path)'
expect fail shell-rm             StorageCleaner/Foo.swift 'process.executableURL = URL(fileURLWithPath: "/bin/rm")'
expect fail truncate             StorageCleaner/Foo.swift 'try handle.truncate(atOffset: 0)'
expect fail trash-outside        StorageCleaner/Foo.swift 'try FileManager.default.trashItem(at: url, resultingItemURL: nil)'
expect fail delete-assets-outside StorageCleaner/Views/Grid.swift 'PHAssetChangeRequest.deleteAssets(assets)'
expect fail recycle-outside      StorageCleaner/Foo.swift 'NSWorkspace.shared.recycle([url])'
expect fail change-request-outside StorageCleaner/Foo.swift 'PHAssetChangeRequest(for: asset).isFavorite = false'
expect fail perform-changes-outside StorageCleaner/Foo.swift 'try await PHPhotoLibrary.shared().performChanges { }'

expect pass scanner-reads        StorageCleaner/Scanning/PhotoScanner.swift 'let values = try url.resourceValues(forKeys: keys); let data = try Data(contentsOf: stub)'
expect pass write-outside-scanner StorageCleaner/Log/DecisionLog.swift 'try data.write(to: logURL)'
expect fail scanner-write        StorageCleaner/Scanning/PhotoScanner.swift 'try data.write(to: url)'
expect fail scanner-move         StorageCleanerCore/Sources/StorageCleanerCore/Scanning/X.swift 'try fm.moveItem(at: a, to: b)'
expect fail scanner-attributes   StorageCleaner/Scanning/X.swift 'try url.setResourceValues(values)'
expect fail scanner-download     StorageCleaner/Scanning/X.swift 'try fm.startDownloadingUbiquitousItem(at: url)'
expect fail scanner-network      StorageCleaner/Scanning/X.swift 'options.isNetworkAccessAllowed = true'
expect fail scanner-request-data StorageCleaner/Scanning/X.swift 'PHAssetResourceManager.default().requestData(for: resource, options: nil) { _ in } completionHandler: { _ in }'

expect pass analysis-reads-opt-in StorageCleaner/Analysis/X.swift 'options.isNetworkAccessAllowed = allowDownloads
PHAssetResourceManager.default().requestData(for: r, options: options) { _ in } completionHandler: { _ in }
let handle = try FileHandle(forReadingFrom: url)'
expect fail network-always-on    StorageCleaner/Analysis/X.swift 'options.isNetworkAccessAllowed = true'
expect fail network-always-on-ui StorageCleaner/Views/X.swift 'opts.isNetworkAccessAllowed=true'
expect fail analysis-write       StorageCleaner/Analysis/X.swift 'try data.write(to: cacheURL)'
expect fail analysis-export      StorageCleaner/Analysis/X.swift 'let session = AVAssetExportSession(asset: asset, presetName: preset)'
expect fail analysis-write-resource StorageCleaner/Analysis/X.swift 'PHAssetResourceManager.default().writeData(for: r, toFile: url, options: nil) { _ in }'
expect fail core-duplicates-write StorageCleanerCore/Sources/StorageCleanerCore/Duplicates/X.swift 'FileManager.default.createFile(atPath: p, contents: d)'

if [[ $failures -gt 0 ]]; then
  echo "$failures safety guard self-test(s) failed" >&2
  exit 1
fi
echo "All safety guard self-tests passed."
