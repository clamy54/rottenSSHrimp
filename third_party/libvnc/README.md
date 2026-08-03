# Vendored libvncclient (pinned + patched)

RottenSSHrimp does **not** load a system `libvncclient`. It builds its own from
pinned, patched source. Two reasons:

1. **Security.** The 0.9.15 release, still the latest, carries
   pre-authentication heap out-of-bounds accesses in the Tight/UltraZip
   decoders, reachable from any malicious or man-in-the-middle VNC server.
   There is no fixed upstream release. There are commits on `master`, and for
   one flaw (the Tight decompressed-rows write described below) there is no
   public fix at all.

   So every VNC client built on the packaged library, on Homebrew and on every
   distribution, hands a hostile server a heap write before authentication has
   happened. This has been the situation for a while. Nobody appears alarmed.
   We patch it ourselves, which is less an act of diligence than the minimum
   required to sleep.

   **Note on CVE numbers.** The `20xx-xxxxx` identifiers in the patch filenames
   are best-effort labels; their exact mapping to public CVE records is **not**
   verified. What *is* verified is the code defect each patch removes, stated
   per-patch below. Trust the description, not the number: a CVE identifier is
   a filing reference, not a proof of anything, and treating one as evidence is
   how a project ends up patched against a number rather than against a bug.
2. **Determinism.** The Pascal binding reads `rfbClient` by hardcoded offsets
   (the struct layout depends on build config). Building the library ourselves
   with a *fixed* config makes those offsets deterministic and exact, and
   `scripts/gen-vnc-offsets.c` regenerates them against this build.

## Contents (the corresponding source, GPL-3.0 §1)

- `SHA256SUMS`: pinned hash of the upstream `LibVNCServer-0.9.15.tar.gz`.
- `patches/`: three security patches (applied in lexicographic order). What
  each one actually changes:
  - `0001-CVE-2026-44988-tight-gradient-overflow.patch`: **`tight.c`**, upstream
    commit `5b27054`. Bounds the Gradient filter width (`rw`) so the fixed-size
    stack rows `thisRow[2048*3]` / `tightPrevRow` cannot overflow.
  - `0002-CVE-2026-50538-ultrazip-subrect-bounds.patch`: **`ultra.c`**, upstream
    commit `009008e`. Adds bounds checks to UltraZip sub-rectangle parsing,
    against heap out-of-bounds **reads** of the decompressed buffer.
  - `0003-tight-decode-rows-oob-write.patch`: **`tight.c`**, **locally
    authored** (no public upstream fix at time of writing). `HandleTightBPP()`
    writes decompressed scanlines into `frameBuffer` at row `ry+rowsProcessed`
    with no check that the decompressed row count stays within the announced
    rectangle height `rh`. The only check is *after* the loop. A malicious
    server can inflate a stream into more than `rh` rows, driving a
    pre-auth heap out-of-bounds **write**. The patch bounds `numRows` against
    `rh - rowsProcessed` before each framebuffer write.

The build recipe is `../../scripts/build-libvnc.sh` (macOS and Linux; needs
`cmake` plus the zlib and JPEG development headers). `out/.build-stamp` records
a hash of the pinned tarball + this recipe + all patches. `scripts/make-app.sh`
rebuilds whenever that hash moves, because the alternative is editing a
security patch, shipping the library built before the edit, and believing the
filename.

The struct offsets in `bindings/libvnc/uLibVncApi.pas` are **per platform**:
macOS and Linux agree up to `si`, then diverge because the embedded pthread
primitives differ in size (`pthread_mutex_t` is 64 bytes on Darwin, 40 on
glibc). Regenerate them against the local build with the command below after
changing the version or the config, and never copy one platform's set to
another. `CheckStructLayout` refuses the library at load time if you do, which
is the pleasant outcome; the unpleasant one, in a world without that check, is
a framebuffer written through a pointer read from the wrong offset.

## Build

```sh
./scripts/build-libvnc.sh
```

Fetches the pinned tarball (verifying its SHA-256 before doing anything),
applies the patches (hard failure if any does not apply cleanly), configures
with a locked minimal config (zlib + JPEG **on**; TLS, SASL, crypto backends,
PNG, websockets, filetransfer and examples all **off**), and builds only the
`vncclient` target.

Output (git-ignored, reproducible), named per platform:

- macOS: `out/lib/libvncclient.0.9.15.dylib` (+ `.1` / plain symlinks)
- Linux: `out/lib/libvncclient.so.0.9.15` (+ `.so.1` / `.so` symlinks)
- `out/include/rfb/`: headers including the generated `rfbconfig.h`, so the
  offsets can be regenerated standalone against this exact build:

  ```sh
  cc -Ithird_party/libvnc/out/include scripts/gen-vnc-offsets.c -o /tmp/gen && /tmp/gen
  ```

`cache/`, `work/`, `out/` are build artifacts and are not committed. The
source that produces them (patches, hash, recipe) is.

## Regenerating after a version or patch change

1. Update `SHA256SUMS` and the version in `build-libvnc.sh`.
2. Re-run `./scripts/build-libvnc.sh`.
3. Regenerate offsets (command above) and paste into
   `bindings/libvnc/uLibVncApi.pas`.
4. Re-run the test suite. `uVncApiTests` reverifies the layout against the
   built library at load time.
5. Re-check the GPL-2-or-later compatibility (see `LICENSES/THIRD-PARTY-NOTICES.md`).
