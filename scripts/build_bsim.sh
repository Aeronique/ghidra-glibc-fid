#!/usr/bin/env bash
#
# build_bsim.sh
# Build a BSim similarity database from the glibc programs already analyzed in
# the Ghidra project. BSim complements Function ID: it matches on decompiled
# structure and data references, so it can distinguish thin wrappers like printf
# from wscanf, and it tolerates compiler and version drift that breaks exact
# hashing.
#
# HOW IT WORKS
#   1. createdatabase: makes an H2 file-backed BSim database with the
#      medium_nosize template (nosize allows 32-bit and 64-bit to match).
#   2. generatesigs: decompiles every function in the project and writes XML
#      signature files. This is the slow part.
#   3. commitsigs: loads those signatures into the database.
#
# REUSES existing work: it signs the programs already imported and analyzed by
# build_import.sh, all glibc versions and both arches. No re-import.
#
# REQUIREMENTS
#   Ghidra 12.1.2 install (step 2), the analyzed project (step 3a), a JDK.
#   The project must not be open in a GUI. H2 allows only one process at a time.
#
# USAGE
#   cd ~/ctf/tools/ghidra-glibc-fid
#   ./scripts/build_bsim.sh
#   (long-running; to detach: nohup ./scripts/build_bsim.sh > bsim.log 2>&1 & )
#
# EXPECTED OUTPUT
#   A BSim H2 database at ../bsim/glibc.mv.db and progress from each phase. When
#   done, copy that .mv.db to Windows and register it in the GUI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$(cd "$REPO_DIR/.." && pwd)"

GHIDRA_DIR="$TOOLS_DIR/ghidra_12.1.2_PUBLIC"
BSIM="$GHIDRA_DIR/support/bsim"

PROJ_DIR="$REPO_DIR/fidproject"
PROJ_NAME="glibc-fid"
PROJ_URL="ghidra:$PROJ_DIR/$PROJ_NAME"          # one slash: ghidra:/home/...

BSIM_DIR="$TOOLS_DIR/bsim"
DB_PATH="$BSIM_DIR/glibc"                        # H2 creates glibc.mv.db
DB_URL="file:$DB_PATH"                           # file:/home/...
SIGS_DIR="$REPO_DIR/bsim_sigs"

if [ ! -x "$BSIM" ]; then
  echo "!! bsim launcher not found at $BSIM"
  exit 1
fi
if [ ! -d "$PROJ_DIR/$PROJ_NAME.rep" ]; then
  echo "!! Project not found at $PROJ_DIR/$PROJ_NAME. Run build_import.sh first."
  exit 1
fi

mkdir -p "$BSIM_DIR" "$SIGS_DIR"

echo ">> Ghidra:    $GHIDRA_DIR"
echo ">> Project:   $PROJ_URL"
echo ">> BSim DB:   $DB_URL  (file: $DB_PATH.mv.db)"
echo ">> Sigs dir:  $SIGS_DIR"
echo ""

if [ -f "$DB_PATH.mv.db" ]; then
  echo ">> A BSim database already exists at $DB_PATH.mv.db"
  echo "   Delete it first for a clean rebuild, then rerun."
  exit 1
fi

echo ">> [1/3] Creating H2 database (medium_nosize) ..."
"$BSIM" createdatabase "$DB_URL" medium_nosize

echo ""
echo ">> [2/3] Generating signatures (this is the long part) ..."
rm -f "$SIGS_DIR"/*.xml 2>/dev/null || true
"$BSIM" generatesigs "$PROJ_URL" "$SIGS_DIR" --bsim "$DB_URL"

echo ""
echo ">> [3/3] Committing signatures ..."
"$BSIM" commitsigs "$DB_URL" "$SIGS_DIR"

echo ""
echo ">> Done. BSim database at: $DB_PATH.mv.db"
if [ -f "$DB_PATH.mv.db" ]; then
  echo "   size: $(du -h "$DB_PATH.mv.db" | cut -f1)"
fi
echo "   Copy that .mv.db to Windows and register it in the GUI:"
echo "   File menu path is BSim, Manage Servers, add an H2 file database."
