x# Icon sources

These are the **build inputs**, not what the application ships. They are
consumed by [`../scripts/gen-icons.lpr`](../scripts/gen-icons.lpr), which
recolours and resamples them into `resources/icons/` and embeds the result in
the binary. Nothing here is read at run time.

Two upstream projects, two licences, and one naming convention that will
mislead you if nobody warns you first. Consider yourself warned about eighty
words from now.

## Where they come from

| Directory | Count | Upstream | Licence |
|---|---|---|---|
| `folders/` | 23 | [Tabler Icons](https://tabler.io/icons) | [MIT](../LICENSES/Tabler-MIT.txt) |
| `transfer/` | 15 | [Tabler Icons](https://tabler.io/icons) | [MIT](../LICENSES/Tabler-MIT.txt) |
| `hosts/` | 18 | [Tabler Icons](https://tabler.io/icons) | [MIT](../LICENSES/Tabler-MIT.txt) |
| `extended-set/` | 85 | [Tabler Icons](https://tabler.io/icons) | [MIT](../LICENSES/Tabler-MIT.txt) |
| `folders-dark/` + `folders-light/` | 18 pairs | [Papirus](https://github.com/PapirusDevelopmentTeam/papirus-icon-theme) | [GPL-3.0](../LICENSES/GPL-3.0-or-later.txt) |
| `hosts-dark/` + `hosts-light/` | 18 pairs | [Papirus](https://github.com/PapirusDevelopmentTeam/papirus-icon-theme) | [GPL-3.0](../LICENSES/GPL-3.0-or-later.txt) |

**Tabler** (<https://github.com/tabler/tabler-icons>) supplies the monochrome
line icons: a dark stroke on a transparent background. The generator derives
*both* variants from each one by laying the alpha channel back over a solid
white or black. One source file, two outputs, no artwork touched.

`transfer/` is the odd one out and has its own section below.

**Papirus** supplies the colour icons, and they are used as-is, only resized.
Pinned to release
[`20250501`](https://github.com/PapirusDevelopmentTeam/papirus-icon-theme/tree/20250501),
which is where the matching upstream SVG sources live. **Anyone adding a
Papirus icon later must record the release it came from**, or that pin silently
becomes a lie for part of the set.

## `transfer/`: masks, not variants

The file transfer tab does not get an `ondark` / `onlight` pair. Its icons are
resized into a single **white alpha mask** per size, and the colour is applied
when the tab draws them.

That is not a shortcut, it is the requirement. In the two file panels the ink
colour *carries meaning*: a symlink is drawn in the accent colour, a special
file in the warning colour, an entry whose attributes could not be read in the
secondary colour, and a selected row in the selection text colour. A frozen
pair of variants would have flattened all of those into two shades.

Two consequences worth knowing before you touch it:

- **Twelve sizes, 12 to 64.** The tree asks for 16/24/32/48 and gets them; this
  tab asks for whatever the row height and the toolbar height work out to,
  which follows the UI font. The drawing code picks the largest size that
  *fits* and centres it, and never stretches, so a gap in that ladder shows up
  as an icon that looks too small next to its label.
- **The filename is the identifier**, as everywhere here, but these ones are
  mapped to drawing constants in
  [`../src/ui/uScpIcons.pas`](../src/ui/uScpIcons.pas) (`XferIdFor`) rather
  than stored in anybody's document. Renaming one is therefore safe for
  existing files and breaks the mapping instead: the icon silently falls back
  to the hand-drawn one. Grep `XferIdFor` after any rename.

Icons the tab needs and this set does not provide — the queue states (tick,
cross, warning, pause, play), the broken symlink, the special file, the drive
glyphs — stay hand-drawn in that same unit. They coexist on screen without
looking out of place because both follow the Tabler geometry, but they are not
Tabler artwork and are not covered by the attribution above.

## The `-dark` / `-light` trap

The suffix names the **theme the icon is for**, not the colour of the ink.

- `folders-dark/` = for a **dark theme** = pale artwork
- `folders-light/` = for a **light theme** = dark artwork

Get this backwards and you produce a set that is invisible on every background
it is shown against, which looks like a rendering bug and is not one. The
generator sidesteps the ambiguity internally by naming its outputs after the
**background** instead: `ondark` and `onlight`. Follow that convention if you
touch the code.

The `-dark`/`-light` pairs shipped here are **this project's own work**, not
the upstream `Papirus` / `Papirus-Dark` split. Only 7 of the 36 names exist in
both upstream themes; the other 29 exist solely in `Papirus`. Ours were made by
recolouring, which is a modification, and it is declared as one in
[`../LICENSES/THIRD-PARTY-NOTICES.md`](../LICENSES/THIRD-PARTY-NOTICES.md).

## Adding an icon

The filename **is** the identifier, and identifiers are stored in
`nodes.icon_id` inside people's encrypted documents. Renaming one does not
break the build, it breaks somebody's tree, silently, on next open. If you must
rename, add a back-compatibility alias in `uTreeIcons`.

1. Drop a PNG in `folders/`, `hosts/` or `extended-set/` (monochrome, dark
   stroke on transparent), or a matching pair in the `-dark` / `-light`
   directories. For the transfer tab, drop it in `transfer/` and point a
   `TScpIcon` at it in `XferIdFor`.
2. Regenerate:

   ```sh
   fpc -O2 scripts/gen-icons.lpr && scripts/gen-icons
   ```

3. Commit the regenerated `resources/icons/tree/*.png` and
   `resources/icons/transfer/*.png`, the updated
   `src/ui/uTreeIconCatalog.inc` and `src/ui/uScpIconCatalog.inc`, and both
   rewritten `.lpi` files.

`extended-set/` is the catch-all: if an identifier there collides with one
already provided by `folders/` or `hosts/`, the curated group wins and the
extended entry is dropped with a printed warning rather than an error. That is
why `pyramid` appears twice on disk and once in the catalogue.

## Trademarks

Reproduced from upstream, because it matters more here than it looks: every
application logo in the Papirus set is owned by its respective trademark
holder. `putty`, `realvnc-vncviewer`, `vmware-datacenter`, `icloud`,
`windows95` and friends are names belonging to other people.

Trademark rights are separate from the copyright licence and are **not**
granted by the GPL. The icons may be redistributed; the logos may not
necessarily be used to suggest anybody endorses this. They are here to label a
host in a tree, which is nominative use, and nothing more.

## The authority on all of this

[`../LICENSES/THIRD-PARTY-NOTICES.md`](../LICENSES/THIRD-PARTY-NOTICES.md) is
the compliance document: the modifications declared under GPL-3.0 section 5a,
the corresponding-source obligations.
