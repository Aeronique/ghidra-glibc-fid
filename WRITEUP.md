# Naming glibc Functions in Stripped Static Binaries

Building reusable Function ID and BSim databases for Ghidra, so you stop identifying the same library functions over and over.

## The Problem

A stripped, statically linked Linux binary contains the entire C library with all symbol names removed. Ghidra loads it as a large set of functions named `FUN_<address>`, with no imports to identify them. Most of those functions are library code. A few are the program's own.

If you have opened one of these, you know the feeling. You came for one function and the disassembler hands you a thousand, every one named after its address, none of them talking.

A few terms first, so the rest reads cleanly:

- A symbol is a name bound to an address, like `main` or `printf`. Compilers emit them. A stripped binary has had them removed.
- Statically linked means the C library was copied into the binary at build time. A dynamically linked binary loads the library at run time and keeps its import names, so library calls stay labeled. A static binary keeps no such labels once it is stripped.
- glibc is the GNU C Library. Linked statically, it can add well over a thousand functions to a binary.

On a test target, a CTF binary named "printf to pay respects," Ghidra found 1,161 functions. After full analysis, 7 had names, all from the loader. One of the rest was the program's own code. The other 1,153 were glibc, taking up space and telling me nothing.

## Why a Reusable Database

You can identify library functions by hand, by reading their code and their calls. That work does not persist. It covers one binary and has to be redone on the next, because nothing carries between files. Do it a few times and it gets old.

A reusable database fixes that. Ghidra can fingerprint known library functions once, store the fingerprints with their names, and apply them automatically to every binary you analyze afterward. Whatever stays unnamed is the program's own code, which is the part you came for.

## Function ID

Function ID (FID) is a Ghidra feature. It computes a hash of each function's instructions and stores the hash with the function's name in a database. During analysis it hashes every function in your target and checks for a matching hash. A match applies the name. Simple and fast.

Ghidra ships with FID databases, but they lean toward Windows software and carry little Linux glibc. On the test target they matched nothing, which is how I ended up with 1,160 anonymous functions and a project.

### Source Libraries

Fingerprinting glibc needs copies of glibc that still have symbols. Docker images are the clean source, one version per image. I used four Ubuntu releases:

- Ubuntu 18.04: glibc 2.27
- Ubuntu 20.04: glibc 2.31
- Ubuntu 22.04: glibc 2.35
- Ubuntu 24.04: glibc 2.39

The files you want are the static library archives, the `.a` files. A `.a` archive holds many object files, each with one or a few functions. FID works on individual functions, so that granularity is the whole point.

### Building the Database

Three steps:

1. Import each `.a` archive into a Ghidra project with recursion enabled, so the archive expands into its member object files. Forget the recursion and it imports as one blob with nothing to fingerprint, which I mention because I did exactly that the first time.
2. Analyze the imported programs, so each function has disassembled instructions to hash.
3. Populate the database, hashing every function and storing the hash with its name and glibc version.

Each step is scripted, so the whole thing is repeatable and menu-free. The scripts are in the repo. The first build held 29,578 functions across the four glibc versions, in 32-bit and 64-bit.

## Matching the Target Toolchain

I attached the database, ran FID on the test target, and the named count went from 7 to 144. Good, except the three functions I wanted, the `fopen`, `fgets`, and `printf` calls in the target, were not among them. Of course they were not.

Here is the part I wish someone had told me before I spent an afternoon on it. Read the compiler string first. Every binary records the compiler that built it, and one command shows it:

```
strings -a <binary> | grep -iE 'glibc|release version|GCC:'
```

The target said `GCC 15.2.1 20250813`. That is a rolling-release compiler version, newer than anything the four Ubuntu releases ship.

FID matches on exact instruction bytes. The same glibc function compiled by a different GCC produces different bytes, the hashes differ, and no match happens. The 144 hits were mostly dynamic-linker functions that stay identical across builds. The rest of glibc had been built by a newer compiler and sailed right past my database. My four Ubuntu versions were the wrong library, and one string at the start would have saved the afternoon.

## The Fix: Match the Toolchain Exactly

The binary was built on Arch, and Arch keeps a dated archive of every package it has ever shipped, so no guessing required. I pulled the glibc that was live on Arch on the compiler's build date, August 13, 2025, which is the exact library the author linked against. It was glibc 2.42.

A database built from that one library, attached beside the first, took the named count from 144 to 656, and `puts` sorted itself out. The exact match worked, which is the reward for reading the string I should have read on day one.

## Function ID Limitations

Three functions in the target were still wrong or missing after the exact match. These are structural limits of hash matching, worth knowing so you do not chase them.

- `printf` matched as `wscanf`. The variadic wrapper functions, `printf`, `fprintf`, `scanf`, `wscanf`, set up their arguments with identical instructions and differ only in one internal pointer. Their hashes are the same, so FID cannot tell them apart and picks a name. This time it picked confidently, and confidently wrong.
- `fopen` did not match. It is a 13-byte stub that jumps to an internal function, under the size FID bothers to fingerprint.
- `fgets` did not match either.

You fix this handful by hand, which is normal. FID names the bulk, you clean up the stragglers. Each wrapper gives itself away through the internal function it calls, which FID does name. `fopen`'s stub calls `__fopen_internal`, so the little liar is easy to catch.

## BSim

BSim is Ghidra's second matcher. It compares the structure of the decompiled function and the data it references, so it can match functions across compiler versions and separate functions that look byte-identical to FID. It picks up where exact matching gives out.

You drive it differently. FID names things on its own during analysis. BSim you query. You open a binary, run a search over its functions, and apply the matches, one query and one apply per file.

I built the BSim database from the same glibc programs I had already imported, so nothing extra to download. Running BSim Overview on the test target reported matches across all 843 functions.

Two numbers tell you what to trust:

- Hit count: how many database functions resemble the one you are looking at. A high count means generic, weak evidence.
- Significance: how distinctive the function is. High significance with a low hit count means distinctive, and a strong similarity match there is solid.

Sort by significance and work down from the standouts. BSim returned nothing for the one function I wrote, which is exactly correct and a little insulting. By the same logic, the functions with no matches are your shortlist to read. The blanks are the interesting part.

## When to Use Each

- Function ID: automatic naming during analysis, for library builds already in your database.
- BSim: manual per-binary queries, for the larger functions FID missed and for binaries whose exact build you do not have.
- Small variadic wrappers and stub functions dodge both. Those you name yourself.

## Adding a New Build

When a binary comes up empty, its build is not in your database yet. Adding it is the same routine every time:

1. Read the compiler string: `strings -a <binary> | grep -iE 'glibc|GCC:'`.
2. Get that glibc version. For a rolling-release distro, use the dated package archive.
3. Import and populate it.
4. Re-attach and run again.

The scripts for all of it are in the repo. Take them, and when a stubborn binary shows up, fix them, because that is half the fun of building your own.
