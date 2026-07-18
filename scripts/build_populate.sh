#!/usr/bin/env bash
#
# build_populate.sh
# Step 3b: create the FID database and populate it from the imported archives.
#
# WHAT IT DOES
#   Runs PopulateGlibcFid.java headless against the project built in step 3a.
#   That script creates a fresh glibc.fidb, then walks /glibc/<version>/<arch>
#   and creates one FID library per version and arch, inferring the language
#   from the arch folder. It prints a per-library count and a final total.
#
# HOW IT RUNS ONCE
#   A headless -postScript normally runs once per imported file. To trigger it a
#   single time we import one tiny sentinel object (a crtn.o already on disk)
#   into a throwaway /_trigger folder. The populate script ignores that program
#   and operates on the whole project.
#
# REQUIREMENTS
#   Step 3a finished (project under fidproject/), Ghidra installed (step 2).
#
# USAGE
#   cd ~/ctf/tools/ghidra-glibc-fid
#   ./scripts/build_populate.sh                              # full db -> glibc.fidb
#   ./scripts/build_populate.sh ../glibc-arch.fidb 2.42      # test db, one version
#   (args: [output_fidb_path] [version_filter])
#
# EXPECTED OUTPUT
#   Lines like "glibc 2.35 x86_64 (x86:LE:64:default): 1583 programs" followed by
#   "added=..." per library, then "DONE: N libraries, M functions added". The
#   database lands at glibc.fidb in the repo root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$(cd "$REPO_DIR/.." && pwd)"

GHIDRA_DIR="$TOOLS_DIR/ghidra_12.1.2_PUBLIC"
HEADLESS="$GHIDRA_DIR/support/analyzeHeadless"

ARCHIVE_ROOT="$REPO_DIR/glibc-archives"
PROJ_LOC="$REPO_DIR/fidproject"
PROJ_NAME="glibc-fid"
SCRIPTS_DIR="$REPO_DIR/ghidra_scripts"
# Optional args: output fidb path, and a version filter (populate one version only).
FIDB="${1:-$REPO_DIR/glibc.fidb}"
VERSION_FILTER="${2:-}"
# Resolve FIDB to an absolute path.
FIDB="$(cd "$(dirname "$FIDB")" && pwd)/$(basename "$FIDB")"

if [ ! -x "$HEADLESS" ]; then
  echo "!! analyzeHeadless not found at $HEADLESS"
  exit 1
fi
if [ ! -d "$PROJ_LOC/$PROJ_NAME.rep" ]; then
  echo "!! Project not found at $PROJ_LOC/$PROJ_NAME. Run build_import.sh first."
  exit 1
fi

# A tiny valid object to trigger the postScript exactly once.
SENTINEL="$(find "$ARCHIVE_ROOT" -type f -name 'crtn.o' | head -n1)"
if [ -z "$SENTINEL" ]; then
  SENTINEL="$(find "$ARCHIVE_ROOT" -type f -name '*.o' | head -n1)"
fi
if [ -z "$SENTINEL" ]; then
  echo "!! No .o sentinel found under $ARCHIVE_ROOT"
  exit 1
fi

echo ">> Ghidra:   $GHIDRA_DIR"
echo ">> Project:  $PROJ_LOC/$PROJ_NAME"
echo ">> Script:   $SCRIPTS_DIR/PopulateGlibcFid.java"
echo ">> Database: $FIDB"
echo ">> Sentinel: $SENTINEL"
echo ""

POST_ARGS=(PopulateGlibcFid.java "$FIDB")
if [ -n "$VERSION_FILTER" ]; then
  POST_ARGS+=("$VERSION_FILTER")
  echo ">> Version filter: $VERSION_FILTER"
fi

"$HEADLESS" "$PROJ_LOC" "$PROJ_NAME/_trigger" \
  -import "$SENTINEL" \
  -overwrite \
  -noanalysis \
  -scriptPath "$SCRIPTS_DIR" \
  -postScript "${POST_ARGS[@]}" \
  -scriptlog "$REPO_DIR/populate.log"

echo ""
echo ">> Populate finished. Database at: $FIDB"
echo "   Look above for the per-library counts and the DONE line."
if [ -f "$FIDB" ]; then
  echo "   fidb size: $(du -h "$FIDB" | cut -f1)"
fi
