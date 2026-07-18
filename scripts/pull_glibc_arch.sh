#!/usr/bin/env bash
#
# pull_glibc_arch.sh
# Stage a static glibc archive from the Arch Linux Archive for an exact match
# against a binary built on Arch.
#
# WHY
#   Ubuntu glibc does not match binaries built on rolling distros. Arch keeps a
#   dated archive of every package it shipped, so pulling glibc from the build
#   date gives the exact library the author linked, byte for byte, which is what
#   Function ID needs for an exact hash match.
#
#   Anchor the date to the binary's compiler stamp. This target shows
#   "GCC 15.2.1 20250813", so DATE defaults to 2025/08/13.
#
# REQUIREMENTS
#   curl, and one of: bsdtar (from libarchive-tools) or tar with zstd support.
#   Network access to archive.archlinux.org.
#
# USAGE
#   cd ~/ctf/tools/ghidra-glibc-fid
#   ./scripts/pull_glibc_arch.sh                 # uses DATE below
#   ./scripts/pull_glibc_arch.sh 2025/08/14      # override the date
#
# EXPECTED OUTPUT
#   glibc-archives/arch-<date>/x86_64/ with libc.a, libm.a, crt objects, and a
#   MANIFEST.txt naming the exact glibc version. Prints the version at the end
#   so we can confirm the match before the import step.

set -euo pipefail

DATE="${1:-2025/08/13}"
DATE_LABEL="arch-$(echo "$DATE" | tr -d '/')"   # 2025/08/13 -> arch-20250813

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_DIR/glibc-archives/$DATE_LABEL/x86_64"
BASE="https://archive.archlinux.org/repos/$DATE/core/os/x86_64"

# Preflight: extractor for .pkg.tar.zst
EXTRACT=""
if command -v bsdtar >/dev/null 2>&1; then
  EXTRACT="bsdtar"
elif tar --help 2>/dev/null | grep -q -- '--zstd'; then
  EXTRACT="tar"
else
  echo "!! Need an extractor for .zst. Install one:"
  echo "     sudo apt-get install -y libarchive-tools   (gives bsdtar), or"
  echo "     sudo apt-get install -y zstd                (for tar --zstd)"
  exit 1
fi

echo ">> Arch archive date: $DATE"
echo ">> Repo URL:          $BASE"
echo ">> Output:            glibc-archives/$DATE_LABEL/x86_64"
echo ""

# Find the glibc package in that day's core repo. Match glibc-<digit> so we skip
# glibc-locales, and there is no lib32 in the x86_64 repo listing.
echo ">> Locating glibc package ..."
LISTING="$(curl -fsSL "$BASE/")"
PKG="$(echo "$LISTING" \
  | grep -oE 'glibc-[0-9][^"<>]*-x86_64\.pkg\.tar\.zst' \
  | sort -u | head -n1)"

if [ -z "$PKG" ]; then
  echo "!! No glibc package found for $DATE."
  echo "   The archive may not have a snapshot for that exact day."
  echo "   Try an adjacent date, e.g.: ./scripts/pull_glibc_arch.sh 2025/08/14"
  exit 1
fi

VERSION="$(echo "$PKG" | sed -E 's/^glibc-([0-9][^-]*)-.*/\1/')"
echo "   found: $PKG  (glibc $VERSION)"

mkdir -p "$OUT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo ">> Downloading ..."
curl -fSL -o "$TMP/$PKG" "$BASE/$PKG"

echo ">> Extracting static libraries ..."
if [ "$EXTRACT" = "bsdtar" ]; then
  bsdtar -xf "$TMP/$PKG" -C "$TMP" usr/lib 2>/dev/null || bsdtar -xf "$TMP/$PKG" -C "$TMP"
else
  tar --zstd -xf "$TMP/$PKG" -C "$TMP" usr/lib 2>/dev/null || tar --zstd -xf "$TMP/$PKG" -C "$TMP"
fi

# Copy the real static archives and crt objects.
copied=0
for f in "$TMP"/usr/lib/*.a; do
  [ -f "$f" ] || continue
  # skip tiny stubs
  if [ "$(stat -c%s "$f")" -gt 100 ]; then
    cp -f "$f" "$OUT_DIR/"
    copied=$((copied+1))
  fi
done
for f in "$TMP"/usr/lib/crt1.o "$TMP"/usr/lib/crti.o "$TMP"/usr/lib/crtn.o "$TMP"/usr/lib/Scrt1.o; do
  [ -f "$f" ] && cp -f "$f" "$OUT_DIR/"
done

{
  echo "glibc version report"
  echo "source: Arch Linux Archive $DATE"
  echo "package: $PKG"
  echo "stable release version $VERSION"
} > "$REPO_DIR/glibc-archives/$DATE_LABEL/MANIFEST.txt"

echo ""
if [ "$copied" -eq 0 ]; then
  echo "!! No static .a archives were found in the package."
  echo "   Arch may ship static glibc elsewhere. Paste this and I will adjust."
  echo "   Package contents under usr/lib:"
  ls -la "$TMP"/usr/lib/ 2>/dev/null | sed 's/^/   /' | head -40
  exit 1
fi

echo ">> Done. glibc $VERSION staged."
echo "   Archives in glibc-archives/$DATE_LABEL/x86_64:"
ls -la "$OUT_DIR" | sed 's/^/   /'
echo ""
echo ">> Confirm the version above, then we import just this one and test it."
