#!/usr/bin/env bash
# Fails if source code can permanently delete user data, or if anything other than
# TrashService touches the move-to-trash APIs.
#
#   scripts/check-no-permanent-delete.sh [repo-root]
#
# Rule 1 applies to every source file, TrashService included: permanent-deletion and
# destructive file APIs are banned outright.
# Rule 2: trash / Recently Deleted APIs may only appear in TrashService.swift.
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
)

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
fi

if [[ $violations -gt 0 ]]; then
  echo "Safety guard failed: ${violations} violation(s). All removal must go through TrashService, which only moves items to Recently Deleted or the Trash." >&2
  exit 1
fi

echo "Safety guard passed: scanned ${#FILES[@]} source file(s); no permanent-deletion APIs, trash APIs only in ${TRASH_SERVICE}."
