# Building RottenSSHrimp

Three platforms, three slightly different stories. The compiler is the same
everywhere; what differs is where the native libraries come from, and how
creatively each operating system makes that difficult.

Everything below assumes you cloned the repository and are sitting in its root.
It also assumes you want to build this rather than download it, which is a
choice, and one you are about to have several opportunities to reconsider.

## Common requirements

- **Lazarus 4.8** and **FPC 3.2.2**. Older Lazarus 4.x builds fine, 4.8 is what
  releases are built with. Only `lazbuild` is needed, the IDE is optional.
- The build scripts find `lazbuild` themselves: `PATH` first, then the usual
  install locations including `~/fpcupdeluxe/lazarus`. If yours lives somewhere
  exotic, put it on the `PATH`.

Both build scripts take an optional `--release` / `-Release`. Without it you
get a debug build with range checks and a much larger binary. Use it.

**One quirk worth knowing before it bites you:** `lazbuild` resolves the RCDATA
resource paths declared in the `.lpi` relative to the *current directory*, not
to the `.lpi`. The scripts `cd` into `app/` for the duration of the build. Call
`lazbuild` by hand from the repository root and it will not find the embedded
fonts and icons, will not say so, and will hand you a perfectly successful
build of an application with no icons. Enjoy discovering that at runtime.

### Regenerating the icons (rarely)

The 1468 icon PNGs under `resources/icons/` are committed, so a normal build
never touches them. If you add or change an icon in `icons/`, regenerate:

```sh
fpc -O2 scripts/gen-icons.lpr && scripts/gen-icons
```

One program, two sets. For the **tree** it recolours the monochrome sources
into their on-dark and on-light variants and resamples to 16/24/32/48. For the
**file transfer tab** it produces a single white-on-transparent mask per icon,
across twelve sizes from 12 to 64, because that tab tints its icons at draw
time and asks for whatever size the row height works out to. It then rewrites
`uTreeIconCatalog.inc`, `uScpIconCatalog.inc` and the `<Resources>` block of
both `app/rottensshrimp.lpi` and `tests/rsshscpsmoke.lpi` — the smoke suite
paints the same panels, so it needs the same resources or it checks a fallback
nobody sees. It depends on nothing but the FCL, so the toolchain you already
installed to build the application is the whole requirement.

The same "build from the project directory" rule applies to the smoke suite:
`lazbuild` resolves resource paths against the current directory, so
`scripts/run-tests.*` steps into `tests/` before building it.

It carries its own Lanczos resampler rather than using `TFPBaseInterpolation`
from the FCL, which accumulates into the destination `Word`: a filter with
negative lobes underflows there, wraps around, and turns every bit of ringing
into an opaque white pixel. Ask how that was discovered.

### Tests

Three of them, and they answer different questions.

**Unit tests.** No network, no server, no LCL. They cover the layers of the
File Transfer tab that can be reasoned about in isolation: path joining, normalisation
and containment on both platforms, the rules that decide which filenames from a
server are acceptable to act on, the transfer queue's state machine, and the
transfer engine driven against fake filesystems that inject access denied,
disk full, short reads, short writes, premature EOF, lost connections and
servers with no atomic rename.

```sh
lazbuild tests/rsshtests.lpi && ./rsshtests
```

It builds to the repository *root* on purpose: the last suite loads the real
`libssh2` and checks that every SFTP symbol resolves and that
`LIBSSH2_SFTP_ATTRIBUTES` has the layout the binding assumes. That record
starts with an `unsigned long`, which is four bytes on Windows x64 and eight
everywhere else, followed by a 64-bit integer that has to be aligned. Getting
it wrong produces no error and no crash: it produces files of several petabytes
dated 1970. The check runs on whichever platform you are on, which is the only
place it can mean anything.

Exit code is non-zero if anything fails, so it drops into CI unchanged.

**A smoke test of the File Transfer tab.** A separate project because it needs the LCL,
which the unit tests deliberately do not:

```sh
lazbuild tests/rsshscpsmoke.lpi && ./rsshscpsmoke
```

