# Build notes and writeup material

Raw material for a blog post. The README is the how-to. This is the why, the decisions, and the things that bit us along the way.

## Why do this at all

Reverse engineering a stripped, statically linked binary starts with a wall. The whole C library is compiled into the file and its names are stripped, so the disassembler shows you a thousand or more functions called `FUN_00401234` and nothing else. On a real target that was 1,161 functions. Exactly one of them was the code the author wrote. The other 1,160 were glibc.

The work you actually came to do is read that one function. Everything else is library plumbing you already understand. But with no names, you cannot tell the one from the other. You end up reading library code by hand just to prove it is library code, then setting it aside. You re-derive that some function is `fopen` by reading its calls, then the next binary lands and you do it all again.

Doing that once is fine. Doing it on every binary forever is wasted, repeated effort, and it burns the time that should go to the actual challenge. In a CTF that time is the whole game. In malware or firmware work it is the difference between reading the payload today or next week.

So the point of this project is to pay that cost once. Fingerprint the library functions a single time, store the fingerprints in a database, and attach it. From then on every binary you open gets its library noise named automatically, and the functions that stay unnamed are precisely the author's code. The wall becomes a short list. You go straight to what matters.

That is the core idea, and it is why the payoff compounds. The database is not for one binary. It is a durable capability that gets better every time you add a library build you have run into. The four hours spent building it is spent once. Every future binary it names is time you do not spend again.

## The problem, stated plainly

A stripped, statically linked Linux binary carries all of glibc inside it with the symbol names removed. Ghidra loads it as more than a thousand `FUN_xxxxxxxx` functions with no imports to lean on. Only a handful of those functions are the program's own code. The rest are glibc.

Ghidra can name library functions with Function ID, which fingerprints each function and matches it against a database. The databases that ship with Ghidra lean toward Windows builds and did not cover the glibc that compiled our target. So Function ID matched nothing, and every glibc function stayed a `FUN_` name.

The proof, from a real target (the "printf to pay respects" CTF binary): after a full auto-analysis, only 7 functions had non-default names, and those were switch-case labels and `entry` from the loader. Function ID named zero library functions.

## The approach

Build our own Function ID database from the glibc versions we actually run into, attach it once, and let Ghidra name library functions on every future analysis. When a new binary shows up unmatched, add that one glibc and it is covered from then on.

## Decisions and why

Match the build Ghidra to the GUI version. Database format is tied to the major version, so the Linux-side build Ghidra is pinned to 12.1.2 to match the Windows GUI. Mismatched majors can refuse to load each other's databases.

Build on Linux, use on Windows. The glibc archives live on the Linux side, so the build runs there headless without touching the running GUI. The finished `.fidb` is a plain file. Copy it to Windows and attach it under Tools, Function ID, Choose active FidDbs.

Pull glibc from Docker images, not the host. One image per glibc version gives clean, reproducible archives with symbols intact. Ubuntu 18.04, 20.04, 22.04, and 24.04 give glibc 2.27, 2.31, 2.35, and 2.39, which covers most CTF targets.

Write a custom argument-driven populate script instead of the shipped ones. The shipped `CreateMultipleLibraries` and `CreateEmptyFidDatabase` lean on interactive prompts. In headless mode those prompts have to be fed through a properties file, and one of them is a choice that must match an object's string form exactly. Driving all of that blind is brittle. A small script that takes plain arguments and calls the same FID API directly is more robust and reads better in a repo.

Folder layout drives library identity. Function ID derives library name, version, and variant from project folder depth. We import into `glibc / <version> / <arch>` so the identity comes out clean.

Recursive import expands the archive. Importing a `.a` with `-recursive 1` turns it into its member object files, which is where the individual functions live. Without recursion you get one opaque blob and no functions to hash.

## Gotchas that cost time, good for the writeup

Scripts need the execute bit. New scripts written to disk are not executable by default. Run through `bash script.sh` or `chmod +x` first. Symptom: `zsh: permission denied`.

Ghidra needs a JDK, not a JRE. The launcher rejected OpenJDK 25 with "JDK 21+ could not be found." Cause: `java` was present but `javac` was not. Ghidra compiles scripts at run time, so it needs the full JDK. Fix: `sudo apt-get install -y openjdk-25-jdk`, then confirm with `javac -version`. The install script now checks for `javac` up front so this surfaces early.

The import errors are almost all noise. Importing unlinked object files throws a steady stream of messages that look alarming and are not:
- `LSDACallSiteTable ... does not contain the landing pad` and `GccExceptionAnalyzer Failed to disassemble at 00200000`. The exception-handling analyzer is trying to parse unwind tables in object files whose addresses are still placeholders. It gives up on those tables. Function code still disassembles.
- `ElfRelocationHandler EXTERNAL ... Relocation`. Object files reference symbols that are not resolved until link time. Function ID masks relocated operands when it hashes, so this does not hurt the fingerprints.
- Lines mentioning `error.o` are not errors. `error.o` is a real member of `libc.a`, the compilation unit for glibc's `error()` function.

## Scale and timing, measured

Total member object files across all real archives: 19,306.
Steady-state import and analyze rate on a modest WSL setup: about 2 members per second.
Full import wall time: roughly 2 to 2.5 hours. `libc.a` dominates every combo, so no version is dramatically faster than another.

## Reproducibility record

