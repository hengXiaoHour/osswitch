# osswitch

One command to pick which OS this laptop boots next: **Windows 11** or **Manjaro**.
It removes the "reboot, then mash F12 and hope" step from switching between the
two systems.

There are two halves, and they take the same commands:

| command | Linux half | Windows half |
| --- | --- | --- |
| `osswitch status` | what boots by default, what is pending | same |
| `osswitch list` | the boot entries this machine has | same |
| `osswitch windows` | queue Windows, reboot | same |
| `osswitch manjaro` | queue Manjaro, reboot | same |
| `osswitch restore` | drop a pending switch | same |

The same names, deliberately: one habit has to work from either side of the
dual boot. What differs is only the mechanism — `efibootmgr -n` (BootNext) from
Linux, `bcdedit` from Windows.

Both halves set a **one-shot boot override**: the firmware uses it for the very
next boot and then discards it. Nothing is permanently reordered, so a switch
that goes wrong falls through to the normal order on the next boot, and nothing
needs undoing after a successful one.

- [Linux half](#linux-half-efibootmgr) — below
- [Windows half](#windows-half-bcdedit)

---

## Linux half (efibootmgr)

`linux/osswitch` — one bash script, `efibootmgr`, and two GNOME launchers. This
is the side that runs *on the machine you are typing at*, so it is the one you
will actually use to leave.

### Install

```bash
git clone https://github.com/hengXiaoHour/osswitch.git
cd osswitch/linux
./install.sh -DryRun     # print what it would do, change nothing
./install.sh
```

Everything lands in `$HOME/.local`; installing needs no root and writes nothing
system-wide:

```
~/.local/bin/osswitch
~/.local/share/applications/osswitch-windows.desktop
~/.local/share/applications/osswitch-manjaro.desktop
~/.local/share/icons/hicolor/{48x48,256x256}/apps/osswitch-{windows,manjaro}.png
```

`./install.sh -Remove` takes all of it back out. The icons are rendered from the
same artwork the Windows half ships, so the two launchers look alike.

**One dependency worth having: `zenity` (or `yad`).** The launchers ask before
rebooting and show a dialog if anything fails; neither tool is present on a
stock Manjaro install. `sudo pacman -S zenity`. The script also works fine from
a terminal without them — it just does not ask, because you typed the command.

### The two launchers

| Launcher | Does |
| --- | --- |
| **Switch to Windows 11** | `osswitch windows` — queue a one-shot override for Windows, then reboot |
| **Switch to Manjaro** | `osswitch manjaro` — queue Manjaro (which *replaces* a pending Windows override), then reboot |

Both ask "Reboot into … now?" first, and if anything fails they put the reason in
a dialog rather than dying silently where nobody will see it.

The Manjaro launcher deliberately does not take the "it is already the default,
just reboot" shortcut. If a Windows override is still queued and unused, a plain
reboot follows it into Windows — the exact opposite of what the button promises.
Writing `BootNext=Manjaro` settles the question instead of assuming it.

### Before you trust it with a real reboot

```bash
osswitch status                    # read-only, needs no root at all
osswitch windows --dry-run         # applies, verifies, prints, does NOT reboot
osswitch restore                   # drop the pending switch
osswitch windows                   # the real thing
```

`--dry-run` is the same gate as the Windows half's `-DryRun`: it writes and
reads back the firmware variable and then stops. If the write did not land, it
refuses to reboot.

### Tests

```bash
./linux/tests/test_osswitch.sh              # 95 checks
./linux/tests/test_osswitch.sh -Mutants     # plus 11 deliberate breakages
```

The suite runs the **real** script against a stub `efibootmgr` that keeps fake
boot variables in a temp file, a stub `systemctl` that records reboot requests
instead of performing them, and a stub `pkexec` that wipes the environment the
way real polkit does. **Nothing in it can reboot anything.**

Covered: read-only `status`/`list`, both dry-run directions, the reboot, an
already-queued switch, a missing target, firmware that ignores the write,
`restore` with and without a pending override, a firmware that ignores the
delete, bad input, the dialog asking exactly once across an escalation, a
declined reboot, and a replay of
`tests/fixture-real-efibootmgr-enum.txt` — real `efibootmgr -v` output captured
from this machine (with the disk serial blanked), which is what pins the parser
to reality rather than to an assumption.

`-Mutants` then breaks the script eleven ways and requires the suite to fail on
each, so a green suite means something: no write-back verification, verifying
the wrong value, `--dry-run` ignored, `restore` using the wrong `efibootmgr`
flag, `restore` not checking its own result, a silent fallback when the target
entry is missing, entry parsing reverted to field splitting, the error dialog
removed, the reboot question removed, the question asked twice across an
escalation, and pkexec forwarding that drops the flags. An anchor that no longer
matches is reported as `[skip]`, never as a blind pass.

### Test seams

| Seam | Why |
| --- | --- |
| `--efibootmgr PATH` / `--systemctl PATH` | run the real script against the stubs |
| `OSSWITCH_DRY_RUN=1` | the dry run, as an environment variable |
| `OSSWITCH_TEST_ASSUME_ROOT=1` | skip the pkexec re-exec. Grants nothing: `efibootmgr` still refuses an unprivileged process |

### Four things this machine taught us

**`-b` is not `--delete-bootnext`.** The first version of `restore` called
`efibootmgr -b`, which is *modify BootXXXX* — it takes an argument, and given
none it just errors. `osswitch cancel` therefore did nothing at all, and looked
like it had. The flag is `-N` / `--delete-bootnext`, and the suite asserts on
the exact call.

**pkexec throws the environment away.** It runs the target with a sanitised
environment, so anything chosen by an environment variable — the GUI mode, the
dry run — is simply gone by the time the script is root. The launcher modes are
therefore argv flags (`--gui`, `--dry-run`), which pkexec passes through
untouched, and the whole argv is re-executed verbatim.

**A flag that pkexec drops is a feature that silently does nothing.** Both of
those are covered by mutation: break the forwarding, and the suite must catch a
reboot that happens during a dry run.

**sed cannot parse this output.** `efibootmgr -v` puts a TAB between an entry's
description and its device path. A bracket expression like `[^\t]` is not a tab
in sed — it is "neither backslash nor t" — so descriptions get quietly
truncated (`Manjaro` → `Manjar`). The parsing is awk, slicing on the real tab.

---

## Windows half (bcdedit)

### How it works

It sets a **one-shot boot override** on the UEFI firmware boot manager — the same
idea as the Linux half's `efibootmgr -n` (BootNext). The firmware uses it for the
very next boot and then discards it, so:

- the machine's own boot order is never rewritten or lost;
- a switch that goes wrong simply falls through to the normal order on the next
  boot;
- nothing needs undoing after a successful switch.

Concretely, on this machine:

```
bcdedit /set {fwbootmgr} bootsequence {bootmgr}      # the switch
bcdedit /deletevalue {fwbootmgr} bootsequence        # the undo
```

Two things this machine taught us, both now baked in:

**`displayorder` cannot be written.** `bcdedit /set {fwbootmgr} displayorder ...`
fails with *"The entry list data is not valid as specified."* That order is a
firmware-managed read-only mirror. `bootsequence` is the element that writes.

**`/enum {fwbootmgr}` shows no entries here.** On this laptop that object form
returns only the manager block. The entry list lives under
`bcdedit /enum firmware`, as `Firmware Application (101fffff)` blocks rather than
`Boot####` ones, with the order spread over indented continuation lines. The
parser handles both the new and the legacy shapes.

### Safety

**Every GUID is read from the live boot store, every time.** Nothing is
hardcoded. The GUID visible on the Linux side,
`8be4df61-93ca-11d2-aa0d-00e098032b8c`, is the shared UEFI vendor GUID that
appears on *every* entry — handing it to bcdedit is accepted and does nothing,
which looks exactly like a successful switch. The script refuses outright if the
entry it matched carries that GUID.

**Every change is read back before anything reboots.** After writing, the script
re-reads the boot store and confirms the override is really there. If the write
silently did nothing, it reports a verification failure and **does not reboot**.

**`-DryRun` writes and verifies but does not reboot.** Same gate as the Linux
half's `OSSWITCH_DRY_RUN=1`. Use it first.

### Install

Administrator rights are required — `bcdedit` only opens the boot store for an
elevated process.

```powershell
New-Item -ItemType Directory -Force $env:LOCALAPPDATA\osswitch
Copy-Item .\osswitch.ps1 $env:LOCALAPPDATA\osswitch\
```

Then from an **elevated** PowerShell ("Run as administrator"):

```powershell
& $env:LOCALAPPDATA\osswitch\osswitch.ps1 status
& $env:LOCALAPPDATA\osswitch\osswitch.ps1 manjaro -DryRun    # applies, verifies, stops
& $env:LOCALAPPDATA\osswitch\osswitch.ps1 manjaro             # applies, verifies, reboots
```

The script calls `exit`, so run it from a script rather than dot-sourcing it.

### Before letting Manjaro write to the Windows partition

Hibernation is currently **on**. That leaves the volume in a hibernated state,
which Linux sees as unclean. `osswitch status` prints the current state; turn it
off once with:

```powershell
powercfg /h off
```

That deletes `hiberfil.sys` and also disables Fast Startup.

### Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_osswitch.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_osswitch.ps1 -Mutants
```

63 checks run the real script in a child PowerShell against a stub `bcdedit`
(`tests/stub/`) that keeps its firmware state in a JSON file and reflects writes
back on `/enum`. That is what makes the script's own read-back verification
meaningful instead of self-confirming. **No scenario touches the real boot store
and nothing reboots.**

Covered: read-only `status`/`list`, dry run both directions, the reboot request,
the already-on-target no-op, an ambiguous target, a missing target, the
vendor-GUID trap, firmware that ignores the write, an unreadable boot store,
`restore` clearing the override, `restore` with nothing saved, a GUID never seen
before, and a replay of `tests/fixture-real-firmware-enum.txt` — genuine
`bcdedit /enum firmware` output captured from this machine, which is what caught
the two format assumptions above.

`-Mutants` then breaks the script eight ways and requires the suite to fail on
each, so a green suite means something: hardcoded GUID, verification against the
request instead of the store, no vendor guard, `-DryRun` ignored, no-op removed,
restore that never clears, writing `displayorder`, and listing with
`/enum {fwbootmgr}`. An anchor that does not match the expected number of times
is reported as `[skip]`, never as a blind check.

### Live test against this machine

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\live_test.ps1   # elevated
```

Reads the real firmware, does a dry-run switch, restores, and shows the boot
order before and after. Every switching step is `-DryRun`, so it never reboots.

### Test seams

| Seam | Why |
| --- | --- |
| `-BcdeditPath` / `-ShutdownPath` | point the script at the stubs instead of the real tools |
| `-StatePath` | keep the remembered override inside the temp scenario |
| `OSSWITCH_TEST_BYPASS_ELEVATION=1` | skips the *friendly* elevation pre-check so stub scenarios run without an admin prompt. Grants nothing: `bcdedit` still refuses an unelevated process. |

`OSSWITCH_DEBUG=1` prints the failing line when something goes wrong.
`OSSWITCH_TEST_TRACE=1` makes the suite print what each child process printed.

### Desktop shortcuts

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install_shortcuts.ps1
```

Writes two icons to the desktop (it follows the real Desktop, which on a
OneDrive-redirected profile is `C:\Users\<you>\OneDrive\Desktop`):

| Shortcut | Does |
| --- | --- |
| **Switch to Manjaro** | clears any pending override, then restarts into Manjaro |
| **Restart to Windows 11** | sets the one-shot override to Windows and restarts into it |

The Windows icon is called **Restart to** because that is exactly what it does,
and it is worth being precise: it does not make Windows permanent. The override
is one-shot, so that single boot goes to Windows and the machine returns to
Manjaro by itself on the next restart. Nothing has to be clicked to come back.

**The two icons are deliberately different, because the two jobs are different.**
Manjaro is already the first boot choice on this machine, so there is no boot
order to rearrange — that icon is `tools\boot-manjaro.ps1`, a small script that
runs none of the switching machinery. The Windows icon genuinely has to change
something, so it keeps the full launcher.

The one thing the Manjaro icon still does is delete `{fwbootmgr} bootsequence`.
That is not tidiness: if the Windows icon was used and the machine has not
restarted since, that override is still queued, and a plain restart would follow
it into **Windows** — the exact opposite of what the button promises. Hence the
single UAC prompt.

Both **ask before rebooting** with a plain Yes/No dialog, because a stray
double-click should never restart a machine with unsaved work. If the dialog
cannot be shown, it falls back to a typed `Y`/`N` question.

The window always holds long enough to read, and it never closes silently. When
the machine already boots the OS you picked, there is nothing to change in the
boot order — the shortcut says so plainly and restarts anyway, after a 15-second
countdown you can cancel with `shutdown /a`. (Not restarting there was the
original bug: it made the shortcut look like it did nothing.)

The restart is handed to a **detached** process on purpose. `shutdown.exe` with
`/t` blocks for the whole countdown and is then killed by the restart it just
scheduled, so calling it inline made the launcher die mid-call with exit code 1
and no message — again indistinguishable from "nothing happened".

### When something looks like it did nothing

The shortcut writes a breadcrumb to `%LOCALAPPDATA%\osswitch\launcher.log`
*before* PowerShell even starts, then logs every step. If the window appears and
vanishes, that file says exactly which step stopped:

```
Get-Content "$env:LOCALAPPDATA\osswitch\launcher.log" | Select-Object -Last 20
```

An empty log means the click never reached PowerShell at all — a different fault
from a crash inside the script.

Remove the shortcuts again with the same installer plus `-Remove`.

The shortcuts point into this project folder, so if you move or delete it the
icons stop working; re-run the installer after moving.

### Icons

`assets\manjaro.ico` is built from **your own** logo file, letterboxed and centred,
at 16/24/32/48/64/128/256 px. `assets\windows.ico` is the four-pane Windows mark,
drawn from geometry. Regenerate with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\make_icon.ps1 `
    -LogoPng "$env:USERPROFILE\Downloads\manjaro-os-logo.png"
```

Omit `-LogoPng` and it falls back to drawing the three-block mark from geometry and
sampling the green off the installation ISO.

The supplied logo's green is `#35BF5C` — the classic Manjaro green, and the
script prints what it actually sampled rather than trusting a hardcoded value.
(Omitting `-LogoPng` and using the 26.1 ISO instead picks up `#35BFA4`, the newer
teal branding; pass `-GreenHex '#35BFA4'` for that.)

Small frames are written as true 32bpp DIBs, not PNG-compressed ones: a
PNG-compressed 32px frame parses as coloured noise on Windows, so the icons are
verified by extracting frames back out and looking at them.

### Files (Windows half)

```
osswitch.ps1                          the Windows half: the switcher itself
tools/boot-manjaro.ps1                the Manjaro icon: clear override, restart
tools/osswitch-launch.ps1             the Windows icon: full switcher, elevated
tools/osswitch-shortcut.cmd           entry point; dispatches on the target
tools/install_shortcuts.ps1           creates / removes the desktop icons
tools/make_icon.ps1                   builds manjaro.ico and windows.ico
tests/test_osswitch.ps1               63 checks + 8 mutation checks
tests/test_launcher.ps1               36 checks on the desktop launcher
tests/live_test.ps1                   dry-run test against the real boot store
tests/probe_what_writes.ps1           what bcdedit will and will not write here
tests/fixture-real-firmware-enum.txt  real bcdedit output, replayed in the suite
tests/stub/bcd.cmd                    stub bcdedit entry point
tests/stub/bcd.ps1                    fake firmware: /enum, /set, /deletevalue
tests/stub/shutdown.cmd               stub reboot
assets/                               the icons, shared with the Linux half
```

## Files (Linux half)

```
linux/osswitch                        the Linux half: the switcher itself
linux/install.sh                      installs/removes the command and launchers
linux/osswitch-windows.desktop.in     launcher template, @HOME@ rendered on install
linux/osswitch-manjaro.desktop.in     launcher template, @HOME@ rendered on install
linux/tests/test_osswitch.sh          95 checks + 11 mutation checks
linux/tests/mutate.py                 the eleven breakages, by name
linux/tests/mutants.tsv               which scenario must catch which breakage
linux/tests/capture_fixture.py        refreshes the fixture from real hardware
linux/tests/fixture-real-efibootmgr-enum.txt  real efibootmgr output, serial blanked
linux/tests/stub/efibootmgr           fake firmware: BootNext, -N, ignores-write modes
linux/tests/stub/systemctl            stub reboot
linux/tests/stub/pkexec               stub escalation, wipes the environment
linux/tests/stub/zenity, stub/yad     stub dialogs
```