It builds the tab, shows it, lets it paint, starts its three threads against a
port where nothing is listening, then shuts it down and frees it. Nothing
leaves the machine. It exists because none of the unit tests touch a control,
and an owner-drawn panel that measures text before it has a parent window
raises inside its own constructor -- which is visible only when the tab is
opened. It opens a window briefly, so it needs a graphical session.

It also checks the rules of the drag between the two panels, which is the part
that decides where files get written: a panel refuses its own selection,
accepts the other one's, and resolves a drop to the folder under the cursor --
never to a file, and never to a symlink. `--shot <file.png>` saves an image of
the window, because a layout is not something you read in the source.

Both test scripts run it after the unit tests:

```sh
scripts/run-tests.sh          # or: powershell -File scripts\run-tests.ps1
```

**An SFTP integration scenario.** Not part of any build, because it needs a
document, its password and a reachable host:

```sh
fpc -Mobjfpc -Sh -O1 -Fusrc/util -Fusrc/application -Fusrc/platform -Fusrc/sessions/ssh -Fusrc/sessions/common -Fusrc/crypto -Fusrc/storage -Fusrc/domain -Fubindings/libsodium -Fubindings/libssh2 -Fubindings/libfido2 -Fubindings/sqlite -Futests -Fu<lazarus>/components/lazutils/lib/$(TargetCPU)-$(TargetOS) -FE. tests/rsshsftpit.lpr

./rsshsftpit <document.rsh> <password> <host-name-in-the-tree> [--big]
```

It drives the *same* transport and the *same* engine the File Transfer tab uses, minus
the LCL, against a real server: connect, list, round-trip empty, small and
large files, names with spaces, quotes, accents and a leading dash, a recursive
tree, duplication in place on both sides, the three conflict resolutions,
rename, and recursive delete. Every downloaded file is compared byte for byte
with what was sent.

`uScpPaths` uses `LazUTF8`, so the LazUtils unit path has to be on the command
line even though nothing here touches the LCL.

It works in a directory it creates in the remote home and removes afterwards.
`--cleanup` instead of `--big` removes what an interrupted run left behind.

`--big` adds a file of just over 4 GiB, which is the size at which a 32-bit
counter overflows in silence. It asks the server how much room it has first,
via `statvfs@openssh.com`, and skips rather than proceed if the answer is not
comfortable or not available: filling somebody else's disk is not a test
result. No password or key ever reaches the output or a temporary file.

---

## Windows

The easy one, because the native DLLs are committed to the repository.

```powershell
powershell -File scripts\build.ps1 -Release
```

Output: `rottensshrimp.exe` at the repository root. Run it from there: the
loaders look for the DLLs *next to the executable*, using an absolute path
built from `ParamStr(0)`. Never the `PATH`, never the current directory. That
is deliberate, and it means a copy of the `.exe` on its own does nothing.

### The DLLs

Fourteen of them, x64, versioned in the repository so that a fresh clone builds
and runs without you losing an afternoon to vcpkg. Provenance, versions and
SHA-256 for every one are recorded in
[`packaging/windows/DEPS.md`](packaging/windows/DEPS.md), and
`scripts/check-win-deps.sh` verifies that the document and the files still
agree.

That check exists because the document was once wrong about nine hashes out of
eleven, after a re-provisioning that nobody wrote down. A provenance file with
stale hashes is worse than no provenance file: it proves nothing while looking
exactly like proof, and it is the sort of thing you only discover while writing
an incident report.

You need nothing else installed. The DLLs are MSVC builds and link against
`VCRUNTIME140.dll`, which is not part of Windows, so that one is versioned here
too and travels with the others. The rest of what they need is the Universal
CRT, part of Windows since Windows 10.

### Rebuilding the RDP shim (rarely)

`rssh_rdp_shim.dll` is committed prebuilt. You only need to rebuild it if you
re-provision FreeRDP, and if you do, you **must**: the binding checks which
version the shim was built against and quietly discards it on a mismatch,
falling back to the hardcoded offsets. Nothing breaks, nothing complains, and
you simply ship the degraded path to everybody without ever finding out.

