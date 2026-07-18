# Teaching Ghidra to Read glibc

*Naming the library functions in a stripped static binary so the author's code stands out*

Open a stripped, statically linked binary in Ghidra and you meet a wall of `FUN_00401000`, `FUN_00401337`, and a thousand more like them. No names, no imports, only addresses. One of those functions is the thing you opened the file to read, and the other thousand are the C library, compiled in and stripped of every name that would have told you so.

This is about clearing that wall once. I built a database that recognizes glibc functions and labels them on sight, so every binary I open afterward shows me a handful of unknowns where a thousand used to be, and those unknowns are the code worth my time. What follows is the problem, the two tools Ghidra gives you for it, how I built each one, and the mistake that cost me an afternoon before I understood what I had done wrong. All the scripts are in the repo. The reasoning is the part worth reading, because once you see why each step exists you can build your own version or repair mine when a stubborn binary refuses to cooperate.

## What You Are Looking At

A few terms first, so the rest reads cleanly.

A symbol is a name pinned to an address, something like `main` or `printf`. Compilers emit them, and they are what turns a screen of hex into something you can follow.

Stripped means someone removed those names after the build. The program runs exactly as before. Only the map is gone.

Statically linked means the C library was copied into the binary when it was built. A dynamically linked binary leaves the library on the system and loads it at run time, which keeps the import names in view, so `printf` shows up as `printf` at no cost to you. A static binary carries the whole library inside itself, and after stripping, all of that borrowed code turns into nameless functions.

glibc is the GNU C Library, the standard C library on most Linux systems, and it is not small. Linked statically into a program, it can contribute well over a thousand functions on its own.

Here is what that looked like on a real target, a CTF binary named "printf to pay respects." Ghidra found 1,161 functions. After a full pass of analysis, seven of them had names, and every one came from the loader. None was a real identification. Of the 1,161, a single function was the author's own work, and the remaining 1,160 were glibc.

## Why This Is Worth the Trouble

The whole reason I opened the file was to read that one function. Everything around it was library code I already know cold, and the difficulty was telling one from the other, since on screen they were identical: a `FUN_`, an address, nothing else.

So you do the tedious thing. You read a library function by hand, follow its calls, conclude it is `fopen`, and set it aside. Then the next binary lands and you begin again, because nothing you learned carried forward. Once, that is reasonable. As a standing habit it drains the hours you should be spending on the target. In a CTF the clock is the whole contest, and every minute rediscovering `fopen` is a minute you did not spend on the puzzle. In malware or firmware work it can decide whether you read the payload this afternoon or next week.

The way out is to pay that cost a single time. Fingerprint the library functions once, keep the fingerprints, and hand them to Ghidra. From then on, every binary you analyze gets its library code named for you, and whatever stays nameless is, by elimination, the author's code. The wall becomes a list.

## The First Tool: Function ID

Ghidra ships with a feature called Function ID, or FID, and the idea behind it is clean. It computes a hash, a compact fingerprint, of each function's instructions, and it stores those hashes alongside the real names in a database. When you analyze something new, it fingerprints every function and checks the database for a match. A hit means it can drop the name straight onto the function.

Ghidra includes a few of these databases out of the box, but they favor Windows software and cover very little Linux glibc. On my target they matched nothing at all, which is how 1,160 glibc functions stayed anonymous. The obvious move was to build my own from the glibc versions I keep meeting, and to grow it over time.

### Getting Clean glibc to Fingerprint

To fingerprint glibc, I need copies of it that still carry their names. Docker images are the tidiest source, one per version, each a known and repeatable snapshot of the library with symbols intact. I pulled the static library archives from four Ubuntu releases, which between them cover a wide span of what turns up in the wild:

- Ubuntu 18.04 carries glibc 2.27
- Ubuntu 20.04 carries glibc 2.31
- Ubuntu 22.04 carries glibc 2.35
- Ubuntu 24.04 carries glibc 2.39

A static library archive is a `.a` file, which you can picture as a small archive of object files, each holding a function or two. That fine granularity is what FID wants to work with.

### Building the Database

Three moves make the database. First you import the archives into a Ghidra project, telling it to recurse into each `.a` so the archive expands into its member object files. Skip the recursion and you get one opaque blob with nothing to fingerprint. Include it and every glibc function arrives as its own analyzable unit. Next you analyze them, which gives each function real instructions for FID to hash. Last you populate the database, hashing every function and filing the hash with its name and its glibc version.

I wrote a small script for each move so the whole run is repeatable and I never click through a menu twice. They are in the repo. The first build came out to 29,578 functions across those four glibc versions, in both 32-bit and 64-bit.

## The First Attempt, and the Lesson It Taught

I attached the database, ran Function ID again on the printf binary, and watched the count of named functions climb from 7 to 144. Progress, and yet the functions I had come for, the `fopen`, `fgets`, and `printf` calls inside the target, were all still `FUN_`. Something was off.

