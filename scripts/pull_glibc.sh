#!/usr/bin/env bash
#
# pull_glibc.sh
# Stage static glibc archives from distro Docker images for Ghidra Function ID.
#
# WHAT IT DOES
#   For each distro image listed in IMAGES, it starts a throwaway container,
#   installs the glibc development packages (64-bit and, when available, 32-bit),
#   and copies the static archives (libc.a, libm.a, libpthread.a, etc.) out to
#   ./glibc-archives/<label>/<arch>/. It also records the exact glibc version
#   string for each image in a MANIFEST.txt so the FID database can be tagged.
#
# WHY
#   Ghidra's shipped Function ID databases do not cover most Linux glibc builds,
#   so statically linked CTF binaries show up as thousands of FUN_ names. These
#   archives are the raw material we feed Ghidra to build a glibc FID database.
#
# REQUIREMENTS
#   docker (present), network access to pull images and apt packages.
#
# USAGE
#   cd ~/ctf/tools/ghidra-glibc-fid
#   ./scripts/pull_glibc.sh
#
# EXPECTED OUTPUT
#   A tree under glibc-archives/ like:
#     glibc-archives/ubuntu-2204/x86_64/libc.a  libm.a  libpthread.a ...
#     glibc-archives/ubuntu-2204/i386/libc.a    libm.a  ...
#     glibc-archives/ubuntu-2204/MANIFEST.txt   (holds the glibc version string)
#   Plus a top-level glibc-archives/SUMMARY.txt listing every archive pulled and
#   its size. On glibc 2.34 and newer, libpthread.a is a tiny stub because pthread
#   was folded into libc. That is expected and harmless.
#
# NOTES
#   Do not commit the archives themselves to git. They are copyrighted glibc
#   binaries. The .gitignore in this repo already excludes glibc-archives/.
#   Re-running is safe. Existing per-image folders are replaced.

set -euo pipefail

# Distro images to harvest. Add or trim as your target set changes.
IMAGES=(
  "ubuntu:18.04"
  "ubuntu:20.04"
  "ubuntu:22.04"
  "ubuntu:24.04"
)

# Resolve paths relative to this script so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_ROOT="$REPO_DIR/glibc-archives"
SUMMARY="$OUT_ROOT/SUMMARY.txt"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

mkdir -p "$OUT_ROOT"
: > "$SUMMARY"
echo "Ghidra glibc FID source archives" >> "$SUMMARY"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SUMMARY"
echo "" >> "$SUMMARY"

# This script runs inside each container. It installs dev packages, then copies
# the static archives to the bind-mounted /out, and fixes ownership back to the
# host user so the files are not left owned by root.
read -r -d '' IN_CONTAINER <<'EOS' || true
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq >/dev/null 2>&1

# 64-bit dev libs. Always available.
apt-get install -y -qq libc6-dev >/dev/null 2>&1 || true
# 32-bit dev libs. Not present on every image; best effort.
apt-get install -y -qq libc6-dev-i386 >/dev/null 2>&1 || true

copy_arch () {
  # $1 = arch label, $2..= path fragments that identify that arch
  local arch="$1"; shift
  local dest="/out/$arch"
  mkdir -p "$dest"
  local found=0
  for name in libc.a libm.a libpthread.a libdl.a librt.a libutil.a libcrypt.a; do
    for frag in "$@"; do
      # Find the first match for this lib under a path containing the fragment.
      local f
      f="$(find /usr -type f -name "$name" -path "*${frag}*" 2>/dev/null | head -n1 || true)"
      if [ -n "$f" ]; then
        cp -f "$f" "$dest/$name"
        found=1
        break
      fi
    done
  done
  # crt startup objects help Ghidra label _start and friends.
  for name in crt1.o crti.o crtn.o Scrt1.o; do
    for frag in "$@"; do
      local f
      f="$(find /usr -type f -name "$name" -path "*${frag}*" 2>/dev/null | head -n1 || true)"
      if [ -n "$f" ]; then
        cp -f "$f" "$dest/$name"
        break
      fi
    done
  done
  if [ "$found" -eq 0 ]; then
    rmdir "$dest" 2>/dev/null || true
  fi
}

# 64-bit archives live under an x86_64 path fragment.
copy_arch "x86_64" "x86_64-linux-gnu"
# 32-bit archives land under i386-linux-gnu or lib32 depending on the release.
copy_arch "i386" "i386-linux-gnu" "lib32"

# Record the precise glibc version for tagging the FID entries later.
{
  echo "glibc version report"
  ldd --version 2>/dev/null | head -n1 || true
  # Fallback: the banner inside libc itself.
  for so in /lib/x86_64-linux-gnu/libc.so.6 /lib/i386-linux-gnu/libc.so.6; do
    if [ -f "$so" ]; then
      strings "$so" 2>/dev/null | grep -m1 "GNU C Library" || true
    fi
  done
} > /out/MANIFEST.txt 2>/dev/null || true

# Hand ownership back to the host user.
chown -R "${HOST_UID}:${HOST_GID}" /out 2>/dev/null || true
EOS

for image in "${IMAGES[@]}"; do
  label="$(echo "$image" | tr ':/' '--')"   # ubuntu:22.04 -> ubuntu-22.04
  label="${label/./}"                        # -> ubuntu-2204
  dest="$OUT_ROOT/$label"

  echo ">> $image  ->  glibc-archives/$label"
  rm -rf "$dest"
  mkdir -p "$dest"

  # Pull explicitly first so failures are obvious and separate from the run step.
  docker pull -q "$image" >/dev/null

  docker run --rm \
    -e HOST_UID="$HOST_UID" \
    -e HOST_GID="$HOST_GID" \
    -v "$dest":/out \
    "$image" \
    bash -c "$IN_CONTAINER"

  # Append this image's results to the summary.
  {
    echo "=== $image  ($label) ==="
    if [ -f "$dest/MANIFEST.txt" ]; then
      sed 's/^/  /' "$dest/MANIFEST.txt"
    fi
    find "$dest" -type f \( -name '*.a' -o -name '*.o' \) -printf '  %-12s %p\n' \
      | sed "s#$OUT_ROOT/##" | sort -k2 || true
    echo ""
  } >> "$SUMMARY"
done

echo ""
echo "Done. Review the summary below, then paste it back:"
echo "----------------------------------------------------"
cat "$SUMMARY"
