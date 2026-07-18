#!/usr/bin/env bash
#
# build_import.sh
# Step 3a: import and analyze the glibc archives into a Ghidra project.
#
# WHAT IT DOES
#   Creates (or reuses) a headless Ghidra project and imports each real glibc
#   archive into a folder tree shaped as:
#       glibc-fid / glibc / <version> / <arch> / <archive> / <members>
#   Importing a .a with -recursive 1 expands it into its member object files,
#   and analysis runs on each so the functions have bodies to hash later.
#
#   The version for each image is read from that image's MANIFEST.txt so the
#   folder names are exact. Eight-byte stub archives (the merged libs on glibc
#   2.34+) are skipped automatically.
#
# WHY SEPARATE FROM POPULATE
#   Imports persist in the project. Keeping this apart from the populate step
#   means we run the slow part once and iterate the fast part freely.
#
# REQUIREMENTS
#   The Linux-side Ghidra from install_ghidra_linux.sh, and the archives from
#   pull_glibc.sh already present under glibc-archives/.
#
# USAGE
#   cd ~/ctf/tools/ghidra-glibc-fid
#   ./scripts/build_import.sh                 # import every source under glibc-archives/
#   ./scripts/build_import.sh arch-20250813   # import only that one label folder
#
#   This is long-running for the full set. To run it detached:
#     nohup ./scripts/build_import.sh > import.log 2>&1 &
#     tail -f import.log
#
# EXPECTED OUTPUT
#   One analyzeHeadless run per (version, arch) combination, each ending with an
#   "IMPORTING" / analysis summary. When done it prints a per-combo tally of how
#   many archives were imported. The project lands under fidproject/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$(cd "$REPO_DIR/.." && pwd)"

GHIDRA_DIR="$TOOLS_DIR/ghidra_12.1.2_PUBLIC"
HEADLESS="$GHIDRA_DIR/support/analyzeHeadless"

ARCHIVE_ROOT="$REPO_DIR/glibc-archives"
PROJ_LOC="$REPO_DIR/fidproject"
PROJ_NAME="glibc-fid"

# Minimum size to treat an archive as real. The merged-lib stubs are 8 bytes.
MIN_BYTES=100

# Optional first argument: import only this label folder (e.g. arch-20250813).
LABEL_FILTER="${1:-}"

if [ ! -x "$HEADLESS" ]; then
  echo "!! analyzeHeadless not found at $HEADLESS"
  echo "   Run scripts/install_ghidra_linux.sh first."
  exit 1
fi
if [ ! -d "$ARCHIVE_ROOT" ]; then
  echo "!! No glibc-archives/ found. Run scripts/pull_glibc.sh first."
  exit 1
fi

mkdir -p "$PROJ_LOC"

# Pull the glibc version string out of an image's MANIFEST.txt, e.g. "2.35".
version_from_manifest () {
  local manifest="$1"
  if [ -f "$manifest" ]; then
    grep -oE 'version [0-9]+\.[0-9]+' "$manifest" | tail -n1 | awk '{print $2}'
  fi
}

echo ">> Ghidra:   $GHIDRA_DIR"
echo ">> Project:  $PROJ_LOC/$PROJ_NAME"
echo ">> Archives: $ARCHIVE_ROOT"
echo ""

# Iterate each image folder, each arch, and import that arch's real archives in
# a single headless run so the JVM starts once per combo.
for label_dir in "$ARCHIVE_ROOT"/*/; do
  [ -d "$label_dir" ] || continue
  label="$(basename "$label_dir")"
  if [ -n "$LABEL_FILTER" ] && [ "$label" != "$LABEL_FILTER" ]; then
    continue
  fi
  version="$(version_from_manifest "$label_dir/MANIFEST.txt")"
  if [ -z "${version:-}" ]; then
    echo ">> Skipping $label, no version in MANIFEST.txt"
    continue
  fi

  for arch in x86_64 i386; do
    arch_dir="$label_dir$arch"
    [ -d "$arch_dir" ] || continue

    # Collect real .a archives (skip the tiny merged-lib stubs).
    mapfile -t archives < <(find "$arch_dir" -maxdepth 1 -type f -name '*.a' -size +${MIN_BYTES}c | sort)
    if [ "${#archives[@]}" -eq 0 ]; then
      echo ">> $label/$arch (glibc $version): no real archives, skipping"
      continue
    fi

    dest="$PROJ_NAME/glibc/$version/$arch"
    echo ">> Importing ${#archives[@]} archive(s) into $dest"
    for a in "${archives[@]}"; do
      echo "     $(basename "$a")"
    done

    # Build repeated -import args.
    import_args=()
    for a in "${archives[@]}"; do
      import_args+=(-import "$a")
    done

    "$HEADLESS" "$PROJ_LOC" "$dest" \
      "${import_args[@]}" \
      -recursive 1 \
      -analysisTimeoutPerFile 180 \
      -scriptlog "$REPO_DIR/import-ghidra.log"

    echo "   done: $label/$arch"
    echo ""
  done
done

echo ">> Import phase complete."
echo "   Project: $PROJ_LOC/$PROJ_NAME"
echo "   Next: the populate step turns these into named FID libraries."