The lesson here is the most useful thing in this writeup, so I will state it plainly. Read the toolchain of your target before you build the database. Every binary carries a short string naming the compiler that produced it, and one command pulls it out:

```
strings -a <binary> | grep -iE 'glibc|release version|GCC:'
```

Mine reported `GCC 15.2.1 20250813`, a compiler recent enough to belong to a rolling-release distribution like Arch. None of the Ubuntu releases I had pulled ship anything close to that.

Function ID matches on exact bytes. glibc compiled by an older Ubuntu GCC lays down different bytes from glibc compiled by a newer Arch GCC, even for one and the same function. When the bytes differ the hash differs, and the match never happens. The 144 that did land were mostly dynamic-linker internals stable enough to look the same across builds. The functions I wanted were compiled another way and slipped past. My four Ubuntu versions were the wrong library for this binary, and that one compiler string would have told me so before I spent an afternoon finding out.

## The Fix: Match the Toolchain Exactly

The binary was built on Arch, and Arch keeps a dated archive of every package it has ever shipped, so I did not have to guess. I pulled the glibc that was live on Arch on the compiler's build date, the 13th of August 2025, which gave me byte for byte the library the author had linked against. It came back as glibc 2.42.

I built a small database from that one library, attached it beside the first, and ran Function ID once more. The named count went from 144 to 656, and `puts` resolved correctly on its own. The exact match did its job.

## The Blind Spot Both Tools Share

Even with the right library in hand, three functions in my target stayed wrong or missing, and the reason is worth understanding, because it is a permanent limit and knowing about it saves you a lot of squinting.

`printf` came back labeled `wscanf`. The thin wrapper functions in a C library, the likes of `printf`, `fprintf`, `scanf`, and `wscanf`, set up their arguments with almost identical code and differ only in a single internal pointer they hand off. Their fingerprints collide, so Function ID cannot separate them and picks one, which this time was the wrong one. The database is fine. Those functions are identical in the bytes FID inspects.

`fopen` stayed nameless because it is a 13-byte stub that does little more than jump into an internal routine, too small to fingerprint. `fgets` stayed nameless too.

The cure for this handful is a one-time fix by hand, which is ordinary practice. Function ID handles the bulk and you tidy up the few it cannot resolve. There is a shortcut for spotting them. Read the internal function each wrapper calls, since those larger routines do get named. `fopen`'s little stub jumps to `__fopen_internal`, and once you see that, the wrapper names itself.

## The Second Tool: BSim

Function ID is fast, automatic, and exact, and that exactness is also where it falls down, on functions that drift between builds or share their bytes with siblings. Ghidra answers that with a second tool called BSim. It works from the shape of the decompiled function and the data the function touches, which lets it match across compiler versions and separate functions that look byte-identical to FID.

The cost is in how you drive it. Function ID names things on its own during analysis, while BSim is something you query. You open a binary, run a search across its functions, and apply the strong matches, one query and one apply per file.

I built a BSim database from the same glibc programs I had already imported, so there was nothing new to download. Then I ran its Overview against the printf binary, which sweeps every function at once and reports how many have matches, and it lit up across all 843 functions in the program.

Two numbers guide you when you read BSim results. Hit count is how many library functions resemble the one in front of you. Significance is how distinctive that function is. A function with thousands of hits and low significance is generic and weak evidence, while one with a low hit count and high significance is distinctive, and a strong similarity match there is a confident call. Sort by significance, skip past the generic rows, and work down the distinctive ones.

One more detail earns BSim its place. It returned zero matches on the author's own function, the very one I cared about, which is exactly right, since that code resembles nothing in glibc. By the same logic, the functions with no matches are your shortlist of code to read. The tool points you at the interesting parts by leaving them blank.

## What You End Up With

Two layers that cover each other's gaps. Function ID names the mass of the library on its own the moment you analyze a binary, as long as you hold the matching build in your database. BSim, run by hand per file, fills in the larger functions Function ID missed and copes with binaries whose exact build you never pulled. The smallest wrappers fall through both tools, and for those the one-time fix by hand stands, a short list made easy by the named code around it.

The return grows the more you use it. The database serves every binary I open, and it improves each time I add a build I have run into. The hours behind it are spent once, and every future binary it names is time I never spend again.

## Adding a New Build Later

When a binary comes up empty, its build is missing from the database, and the routine to add it is the same every time:

1. Read the compiler string with `strings -a <binary> | grep -iE 'glibc|GCC:'`.
2. Pull that exact glibc. For a rolling distro, use the dated archive so you land on the precise version.
3. Import and populate it into the database.
4. Re-attach and run again.

The gaps close over time, and the thousand-function wall you began with becomes a short list on nearly everything you open. The scripts for all of it are in the repo. Take them, break them, and fix them when a difficult binary shows up, which is the whole reason to build the thing yourself.
