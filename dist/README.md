# Packaging RottenSSHrimp

Build the binary first (see [`../BUILD.md`](../BUILD.md)), then create a
distributable package for the target platform.

Two things every package must carry, whatever the platform:

- **The native libraries, next to the executable.** The loaders
  (`bindings/*`) resolve them as absolute paths built from `ParamStr(0)`,
  never through `PATH`, never through the current directory. On Windows that
  means the DLLs sit *in* the install directory; on Linux and macOS the two
  libraries that travel with the app live in `lib/` (resp.
  `Contents/Frameworks/`) right beside the binary. Put them one level away and
  nothing loads.
- **The licenses, and for one of them the source.** Every package ships
  `LICENSE` and `LICENSES/`. It also ships the *corresponding source* of
  `libvncclient`: the pinned tarball itself, its hash, the three security
  patches and the build recipe. That library is GPL-2.0-or-later and we modify
  it, so shipping the binary without the source is not an oversight, it is a
  license violation All three
  packaging scripts copy it, and all three **verify its SHA-256 before doing
  so**: a corrupt tarball would satisfy the letter of the obligation while
  reconstructing nothing, which is the worst of both worlds.

The version comes from `RSSH_VERSION` in `src/util/uVersion.pas`, the single
source of truth, also shown in `Help > About`. All three packagings extract it
themselves; the Inno Setup script reads it at compile time and errors out if it
is missing.

## Windows (`windows/`)

Inno Setup 6 installer.

1. `powershell -File scripts\build.ps1 -Release` (produces `rottensshrimp.exe`
   at the repository root).
2. `ISCC.exe dist\windows\rottensshrimp.iss` (or open it in the Inno Setup
   IDE). Output:
   `dist\windows\output\RottenSSHrimp-Setup-<version>.exe`.

Installs the executable, the fifteen native DLLs, the licenses and the
libvncclient source into the install directory, plus Start Menu (and optional
desktop) shortcuts and an optional `.rsh` file association. Double-clicking a
`.rsh` opens it: the installer passes the path as an argument, and it is
validated before anything is opened (see `src/util/uOpenArg.pas`).

The DLLs are versioned in this repository rather than rebuilt per clone; their
provenance and SHA-256 are recorded in
[`../packaging/windows/DEPS.md`](../packaging/windows/DEPS.md) and checked by
`scripts/check-win-deps.sh`.

**`legacy.dll` is not optional.** It is the OpenSSL "legacy" provider. RDP
authentication goes through NLA, NLA goes through NTLM, and NTLM needs MD4 and
RC4, two algorithms OpenSSL 3.x banished to a separate module out of
embarrassment. So the file whose name announces that nobody should be using it
any more is a hard requirement for logging into Windows in 2026. Remove it as
housekeeping and you get `ERRCONNECT_LOGON_FAILURE`, a black screen and a
disconnect, with no hint that the cause was you tidying up.

**Runtime dependency:** none to install. The DLLs are MSVC builds, so they need
`VCRUNTIME140.dll`, which is not part of Windows — the installer ships it
alongside them. Asking the user for the Visual C++ redistributable instead
would mean 25 MB and an elevation prompt for a 120 KB file, and it would fail
exactly where it hurts: the freshly installed Windows Server where you are
trying to fix something urgent. Everything else those DLLs call is the
Universal CRT, part of Windows since Windows 10.

### License pages

The wizard's **License Agreement** page shows `LICENSE` (GPL-3), the license
of RottenSSHrimp itself, the one the user accepts. The **Information** page
right after shows the third-party inventory.

Showing it is a courtesy, not an obligation: what the licenses require is that
their text *accompanies* the distribution, which `[Files]` already does. But
Inno renders its info file verbatim, and `THIRD-PARTY-NOTICES.md` shown raw is
an unreadable hedge of `#`, `**` and table pipes, which nobody would read even
if they had intended to, which they did not.

So `make-notices.ps1` renders it to plain text (`third-party.txt`), and
`rottensshrimp.iss` **runs that script at compile time** (`#expr Exec`). The
page therefore cannot drift from its source, which is the only way a generated
document ever stays honest: take away the opportunity to forget.
`third-party.txt` is generated, hence git-ignored; the Markdown stays the
single source of truth and is the copy actually installed.

## Linux (`linux/`)

Two shapes, and the `.deb` is the better one.

**`.deb` (recommended)**: `dist/linux/build-deb.sh [version]`, after
`scripts/build.sh --release`. Needs `dpkg-deb` and `cmake`; ImageMagick
optional, for properly sized icons. Output:
`dist/linux/build/rottensshrimp_<version>_<arch>.deb`.

**Relocatable tarball**: `scripts/make-linux-dist.sh --release`, for
distributions with no package. Output:
`dist/linux/build/rottensshrimp-<version>-linux-<arch>.tar.gz`, with an
`install.sh` that needs no privileges.

