# ghidra-glibc-fid

A repeatable way to teach Ghidra the names of glibc functions in stripped, statically linked binaries.

## The problem

A stripped static binary has all of glibc compiled into it with the symbol names removed. Ghidra loads it as a thousand or more `FUN_xxxxxxxx` functions with no imports to lean on, so the decompiler reads as noise. Only a handful of those functions are the program's own code. The rest are runtime library plumbing.

Ghidra can name library functions automatically through Function ID, which fingerprints each function and matches it against a database. The databases that ship with Ghidra lean toward Windows builds and miss most Linux glibc, so on a typical CTF binary Function ID matches nothing.

The fix is to build our own Function ID database from the glibc versions we actually run into, attach it to Ghidra once, and let it name library functions on every future analysis. When a new binary shows up unmatched, we add that one glibc and it is covered from then on.

## How it works, end to end

1. Pull static glibc archives from distro Docker images. One image per glibc version, 64-bit and 32-bit.
2. Install a Linux-side Ghidra that matches your GUI version, so the database loads on both.
3. Create an empty Function ID database, then import, analyze, and populate it from the archives.
4. Attach the database in your Windows Ghidra so it applies to every analysis automatically.

The build runs headless on the Linux side where the archives live, so it does not touch your running GUI. The finished database is a plain file you copy over and attach.

See `NOTES.md` for the design decisions, the gotchas we hit, and writeup material.

## Requirements

- Docker
- Ghidra (the Function ID plugin ships with it)
- Disk space for the archives, roughly a few hundred MB across four Ubuntu releases

## Step 1: stage the glibc archives

```
cd ~/ghidra-glibc-fid
./scripts/pull_glibc.sh
```

The script starts a throwaway container per image, installs the glibc dev packages, and copies the static archives out to `glibc-archives/<label>/<arch>/`. It records the exact glibc version for each image in a `MANIFEST.txt` and writes a top-level `SUMMARY.txt`.

Default images:

- ubuntu:18.04
- ubuntu:20.04
- ubuntu:22.04
- ubuntu:24.04

Edit the `IMAGES` list at the top of the script to add or remove versions.

Expected layout after a run:

```
glibc-archives/
  SUMMARY.txt
  ubuntu-2204/
    MANIFEST.txt
    x86_64/
      libc.a  libm.a  libpthread.a  libdl.a  librt.a  crt1.o  crti.o  crtn.o
    i386/
      libc.a  libm.a  ...
```

On glibc 2.34 and newer, `libpthread.a` is a small stub because pthread was folded into libc. That is expected.

## Step 2: install a matching Ghidra (Linux side)

```
cd ~/ghidra-glibc-fid
./scripts/install_ghidra_linux.sh
```

This installs Ghidra beside the repo at `~/ghidra_12.1.2_PUBLIC/`, kept out of the git tree on purpose. It pins the version to match the Windows GUI so the finished database loads on both sides. The download is verified against the published SHA-256 before use.

- Version: 12.1.2
- Asset: `ghidra_12.1.2_PUBLIC_20260605.zip`
- SHA-256: `b62e81a0390618466c019c60d8c2f796ced2509c4c1aea4a37644a77272cf99d`
- Java: a full JDK 21 or newer (OpenJDK 25 works). A JRE alone is not enough, since Ghidra compiles scripts at run time. Confirm with `javac -version`. On Kali: `sudo apt-get install -y openjdk-25-jdk`.

If you bump the Windows Ghidra later, update the pinned values at the top of `scripts/install_ghidra_linux.sh` and rerun.

## Step 3a: import the archives into a Ghidra project

```
cd ~/ghidra-glibc-fid
./scripts/build_import.sh
```

This imports every real glibc archive into a headless project under `fidproject/`, laid out as `glibc-fid/glibc/<version>/<arch>/<archive>/`. Importing a `.a` with `-recursive 1` expands it into its member object files, and each is analyzed so its functions have bodies to fingerprint. The version per image comes from that image's `MANIFEST.txt`, and the 8-byte merged-lib stubs are skipped.

It is long-running, one Ghidra pass per version and arch. To run it detached:

```
nohup ./scripts/build_import.sh > import.log 2>&1 &
tail -f import.log
```

