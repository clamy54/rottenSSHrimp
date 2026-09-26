# RottenSSHrimp

> A rotten approach to remote administration.

A connection manager for SSH, RDP and VNC on Windows, Linux and macOS, written
in Free Pascal / Lazarus, a stack whose obituary has been written several
times and which keeps failing to attend its own funeral. One tree of machines,
one tab per session, one encrypted file behind it all.

![The host tree on the left, an SSH session running top on the right](resources/screenshot.png)

![The host tree on the left, an RDP session running top on the right](resources/screenshot2.png)

The load average in that screenshot is 0.12, which is the only time anybody
takes a screenshot.

## Why

The alternatives come in three families: the one that wants a subscription
and quietly turns your infrastructure into somebody else's recurring revenue,
the one that ships three hundred megabytes of Chromium so a terminal can have
rounded corners, and `servers.txt`, open on your second monitor since 2019,
which at least has the decency not to pretend. RottenSSHrimp is native code
that does not want your email address, has never heard of a seat, starts in
under a second, and sends nothing anywhere except the sessions you asked for:
no telemetry, no "help us improve", no ping home to mention that you launched
it at 3 a.m. again. The name is a warning label, not false modesty. Something
in here will annoy you, but it will annoy you locally, offline, for free, and
forever.

## What it does

**Sessions.** SSH with a real terminal emulator, RDP, VNC and a local shell,
all in tabs, all in one window. Select up to sixteen hosts and open them as a
grid, either to watch them all while typing at one, or in broadcast mode,
because sometimes twelve machines need the same mistake made on all of them
simultaneously.

**The tree.** Folders, icons, search, credentials inherited per folder, and a
dashboard that answers "which of these are actually up" before the meeting
where you were going to claim they all were.

**Ping.** A tab that answers one question, is it coming back and since when,
with no root and no elevation. It says *no reply*, never *down*, because half
the healthy machines on earth have been silently dropping ICMP since a
hardening review in 2018 and it would be rude to accuse them. Mostly you will
use it for the ninety seconds after a reboot you started yourself.

**Clipboard.** Text follows you in and out of RDP and VNC sessions, and on
Windows so do files, both ways. Anything a server sends back is handled like a
parcel that ticks: capped, quarantined in a private folder, and never allowed
to follow a link. In SSH terminals the middle button pastes, as the prophets
of X11 intended.

**Jump hosts.** Any SSH host can serve as a bastion for any other connection,
RDP and VNC included. Ideal for the afternoon you have to repair the VPN
concentrator that everyone, yourself very much included, was connected through
until eleven minutes ago.

**SSH tunnels.** Local forwards, `ssh -L` style, opened with the terminal over
the same connection. Loopback only, because a tunnel on a real network
interface is a door into the server's network, held open by you, for anyone.
A tunnel that fails gets one banner, and the session carries on as if nothing
happened, which is also how most outages begin.

**File transfer.** Two panels, local and remote, the layout every file manager
has used since 1986 because nobody has improved on it without adding a cloud.
It speaks SFTP, not the old SCP that reads directories by parsing `ls` and
praying about the locale. A complete file is never replaced by half of one:
pull the cable mid-download and the old file is still there, intact and
faintly smug. Links are never followed, so a symlink to `/` stays a symlink
instead of becoming the afternoon you copied the whole disk, and when
something fails it says what, instead of *Completed*.

**Credentials.** Passwords, private keys, agent auth, and managed keys the
application generates, rotates, and pushes with a built-in `ssh-copy-id`.
Private keys go to libssh2 in memory and never touch the disk in plaintext,
which is the absolute floor of decency and yet remains a differentiator.

**Security keys.** A FIDO2 token such as a YubiKey can hold the private key
instead of the document, which then keeps only a handle and asks for a touch
at every connection. Whoever steals your document and your master password
gets an excellent inventory of your infrastructure and no way into those
hosts. Neither do you, once the token has been through a wash cycle or stayed
behind in a hotel room in Lyon: a key nobody can copy is a key *you* cannot
copy either. Enrol a second one on an afternoon when nothing is broken. There
will not be a convenient moment later.

**Containers and pods.** Docker and Podman containers, Kubernetes pods, opened
as terminal tabs like anything else. Because eventually the incident is inside
the cluster, and `kubectl exec` from memory at 2 a.m. has never once gone well.

**Imports.** Your `~/.ssh/config`, a CSV, or a JSON export from another
instance. Export a subtree to hand a colleague exactly the six machines they
need, about forty fewer than the last person who pasted the whole file into a
chat window.

## Getting it

Packages for all three systems are on the
[releases page](https://github.com/clamy54/RottenSSHrimp/releases): an
installer for Windows, a `.deb` or a tarball for Linux, a `.dmg` for macOS.
None is signed by anyone a corporation would vouch for, so SmartScreen and
Gatekeeper will both warn you that this software is not to be trusted (*More
info > Run anyway* on Windows, *Privacy & Security > Open Anyway* on macOS).
Both are working exactly as designed, and neither is lying. To build it
yourself, see [`BUILD.md`](BUILD.md).

## Third parties

RottenSSHrimp stands on libsodium, libssh2, FreeRDP, libvncclient, SQLite,
OpenSSL, zlib, libjpeg-turbo, cJSON, the LCL and the FPC runtime, plus a few
fonts and icon sets, all inventoried with their licenses in
[`LICENSES/THIRD-PARTY-NOTICES.md`](LICENSES/THIRD-PARTY-NOTICES.md). Read,
rather than skim, the entries for `libvncclient` (GPL-2.0-**or-later**, source
in [`third_party/libvnc/`](third_party/libvnc/)) and the Papirus icons
(GPL-3).

## License

GPL-3.0-or-later, see [`LICENSE`](LICENSE). No warranty, as the license says at
some length and in capital letters. If this software eats your connection tree
the night before an audit, you have the source, you have the bug, and you have
my sincere condolences, in that order.

(c) 2025-2026 Cyril LAMY.