It is built with MSVC against the headers of the vcpkg build. The procedure is
in `packaging/windows/DEPS.md`, including the overlay-port workaround needed
because the vcpkg registry's FreeRDP port sat at 3.26.0 while two heap
overflows in the TS Gateway client waited politely for someone to notice.

### Installer

Inno Setup 6, then:

```powershell
ISCC.exe dist\windows\rottensshrimp.iss
```

Output: `dist\windows\output\RottenSSHrimp-Setup-<version>.exe`. See
[`dist/README.md`](dist/README.md).

### Signing (there is none)

Neither the executable nor the installer is Authenticode signed. A certificate
costs a few hundred euros a year for the privilege of a warning dialog being
slightly less rude about you, and the EV variety additionally wants a hardware
token you would then have to leave plugged into a build machine forever.

So SmartScreen will meet the first downloads with *"Windows protected your
PC"*, and will render the *Don't run* button noticeably larger than the one you
actually want. Click *More info*, then *Run anyway*.

Being told by an operating system that software called RottenSSHrimp comes from
an unknown publisher and cannot be trusted is not really a defect. It is
accurate labelling, delivered free of charge. If you want something firmer than
vibes, the release page lists SHA-256 sums; that is what they are for.

---

## Linux

Here the libraries come from your distribution, with two deliberate exceptions.

### System packages

| | Debian/Ubuntu | Fedora/RHEL | Arch | openSUSE |
|---|---|---|---|---|
| FreeRDP 3 | `libfreerdp3-3` `libfreerdp-client3-3` `libwinpr3-3` | `freerdp-libs` | `freerdp` | `libfreerdp3` |
| libssh2 | `libssh2-1t64` | `libssh2` | `libssh2` | `libssh2-1` |
| SQLite 3 | `libsqlite3-0` | `sqlite-libs` | `sqlite` | `libsqlite3-0` |
| libsodium | `libsodium23` | `libsodium` | `libsodium` | `libsodium23` |
| libfido2 (optional: FIDO2 security keys) | `libfido2-1` | `libfido2` | `libfido2` | `libfido2-1` |

To build, add the FreeRDP **headers** (`freerdp3-dev` + `libwinpr3-dev` on
Debian, `freerdp-devel` on Fedora, `freerdp` on Arch, `freerdp3-devel` on
openSUSE), plus `cmake`, `gcc`, `pkg-config` and the `zlib` and `libjpeg`
development headers for the vendored libvncclient.

### Build

```sh
scripts/build-libvnc.sh          # once, and after any patch change
scripts/build.sh --release
```

Output: `rottensshrimp` at the repository root, and `lib/` beside it.

### The two libraries that do not come from the system

**`libvncclient`** is built from pinned, patched source, and the loader refuses
every other copy on the machine. Your distribution ships an unfixed 0.9.15 with
pre-authentication heap out-of-bounds accesses in the Tight and UltraZip
decoders, which means a hostile server, or anyone sitting between you and an
honest one, gets to write outside the heap before you have typed a password.
Upstream has commits. Upstream does not have a release. It has been like that
for a while, and everyone has decided to live with it.

It is also built with TLS/SASL, which shifts the `rfbClient` struct the binding
reads by offset, so even the vulnerable copy would be the wrong shape. Two
independent reasons, either one sufficient. Without our build, VNC does not
work at all, and that is the intended behaviour: not working is a state you
notice, unlike the alternative. `build-libvnc.sh` verifies the tarball hash
before touching it and fails hard if a patch does not apply cleanly, because a
security patch that silently did not apply is just a comforting filename.

It also refuses to build when the configuration it obtained is not the one the
binding's offset table describes. `-DWITH_JPEG=ON` only asks CMake to *look*
for libjpeg; missing headers mean a library built without it, whose
`rfbClient` is 40 bytes shorter — large enough to pass the size check at load
time and fail the layout check, so VNC vanishes with a message only a terminal
launch reveals. The recipe reads the generated `rfbconfig.h`, and
`scripts/check-vnc-offsets.sh` — run by CI and by every packaging script —
compares the table in `bindings/libvnc/uLibVncApi.pas` against the library
actually built.