Build Ghidra: 12.1.2, asset `ghidra_12.1.2_PUBLIC_20260605.zip`, SHA-256 `b62e81a0390618466c019c60d8c2f796ced2509c4c1aea4a37644a77272cf99d`.

glibc versions and sources:
- Ubuntu 18.04, glibc 2.27
- Ubuntu 20.04, glibc 2.31
- Ubuntu 22.04, glibc 2.35
- Ubuntu 24.04, glibc 2.39

On glibc 2.34 and newer, `libpthread`, `librt`, `libdl`, and `libutil` are folded into `libc`, so their archives are 8-byte stubs. The importer skips anything under 100 bytes.

## Build results, measured

The populate run produced 8 libraries and 29,578 functions in a 3 MB database:

| glibc | x86_64 added | i386 added |
| ----- | ------------ | ---------- |
| 2.27  | 2,952        | 4,060      |
| 2.31  | 3,296        | 4,224      |
| 2.35  | 3,246        | 4,126      |
| 2.39  | 3,419        | 4,255      |

The i386 side adds more because those images ship more real archives (pthread, rt, crypt, dl, util) while 2.34+ x86_64 folds them into libc. Exclusions run higher on i386 for the same reason. FID drops functions that are too small or too common to be distinctive, which is expected and healthy.

## Verification, measured, and the lesson

This is the most useful part of the story, because the first attempt was a partial miss and the fix taught the real lesson.

Stage 1, Ubuntu database. Attached it and ran Function ID on the printf binary. Named functions went from 7 to 144. But the wrappers in the flag handler stayed unnamed. The cause: the target was not an Ubuntu binary. Its compiler stamp was `GCC 15.2.1 20250813`, a rolling-distro build. Function ID matches on exact bytes, and Ubuntu glibc compiled with older GCC does not byte-match an Arch binary compiled with GCC 15. The 144 that did match were mostly the dynamic linker internals, which happen to be stable across builds.

Lesson: check the target binary's toolchain before choosing source glibc. Read the `GCC:` comment string first. That one string would have set the direction on day one.

Stage 2, exact match from the Arch archive. The binary showed Arch's glibc, so we pulled the exact glibc from the Arch Linux Archive for the compiler's build date, `2.42+r3+gbc13db739377`. That is byte for byte what the author linked. Named functions jumped to 656, and `puts` came back correct.

Stage 3, the permanent Function ID blind spot. Even with the exact library, three functions in the flag handler were still wrong or missing:
- `printf` matched as `FID_conflict:wscanf`. The thin variadic wrappers (printf, fprintf, scanf, wscanf) set up their arguments with identical bytes and differ only in one internal pointer. Their hashes collide, so exact matching cannot separate them. This is not a database gap. Those functions are genuinely identical in the bytes FID hashes.
- `fopen` stayed `FUN_`. It is a 13-byte tail-call stub, below the minimum function size FID will fingerprint.
- `fgets` stayed `FUN_`. Did not match cleanly.

These were corrected by hand once, which is standard FID workflow: the tool does the mass naming, the analyst fixes the ambiguous few. Reading which internal each wrapper calls identifies it: `fopen`'s stub tail-calls `__fopen_internal`, which FID did name.

Takeaway for the tool: exact-hash FID is excellent for the bulk of substantial library functions and structurally cannot handle byte-identical thin wrappers or sub-threshold stubs. That gap is why BSim exists as a second layer.

Two gotchas worth noting for the writeup:
- Re-running full auto-analysis does not re-fire Function ID. Ghidra remembers it already ran. Use Analysis, One Shot, Function ID to apply a newly attached database to an already-analyzed program.
- The listing view does not always repaint after a one-shot. Open Window, Functions and sort by name to see the matches, or reopen the listing.

## BSim, the second layer

BSim is a similarity database. It matches on decompiled structure and data references instead of exact bytes, so it does two things Function ID cannot: it tells apart thin wrappers like printf and wscanf, and it tolerates compiler and version drift.

Key difference in use. Function ID names automatically during analysis. BSim is query-driven. You open a binary, run one BSim search over its functions, and apply the high-confidence matches, in bulk if you like. One query and one apply per binary, not zero touch.

It reuses the analyzed project. `scripts/build_bsim.sh` signs the programs already imported, all glibc versions and both arches, with no re-import. Three phases: create an H2 database with the `medium_nosize` template (nosize lets 32-bit and 64-bit match), generate signatures (the slow phase, it decompiles every function), then commit them. The result is a single `.mv.db` file you copy to Windows and register in the GUI under BSim, Manage Servers.

When to reach for which: Function ID for the fast automatic bulk naming, BSim for the wrappers it misses and for binaries whose exact build you do not have.

## How to add a new glibc later

When a binary does not match, its glibc build is not in the database yet. Add it:
1. Add the distro image to the IMAGES list in scripts/pull_glibc.sh and rerun it.
2. Rerun scripts/build_import.sh. It imports only the new combos into the existing project.
3. Rerun scripts/build_populate.sh to rebuild the database including the new libraries.
4. The database at glibc.fidb updates in place. Re-copy it to the Windows side.

## For the blog draft

The pieces are all captured above. What is left is shaping, not research:
- Before and after screenshots on the printf binary (7 named to 144)
- A tightened narrative arc: the FUN_ wall, why FID missed, the build, the payoff
- Optional: a short aside on FID excluding small and common functions
