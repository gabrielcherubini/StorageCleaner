#!/usr/bin/env bash
# Fails if source code can permanently delete user data, or if anything other than
# TrashService touches the move-to-trash APIs.
#
#   scripts/check-no-permanent-delete.sh [repo-root]
#
# Rule 1 applies to every source file, TrashService included: permanent-deletion and
# destructive file APIs are banned outright.
# Rule 2: trash / Recently Deleted APIs, and PhotoKit change requests, may only appear in
# TrashService.swift.
# Rule 3: scanner and analysis code is read-only. Files under READ_ONLY_DIRS may not write, move
# or change attributes of files. Scanner code (SCAN_ONLY_DIRS) additionally may not download iCloud
# originals or request media data at all.
# Rule 4: iCloud downloads are opt-in. `isNetworkAccessAllowed = true` is banned everywhere; it
# must come from the user's setting.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TRASH_SERVICE="StorageCleaner/Services/TrashService.swift"

# Start-of-word anchor; BSD grep on macOS has no portable \b in extended regexes.
W='(^|[^[:alnum:]_])'

PERMANENT_DELETE_PATTERNS=(
  'removeItem'                             # FileManager.removeItem(at:/atPath:), removeItemAtPath/URL
  "${W}unlink(at)?[[:space:]]*\\("          # unlink(2), unlinkat(2)
  "${W}rmdir[[:space:]]*\\("                # rmdir(2)
  "${W}removefile[[:space:]]*\\("           # removefile(3)
  "${W}(Darwin|Glibc|Foundation)\\.remove[[:space:]]*\\("  # C remove(3)
  '/bin/rm([^[:alnum:]_]|$)'               # shelling out to rm
  '"rm"'
  'emptyTrash'
  'replaceItem'                            # FileManager.replaceItem(at:withItemAt:) destroys the original
  "${W}f?truncate[[:space:]]*\\("           # truncate(2), ftruncate(2), FileHandle.truncate(atOffset:)
)

TRASH_ONLY_PATTERNS=(
  'deleteAssets'                           # PHAssetChangeRequest.deleteAssets -> Recently Deleted
  'deleteAssetCollections'
  'deleteCollectionLists'
  'trashItem'                              # FileManager.trashItem -> Trash
  "${W}recycle[[:space:]]*\\("              # NSWorkspace.recycle -> Trash
  'performChanges'                         # PHPhotoLibrary.performChanges(AndWait)
  'ChangeRequest'                          # PHAssetChangeRequest, PHAssetCollectionChangeRequest, ...
)

READ_ONLY_DIRS=(
  "StorageCleaner/Scanning/"
  "StorageCleanerCore/Sources/StorageCleanerCore/Scanning/"
  "StorageCleaner/Analysis/"
  "StorageCleanerCore/Sources/StorageCleanerCore/Duplicates/"
)

SCAN_ONLY_DIRS=(
  "StorageCleaner/Scanning/"
  "StorageCleanerCore/Sources/StorageCleanerCore/Scanning/"
)

READ_ONLY_PATTERNS=(
  '\.write\('                                # Data/String.write(to:)
  'createFile'
  'createDirectory'
  'moveItem'
  'copyItem'
  'linkItem'
  'createSymbolicLink'
  'setAttributes'
  'setResourceValue'                       # URL.setResourceValue(s)
  'forWriting'                             # FileHandle(forWritingTo:), AVAudioFile(forWriting:)
  'forUpdating'                            # FileHandle(forUpdating:)
  'writeData'                              # PHAssetResourceManager.writeData(for:toFile:)
  'AVAssetWriter'
  'AVAssetExportSession'
  'startDownloadingUbiquitousItem'
  'evictUbiquitousItem'
  'setUbiquitous'
)

SCAN_ONLY_PATTERNS=(
  'isNetworkAccessAllowed'                 # lets PhotoKit download iCloud originals
  'PHAssetResourceManager'
  'requestImage'
  'requestAVAsset'
  'requestPlayerItem'
  'requestExportSession'
  'requestLivePhoto'
  'requestContentEditingInput'
)

