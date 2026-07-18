# Teaching Ghidra to Read glibc

## Naming the library functions in stripped static binaries so you can find the code that actually matters

If you have ever opened a stripped, statically linked binary in Ghidra, you have seen the wall. A thousand functions, all named `FUN_00401000`, `FUN_00401337`, and so on. No hints. No imports. Just a sea of addresses. Somewhere in there is the one function the author wrote, the thing you actually opened the file to read. The rest is the C library, compiled in and stripped of its names.

This post is about clearing that wall once and for good. I built a reusable database that names the library functions automatically, so every binary I open from now on shows me a short list of unknown functions instead of a thousand. That short list is the code I came to read.

I will explain the problem first, then the two tools that solve it, then how I built them and the mistakes I made along the way. There is a repo with all the scripts. The point here is the reasoning, so you can build your own or fix mine when a binary does not cooperate.

## What is actually going on

A few terms first, so the rest makes sense.

A **symbol** is a name attached to an address in a program, like `main` or `printf`. Compilers add them. They are what makes a disassembler readable.

**Stripped** means those names were removed after the binary was built. The code still works. The map is just gone.

**Statically linked** means the C library was copied into the binary at build time instead of being loaded from the system at run time. A dynamically linked binary keeps its imports, so `printf` still shows up as `printf` for free. A static binary has the whole library baked in, and once it is stripped, all of that library code shows up nameless.

**glibc** is the GNU C Library, the standard C library on most Linux systems. It is large. When it gets statically linked into a program, it can add well over a thousand functions.

So here is the situation on a real target. I opened a CTF binary called "printf to pay respects." Ghidra found 1,161 functions. After a full analysis, exactly 7 had names, and those came from the loader, not from any real identification. One of those 1,161 functions was the code the author wrote. The other 1,160 were glibc.

## Why this is worth solving

The work I came to do was read that one function. The other 1,160 were library code I already understand. The problem was I could not tell which was which. Every function looked the same: a `FUN_` and an address.

So you end up reading library code by hand just to prove it is library code. You trace the calls in some function, realize it is `fopen`, and move on. Then the next binary lands and you do it all again, because the names never carried over.

Doing that once is fine. Doing it on every binary forever is a waste. In a CTF, the clock is the whole game, and time spent re-deriving `fopen` is time not spent on the challenge. In malware or firmware work, it is the gap between reading the payload today or next week.

The fix is to pay that cost a single time. Fingerprint the library functions once, store the fingerprints, and attach them to Ghidra. From then on, every binary you open gets its library functions named automatically. The functions that stay nameless are the author's code. The wall becomes a list.

## Tool one: Function ID

Ghidra ships with a feature called **Function ID**, or FID. The idea is simple. It takes a hash, a short fingerprint, of each function's instructions. It stores those hashes in a database along with the real names. When you analyze a new binary, it hashes every function and looks for the same fingerprint in the database. A match means it can apply the name.

Ghidra comes with a few of these databases, but they lean toward Windows software and do not cover most Linux glibc builds. On my target, the shipped databases matched nothing. Every glibc function stayed a `FUN_`.

So the plan was to build my own FID database from the glibc versions I run into, and keep adding to it over time.

### Getting clean glibc to fingerprint

To fingerprint glibc functions, I need copies of glibc that still have their names. The cleanest source is Docker images, one per version. Each image gives a known, reproducible copy of the library with symbols intact.

I pulled the static library archives from four Ubuntu releases:

- Ubuntu 18.04 gives glibc 2.27
- Ubuntu 20.04 gives glibc 2.31
- Ubuntu 22.04 gives glibc 2.35
- Ubuntu 24.04 gives glibc 2.39

A static library archive is a `.a` file. Think of it as a zip of small object files, one or a few functions each. That granularity is exactly what FID wants.

### Building the database

The build has three moves.

Import the archives into a Ghidra project. When you import a `.a` archive, you tell Ghidra to recurse into it so it expands into the member object files. Without that, you get one opaque blob and no functions to hash. With it, you get every glibc function as its own analyzable unit.

Analyze them, so each function has real instructions for FID to fingerprint.

Populate the database, which hashes every function and stores the hash with its name and its library version.

I wrote small scripts for each step so the whole thing is repeatable, and so I am not clicking through menus. They are in the repo.

The first build produced a database with 29,578 functions across those four glibc versions, in both 32-bit and 64-bit.

## The first attempt, and the lesson that saved me

I attached the database, re-ran Function ID on the printf binary, and watched the named count jump from 7 to 144.

Better. But the functions I actually cared about, the `fopen`, `fgets`, and `printf` calls inside the target function, were still `FUN_`. Something was off.

Here is the lesson, and it is the most useful thing in this whole post.

