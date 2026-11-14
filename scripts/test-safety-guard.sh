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

if [[ $failures -gt 0 ]]; then
  echo "$failures safety guard self-test(s) failed" >&2
  exit 1
fi
echo "All safety guard self-tests passed."