NETWORK_OPT_IN_PATTERN='isNetworkAccessAllowed[[:space:]]*=[[:space:]]*true'

FILES=()
while IFS= read -r -d '' file; do FILES+=("$file"); done < <(
  find "$ROOT" \
    \( -name .git -o -name .build -o -name DerivedData -o -name '*.xcodeproj' -o -name '*.xcworkspace' \) -prune -o \
    -type f \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.c' -o -name '*.h' \) -print0
)

violations=0

report() {
  local match="$1" message="$2"
  local file="${match%%:*}" rest="${match#*:}"
  local line="${rest%%:*}" text="${rest#*:}"
  local rel="${file#"$ROOT"/}"
  echo "::error file=${rel},line=${line}::${message}: ${text#"${text%%[![:space:]]*}"}"
  violations=$((violations + 1))
}

if [[ ${#FILES[@]} -gt 0 ]]; then
  for pattern in "${PERMANENT_DELETE_PATTERNS[@]}"; do
    while IFS= read -r match; do
      [[ -n "$match" ]] && report "$match" "Permanent-deletion API is banned everywhere (/${pattern}/)"
    done < <(grep -nHE -- "$pattern" "${FILES[@]}" || true)
  done

  for pattern in "${TRASH_ONLY_PATTERNS[@]}"; do
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      file="${match%%:*}"
      [[ "${file#"$ROOT"/}" == "$TRASH_SERVICE" ]] && continue
      report "$match" "Trash APIs may only be used in ${TRASH_SERVICE} (/${pattern}/)"
    done < <(grep -nHE -- "$pattern" "${FILES[@]}" || true)
  done

  while IFS= read -r match; do
    [[ -n "$match" ]] && report "$match" "iCloud downloads must be opt-in; set isNetworkAccessAllowed from the user's setting"
  done < <(grep -nHE -- "$NETWORK_OPT_IN_PATTERN" "${FILES[@]}" || true)

  READ_ONLY_FILES=()
  SCAN_ONLY_FILES=()
  for file in "${FILES[@]}"; do
    rel="${file#"$ROOT"/}"
    for dir in "${READ_ONLY_DIRS[@]}"; do
      if [[ "$rel" == "$dir"* ]]; then READ_ONLY_FILES+=("$file"); break; fi
    done
    for dir in "${SCAN_ONLY_DIRS[@]}"; do
      if [[ "$rel" == "$dir"* ]]; then SCAN_ONLY_FILES+=("$file"); break; fi
    done
  done

  if [[ ${#READ_ONLY_FILES[@]} -gt 0 ]]; then
    for pattern in "${READ_ONLY_PATTERNS[@]}"; do
      while IFS= read -r match; do
        [[ -n "$match" ]] && report "$match" "Scanner and analysis code must be read-only (/${pattern}/)"
      done < <(grep -nHE -- "$pattern" "${READ_ONLY_FILES[@]}" || true)
    done
  fi

  if [[ ${#SCAN_ONLY_FILES[@]} -gt 0 ]]; then
    for pattern in "${SCAN_ONLY_PATTERNS[@]}"; do
      while IFS= read -r match; do
        [[ -n "$match" ]] && report "$match" "Scanner code may not download or request media data (/${pattern}/)"
      done < <(grep -nHE -- "$pattern" "${SCAN_ONLY_FILES[@]}" || true)
    done
  fi
fi

if [[ $violations -gt 0 ]]; then
  echo "Safety guard failed: ${violations} violation(s). All removal must go through TrashService, which only moves items to Recently Deleted or the Trash." >&2
  exit 1
fi

echo "Safety guard passed: scanned ${#FILES[@]} source file(s); no permanent-deletion APIs, trash APIs only in ${TRASH_SERVICE}, scanner and analysis code read-only, iCloud downloads opt-in."