**Check the toolchain of your target before you build the database.** Every binary carries a small string that names the compiler that built it. You can read it with one command:

```
strings -a <binary> | grep -iE 'glibc|release version|GCC:'
```

My binary said `GCC 15.2.1 20250813`. That is a very recent compiler, the kind you find on a rolling-release distro like Arch, not on Ubuntu. Ubuntu 24.04, my newest source, ships an older GCC.

Function ID matches on exact bytes. glibc compiled by an old Ubuntu GCC does not produce the same bytes as glibc compiled by a new Arch GCC, even for the same function. Different bytes, no match. The 144 that did match were mostly stable dynamic-linker internals that happen to look the same across builds. The functions I wanted were compiled differently, so they slipped through.

The four Ubuntu versions were the wrong source for this binary. One string would have told me that on day one.

## The fix: match the toolchain exactly

The binary was built on Arch. Arch keeps a dated archive of every package it ever shipped. So I did not have to guess. I pulled the glibc that was live on Arch on the compiler's build date, August 13, 2025. That is byte for byte the library the author linked against.

The version came back as glibc 2.42. I built a small database from just that one library, attached it alongside the first, and re-ran Function ID.

Named functions jumped from 144 to 656. `puts` came back correct on its own. The exact match worked.

## The blind spot both tools share

Even with the exact library, three functions in my target were still wrong or missing. This is worth understanding, because it is a permanent limit, not a bug.

`printf` came back labeled as `wscanf`. The thin wrapper functions in a C library, `printf`, `fprintf`, `scanf`, `wscanf`, all set up their arguments with nearly identical code and differ only in one internal pointer they pass. Their fingerprints collide. Function ID cannot tell them apart, so it picks one, and here it picked wrong. This is not a gap in the database. Those functions are genuinely identical in the bytes FID looks at.

`fopen` stayed nameless. It is a 13-byte stub that just jumps to an internal function. Too small to fingerprint.

`fgets` stayed nameless as well.

The fix for these few is a one-time hand correction, which is normal. Function ID does the mass naming, you clean up the handful it cannot resolve. And there is a shortcut for identifying them: read the internal function each one calls. `fopen`'s tiny stub calls `__fopen_internal`, which the database did name. So even a nameless wrapper is easy to identify from the named code around it.

## Tool two: BSim, for the harder cases

Function ID is fast and automatic, and it is exact. That exactness is its weakness on functions that drift between builds or share bytes with siblings.

Ghidra has a second tool for that, called **BSim**. Instead of hashing raw bytes, BSim compares the structure of the decompiled function and the data it references. That lets it match functions across compiler versions and tell apart functions that look byte-identical to FID.

The tradeoff is how you use it. Function ID names things automatically during analysis. BSim is something you query. You open a binary, run a search over its functions, and apply the strong matches. It is one query and one apply per binary.

I built a BSim database from the same glibc programs I had already imported, so no extra downloading. Then I ran its Overview on the printf binary, which scans every function at once and reports how many have matches. It lit up across all 843 functions in the program.

Two things to know when reading BSim results. **Hit count** is how many library functions resemble this one. **Significance** is how distinctive the function is. A function with thousands of hits and low significance is generic and weak evidence. A function with a low hit count and high significance is distinctive, and a strong similarity match there is a confident identification. Sort by significance, ignore the generic rows, work down the distinctive ones.

One more useful detail. BSim returned zero matches on the author's own function, the one I actually cared about. That is correct. It is not glibc, so nothing in the database resembles it. Which means the functions with no matches are your short list of code to read. The tool points you at the interesting parts by process of elimination.

## What you end up with

Two layers.

Function ID names the bulk of the library automatically, the moment you analyze a binary, as long as you have the matching build in your database.

BSim, run by hand per binary, fills in the larger functions Function ID missed and handles binaries whose exact build you never pulled.

The tiny wrappers floor out of both tools, and for those the one-time hand fix stands. It is a small list, and the named code around them makes them obvious.

The payoff compounds. The database is not for one binary. It gets better every time I add a build I have run into, and the hours I spent building it are spent once. Every future binary it names is time I never spend again.

## Adding a new build later

When a binary does not match, its build is not in the database yet. The process to add it is the same each time:

1. Read the compiler string with `strings -a <binary> | grep -iE 'glibc|GCC:'`.
2. Pull that exact glibc. For a rolling distro, use the dated archive so you get the exact version.
3. Import and populate it into the database.
4. Re-attach and re-run.

Over time the gaps fill in, and the wall you started with turns into a short list on almost every binary you open.

The scripts for all of this are in the repo. Take them, break them, and fix them when a stubborn binary shows up. That is the whole point of building the thing yourself.
