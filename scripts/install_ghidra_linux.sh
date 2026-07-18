#!/usr/bin/env bash
#
# install_ghidra_linux.sh
# Install a Linux-side Ghidra that matches the Windows GUI version, so the
# Function ID database we build here loads cleanly in both.
#
# WHY A SECOND GHIDRA
#   We build the FID database headless on the Linux side, where the glibc
#   archives already live, without disturbing the running Windows GUI. The
#   resulting .fidb is a plain file that the Windows Ghidra can attach and use.
#   Database format is tied to the major version, so this install is pinned to
#   12.1.2 to match the GUI.
#
# REQUIREMENTS
#   curl or wget, unzip, and a JDK (OpenJDK 25 is already present).
#   Network access to github.com.
#
# USAGE
#   cd ~/ctf/tools/ghidra-glibc-fid
#   ./scripts/install_ghidra_linux.sh
#
# EXPECTED OUTPUT
#   Downloads the release zip to tools/, verifies its SHA-256, extracts it to
#   tools/ghidra_12.1.2_PUBLIC/, then prints the analyzeHeadless path and the
#   Ghidra launch banner. Re-running is safe. It skips the download when a
#   verified zip is already present and skips extraction when the folder exists.

set -euo pipefail

VERSION="12.1.2"
RELEASE_TAG="Ghidra_12.1.2_build"
ZIP_NAME="ghidra_12.1.2_PUBLIC_20260605.zip"
SHA256="b62e81a0390618466c019c60d8c2f796ced2509c4c1aea4a37644a77272cf99d"
URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/${RELEASE_TAG}/${ZIP_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Install one level up from the repo so the 570 MB install is not inside the
# git tree. tools/ is the parent of this repo.
TOOLS_DIR="$(cd "$REPO_DIR/.." && pwd)"
ZIP_PATH="$TOOLS_DIR/$ZIP_NAME"
INSTALL_DIR="$TOOLS_DIR/ghidra_12.1.2_PUBLIC"

echo ">> Target install: $INSTALL_DIR"

# Preflight: required tools.
need () { command -v "$1" >/dev/null 2>&1; }
if ! need unzip; then
  echo "!! unzip not found. Install it first: sudo apt-get install -y unzip"
  exit 1
fi
if ! need java; then
  echo "!! java not found on PATH."
  exit 1
fi
if ! need javac; then
  echo "!! javac not found. Ghidra needs a full JDK, not just a JRE, because it"
  echo "   compiles scripts at run time. Install one, e.g.:"
  echo "     sudo apt-get install -y openjdk-25-jdk   (or default-jdk)"
  exit 1
fi

verify () {
  echo "$SHA256  $ZIP_PATH" | sha256sum -c - >/dev/null 2>&1
}

# Download unless a verified copy already exists.
if [ -f "$ZIP_PATH" ] && verify; then
  echo ">> Zip already present and verified, skipping download."
else
  echo ">> Downloading $ZIP_NAME (about 573 MB) ..."
  if need curl; then
    curl -L --fail -o "$ZIP_PATH" "$URL"
  else
    wget -O "$ZIP_PATH" "$URL"
  fi
  echo ">> Verifying SHA-256 ..."
  if ! verify; then
    echo "!! Checksum mismatch. Deleting the bad download."
    rm -f "$ZIP_PATH"
    exit 1
  fi
  echo ">> Checksum OK."
fi

# Extract unless already extracted.
if [ -d "$INSTALL_DIR" ]; then
  echo ">> Install dir already exists, skipping extract."
else
  echo ">> Extracting ..."
  unzip -q "$ZIP_PATH" -d "$TOOLS_DIR"
fi

HEADLESS="$INSTALL_DIR/support/analyzeHeadless"
if [ ! -x "$HEADLESS" ]; then
  chmod +x "$HEADLESS" 2>/dev/null || true
fi

echo ""
echo ">> Done."
echo "   GHIDRA_INSTALL_DIR = $INSTALL_DIR"
echo "   analyzeHeadless    = $HEADLESS"
echo ""
echo ">> Launch check (version banner):"
"$INSTALL_DIR/support/launch.sh" fg jre Ghidra "" "" ghidra.GhidraLauncher --help >/dev/null 2>&1 || true
ls -1 "$INSTALL_DIR" | sed 's/^/   /'
echo ""
echo ">> Paste back the two paths above and the folder listing."