Both ship `linux/rottensshrimp.desktop` and `linux/rottensshrimp-mime.xml`, the
same two files, so double-clicking a `.rsh` opens it. The `.desktop` alone is
not enough: it names `application/x-rottensshrimp-document`, and without the
MIME definition that type exists for nobody. The definition matches on the
`RSSHDOC` header rather than the extension. Both packagings rebuild the MIME
and desktop caches after installing, because those are caches: dropping files
in place changes nothing until they are regenerated. The tarball installs into
`~/.local/share`, so it associates for the current user only.

The `.deb` wins because of the shim. `librssh_rdp_shim.so` describes only the
FreeRDP version it was *compiled* against, and the binding discards a shim from
a different major rather than trust it. A `.deb` built on its own target has no
such gap. A tarball landing on an unknown distribution might, in which case RDP
silently falls back to the hardcoded offsets and works, because that is what
the fallback is for, and nobody ever finds out that the good path was never
taken. Belt and braces are both fine. Wearing only the belt and calling it a
suit is a different claim.

**Layout note.** The binary is *not* installed as `/usr/bin/rottensshrimp`.
Since the loaders look for `lib/` next to the executable, everything lives in
`/usr/lib/rottensshrimp/`, and `/usr/bin/rottensshrimp` is a small wrapper that
`exec`s it. A symlink would *not* work: `argv[0]` would remain
`/usr/bin/rottensshrimp` and `lib/` would be looked up in `/usr/bin`.

**Dependencies come from two places, and the second one is the trap.** What is
*linked* into the binary (GTK, X11, libc) is computed by `dpkg-shlibdeps` and
never hand-written, because package names drift under you: Ubuntu's time64
transition renamed `libgtk2.0-0` to `libgtk2.0-0t64`, and a `Depends` on a
package that no longer exists produces a `.deb` installable on precisely zero
machines, with nothing failing at build time to warn you.

But FreeRDP, libssh2, SQLite and libsodium are opened with `dlopen`, which
makes them **invisible** to `dpkg-shlibdeps`, a tool that reads symbol tables
and not intentions. They are listed by hand in `build-deb.sh`. Delete that list
and the package builds cleanly, installs cleanly, launches cleanly, shows you
your whole tree of machines, and then refuses to open a single session. Every
signal says fine. Nothing is fine. Budget an afternoon.

## macOS (`macos/`)

`.app` bundle then `.dmg`.

1. `scripts/make-app.sh --release` builds `RottenSSHrimp.app` at the repository
   root. **That script is the macOS pipeline** (build → bundle → transitive
   closure of the Homebrew dylibs into `Contents/Frameworks/` with
   `@loader_path` install names → shim → `.icns` → `Info.plist` → build
   manifest → SBOM → ad-hoc signature, which is mandatory on Apple Silicon).
   It is not duplicated here.
2. `dist/macos/make-dmg.sh [version]` wraps that bundle into a
   drag-to-Applications `.dmg`. Output:
   `dist/macos/build/RottenSSHrimp-<ver>.dmg`.

The bundling script **fails the build if any dylib still references
`/opt/homebrew` or `/usr/local`** after relocation. This is the failure mode
worth being paranoid about, because it is undetectable from the machine that
caused it: everything launches, everything works, and the app is broken for
every human being who is not you.

The install window is laid out (app left, `/Applications` alias right,
`Licenses/` below). That layout lives in the volume's `.DS_Store`, so the
script builds a read/write image, styles it **through the Finder**, then
compresses it. Yes, that means the packaging pipeline drives a file manager
with AppleScript to position icons in a window, in 2026. Driving the Finder
needs an automation (TCC) permission that may be missing (CI, locked machine),
so the script gives it 30 seconds and then ships the `.dmg` unstyled rather
than hanging the build until someone notices.

With only an ad-hoc signature, Gatekeeper blocks the first launch: open the app
once, then allow it in *System Settings > Privacy & Security* (Open Anyway).
Developer ID signing and notarization are documented at the top of
`make-dmg.sh`, in the tone of someone who has read Apple's documentation and
would rather not again.

## Releases (GitHub Actions)

Everything above also runs unattended in
[`../.github/workflows/release.yml`](../.github/workflows/release.yml):

1. Bump `RSSH_VERSION` in `src/util/uVersion.pas`, commit.
2. `git tag v<version> && git push origin v<version>`.

The workflow refuses a tag that does not match `RSSH_VERSION` before building
anything, which exists solely to prevent the traditional release: tag pushed,
three platforms compiled, forty minutes burned, and a `v1.1` archive containing
a binary that cheerfully reports 1.0 in its About box for the rest of its life.

Then it builds the three packages (macOS arm64 `.dmg`, Ubuntu amd64 `.deb`,
Windows x64 setup, zipped) and attaches them to a **draft** release. Review the
draft on the releases page, then publish it yourself. Nothing here publishes on
your behalf.

Dry run without a tag: *Actions > release > Run workflow*. Builds and uploads
the packages as run artifacts, skips the release.

Rerunning a failed run is safe: an existing release is reused and its files
replaced, never duplicated, so nobody ends up downloading
`RottenSSHrimp-Setup-1.0-1.exe` and wondering which one is real.