Imports persist in the project, so this slow step runs once and the populate step can be re-run freely.

## Step 3b: create and populate the FID database

```
cd ~/ghidra-glibc-fid
./scripts/build_populate.sh
```

This runs `ghidra_scripts/PopulateGlibcFid.java` headless. That script creates a fresh `glibc.fidb`, walks `/glibc/<version>/<arch>` in the project, and creates one FID library per version and arch, inferring the language from the arch folder name (i386 to `x86:LE:32:default`, otherwise `x86:LE:64:default`). It prints a per-library program count and functions-added tally, then a final `DONE` line, and saves to `glibc.fidb` in the repo root.

It takes plain arguments and calls the same FID service methods as the shipped `CreateMultipleLibraries`, so there are no interactive prompts to feed. A headless postScript runs once per imported file, so the runner imports one tiny sentinel object into a throwaway `_trigger` folder to fire the script a single time. The script ignores that program and works on the whole project.

Re-running rebuilds from scratch. An existing `glibc.fidb` at the path is deleted first.

## Step 4: attach in Windows Ghidra and use it

Copy the database to a Windows path, e.g.:

```
cp ~/ghidra-glibc-fid/glibc.fidb /mnt/c/Users/<you>/ghidra-fid/glibc.fidb
```

In the GUI: Tools, Function ID, Choose active FidDbs, Attach existing FidDb, and select the file. It stays attached across restarts and applies during analysis.

To apply it to a binary that was already analyzed, run it as a one-shot: Analysis, One Shot, Function ID. Re-running full auto-analysis will not re-fire Function ID, since Ghidra remembers it already ran. After it runs, open Window, Functions and sort by name to see the matches, since the listing does not always repaint on its own.

Verified result on the "printf to pay respects" binary: named functions went from 7 to 144, with the glibc functions labeled and the program's own handful left as the only unnamed functions.

## Matching a rolling-distro binary (exact source)

Ubuntu glibc will not match a binary built on Arch or another rolling distro. Check the target's toolchain first:

```
strings -a <binary> | grep -iE 'glibc|release version|GCC:'
```

If it shows a recent GCC and Arch strings, pull the exact glibc from the Arch archive for the compiler's build date. The date is in the `GCC:` stamp.

```
./scripts/pull_glibc_arch.sh 2025/08/13
./scripts/build_import.sh arch-20250813
./scripts/build_populate.sh ../glibc-arch.fidb 2.42
```

That builds a separate database from just that version, byte for byte what the author linked, so Function ID matches it exactly.

Note the limit. Function ID cannot name byte-identical thin wrappers (printf vs wscanf vs scanf) or tiny tail-call stubs (fopen). Those either come back as `FID_conflict:` with a wrong sibling name or stay `FUN_`. Correct those few by hand, the named internals they call identify them, or use BSim.

## BSim: the second layer

BSim matches on decompiled structure instead of exact bytes, so it separates the thin wrappers Function ID cannot and tolerates build drift. It reuses the analyzed project, no re-import.

```
./scripts/build_bsim.sh
```

Three phases: create an H2 database, generate signatures (slow, it decompiles every function), commit. The result is `../bsim/glibc.mv.db`. Copy it to Windows and register it under BSim, Manage Servers.

BSim is query-driven, not automatic during analysis. Open a binary, run a BSim search across its functions, apply the strong matches in bulk. Use Function ID for fast automatic bulk naming, BSim for the wrappers it misses and for binaries whose exact build you do not have.

## A note on publishing

The `glibc-archives/` folder and any `.fidb` are excluded from git on purpose. The archives are copyrighted glibc binaries, so the recipe gets published, not the binaries. Anyone who clones the repo runs step 1 to produce their own copies.

## Status

- [x] Step 1: pull glibc archives
- [x] Step 2: install matching Ghidra (Linux side)
- [x] Step 3a: import the archives into a Ghidra project
- [x] Step 3b: create and populate the FID database (8 libraries, 29,578 functions, 3 MB)
- [x] Step 4: attach and verify (Ubuntu db: 7 to 144; Arch 2.42 db: to 656)
- [x] Exact match for a rolling-distro target via the Arch archive
- [x] BSim second layer for thin wrappers and build drift
