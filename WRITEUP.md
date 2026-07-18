# Naming glibc Functions in Stripped Static Binaries

Building reusable Function ID and BSim databases for Ghidra.

## The Problem

A stripped, statically linked Linux binary contains the entire C library with all symbol names removed. Ghidra loads it as a large set of functions named `FUN_<address>`, with no imports to identify them. Most of those functions are library code. A small number are the program's own code.

Terms used below:

- A symbol is a name bound to an address, such as `main` or `printf`. Compilers emit them, and a stripped binary has had them removed.
- Statically linked means the C library was copied into the binary at build time. A dynamically linked binary loads the library at run time and keeps its import names, so library calls stay labeled. A static binary has no such labels once stripped.
- glibc is the GNU C Library. Linked statically, it can add over a thousand functions to a binary.

On a test target, a CTF binary named "printf to pay respects," Ghidra found 1,161 functions. After full analysis, 7 had names, all from the loader. One of the remaining functions was the program's own code. The other 1,153 were glibc.

## Why a Reusable Database

Library functions can be identified by hand, by reading their code and their calls. That identification does not persist. It applies to one binary and has to be repeated on the next, because nothing carries over between files.

A reusable database removes the repetition. Ghidra can fingerprint known library functions once, store the fingerprints with their names, and apply them automatically to every binary analyzed afterward. The functions that remain unnamed are the program's own code.

## Function ID

Function ID (FID) is a Ghidra feature. It computes a hash of each function's instructions and stores the hash with the function's name in a database. During analysis it hashes each function in the target and looks for a matching hash in the database. A match applies the name.

Ghidra ships with FID databases, but they cover mostly Windows software and little Linux glibc. On the test target they produced no matches.

### Source Libraries

Fingerprinting glibc requires copies of glibc that still have symbols. Docker images provide these, one version per image. Four Ubuntu releases were used:

- Ubuntu 18.04: glibc 2.27
- Ubuntu 20.04: glibc 2.31
- Ubuntu 22.04: glibc 2.35
- Ubuntu 24.04: glibc 2.39

The relevant files are the static library archives, the `.a` files. A `.a` archive contains many object files, each with one or a few functions. FID operates on individual functions, so this granularity is required.

### Building the Database

Three steps:

1. Import each `.a` archive into a Ghidra project with recursion enabled, so the archive expands into its member object files. Without recursion the archive imports as a single unit and no functions are exposed.
2. Analyze the imported programs, so each function has disassembled instructions to hash.
3. Populate the database, hashing every function and storing the hash with its name and glibc version.

Each step is scripted for repeatability. The scripts are in the repo. The initial build contained 29,578 functions across the four glibc versions, in 32-bit and 64-bit.

## Matching the Target Toolchain

After attaching the database and running FID on the test target, named functions went from 7 to 144. The `fopen`, `fgets`, and `printf` calls in the target function were not among them.

The cause was the toolchain. Every binary records the compiler that built it. Reading it:

```
strings -a <binary> | grep -iE 'glibc|release version|GCC:'
```

The target reported `GCC 15.2.1 20250813`. This is a rolling-release compiler version. The Ubuntu releases used for the database ship older GCC versions.

FID matches on exact instruction bytes. The same glibc function compiled by different GCC versions produces different bytes, so the hashes differ and no match occurs. The 144 matches were mostly dynamic-linker functions that are identical across builds. The rest of glibc was compiled by a newer GCC and did not match.

The fix was to use the exact glibc the target was built against. The compiler date identified the build as Arch Linux from August 13, 2025. The Arch Linux Archive stores every past package by date, so the exact glibc from that date was available. It was glibc 2.42.

A database built from that single library, attached alongside the first, raised the named count from 144 to 656. `puts` matched correctly.

## Function ID Limitations

Three functions in the target remained wrong or unnamed after the exact match. These are structural limits of hash-based matching.

- `printf` matched as `wscanf`. The variadic wrapper functions (`printf`, `fprintf`, `scanf`, `wscanf`) set up their arguments with identical instructions and differ only in one internal pointer. Their hashes are the same, so FID cannot distinguish them and applies one of the candidate names.
- `fopen` did not match. It is a 13-byte stub that jumps to an internal function, below the minimum size FID fingerprints.
- `fgets` did not match.

These are corrected by hand. FID names the majority, and the analyst names the few it cannot. Each wrapper can be identified from the internal function it calls, which FID does name. `fopen`'s stub calls `__fopen_internal`.

## BSim

BSim is a second Ghidra feature for function matching. It compares the structure of the decompiled function and the data it references, so it can match functions across compiler versions and distinguish functions with identical bytes.

BSim is used differently from FID. FID applies names automatically during analysis. BSim is queried: the analyst runs a search over the target's functions and applies the matches. It is one query and one apply per binary.

The BSim database was built from the same imported glibc programs, so no additional download was needed. Running BSim Overview on the test target reported matches across all 843 functions.

Reading BSim results uses two values:

- Hit count: how many database functions resemble the queried function. A high hit count indicates a generic function and weak evidence.
- Significance: how distinctive the function is. High significance with a low hit count indicates a distinctive function, and a strong similarity match there is reliable.

Sort by significance and work down from the most distinctive functions. BSim returns no match for the program's own functions, since they are not in the database. The unmatched functions are the program's own code.

## When to Use Each

- Function ID: automatic naming during analysis, for library builds present in the database.
- BSim: manual per-binary queries, for larger functions FID missed and for binaries whose exact build is not in the database.
- Small variadic wrappers and stub functions match in neither and are named by hand.

## Adding a New Build

When a binary produces no matches, its build is not in the database. To add it:

1. Read the compiler string: `strings -a <binary> | grep -iE 'glibc|GCC:'`.
2. Obtain that glibc version. For a rolling-release distro, use the dated package archive.
3. Import and populate it into the database.
4. Re-attach and re-run.

The scripts for all steps are in the repo.