**`librssh_rdp_shim.so`** resolves FreeRDP's memory layout through the C
compiler instead of through offsets typed in by hand and blessed by hope.
`build.sh` builds it if the headers are there and shrugs if they are not: RDP
still works, falling back to the offset table, guarded by runtime layout
witnesses and a rendering fallback. That fallback is a parachute, not a
staircase. Use it in the spirit intended. The shim describes only the FreeRDP
version it was compiled against and is discarded on a major mismatch, so build
it on the machine that will run it, or let the package do it for you.

### Packaging

```sh
dist/linux/build-deb.sh            # .deb, the recommended shape
scripts/make-linux-dist.sh --release   # relocatable tarball otherwise
```

Details and the reason the `.deb` is better in
[`dist/README.md`](dist/README.md).

---

## macOS

arm64. Tested on Apple Silicon only; Intel is not built or released.

### Dependencies

```sh
brew install freerdp libssh2 libsodium libfido2 cmake pkg-config jpeg-turbo
```

SQLite comes from the system and is never bundled. Lazarus 4.8 for aarch64 is
the SourceForge distribution, not `brew` and not `setup-lazarus`: the latter
only installs the x86_64 variant, which would give you a Rosetta build.

### Build

```sh
scripts/make-app.sh --release
```

That single script *is* the macOS pipeline. It builds the binary, creates
`RottenSSHrimp.app`, copies the Homebrew dylibs into `Contents/Frameworks/`
along with their transitive dependencies, rewrites every install name to
`@loader_path`, builds the RDP shim, generates the `.icns` and the
`Info.plist`, writes a build manifest and a CycloneDX SBOM, and applies an
ad-hoc signature, which is mandatory on Apple Silicon.

It **fails the build** if any bundled dylib still points at `/opt/homebrew` or
`/usr/local` afterwards. An app that works perfectly on the machine that built
it and dies instantly everywhere else is invisible to its author by
construction, which is why the check is a hard failure and not a warning
scrolling past at 3 a.m.

Two more traps worth naming, both already handled by the scripts, both
discovered the slow way:

- The `.lpi` forces `-ld_classic` on Darwin. Xcode 15's modern linker looks at
  the Objective-C metadata FPC emits for LCL-Cocoa and calls it a "malformed
  method list atom", which is a remarkably polite way of saying that two
  toolchains disagree and you are the one who has to fix it.
- The `Info.plist` deliberately carries no `NSPrincipalClass`. LCL-Cocoa
  instantiates the application class from that key, and a plain `NSApplication`
  gets you an app that opens, runs, and cannot be quit. Not "quits slowly".
  Cannot be quit. Force Quit exists for people who set that key.

### Signing, or the ad-hoc theatre of it

The releases are ad-hoc signed, which means signed by nobody in particular,
which is precisely as reassuring as it sounds. It is enough to satisfy the
Apple Silicon loader, which refuses to run unsigned code at all, and nowhere
near enough for Gatekeeper, which blocks the first launch and thoughtfully
offers *Move to Trash* as the default button. Open the app once, watch it be
refused, then go to *System Settings > Privacy & Security* and click *Open
Anyway*. It only happens once.

Notarizing would mean a paid Developer ID, an Apple account, and uploading
every build to Cupertino to ask permission. Until then the
software is exactly as trusted as its name suggests, and the operating system
is right to say so out loud.

If you do have a Developer ID, set `RSSH_SIGN_IDENTITY` before running
`make-app.sh` (it then adds the hardened runtime and the entitlements), then:

```sh
dist/macos/make-dmg.sh
```

Notarization stays manual on purpose: it needs an account and the network, and
neither belongs in a build script. The two commands are at the top of
`make-dmg.sh`.

---

## When it freezes (macOS)

It happens. While the window is still unresponsive, and *before* you kill it in
irritation:

```sh
scripts/diag-hang.sh
```

It samples the main thread for three seconds and prints where the process is
actually stuck. A frozen thread is the one thing in this business that holds
still long enough to be photographed, so the sample is stable and usually
conclusive: waiting on a `pthread_join`, spinning in one of our loops, or
parked inside libssh2.

Attach the file it names to the bug report. "It hangs sometimes" is a feeling.
This is evidence.


