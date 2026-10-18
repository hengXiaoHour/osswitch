# osswitch — Windows half

One command to pick which OS this laptop boots next: **Windows 11** or **Manjaro**.

The Linux half lives at `~/.local/bin/osswitch` on the Manjaro partition. Together
they remove the "reboot, then mash F12 and hope" step from switching between the
two systems.

```
osswitch status      # what will boot next, and is anything unsafe
osswitch manjaro     # boot Manjaro next time
osswitch windows     # boot Windows 11 next time
osswitch restore     # cancel a pending switch and go back to the usual order
```

## How it works

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

## Safety

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

## Install

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

## Before letting Manjaro write to the Windows partition

Hibernation is currently **on**. That leaves the volume in a hibernated state,
which Linux sees as unclean. `osswitch status` prints the current state; turn it
off once with:

```powershell
powercfg /h off
```

That deletes `hiberfil.sys` and also disables Fast Startup.

## Tests

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

## Test seams

| Seam | Why |
| --- | --- |
| `-BcdeditPath` / `-ShutdownPath` | point the script at the stubs instead of the real tools |
| `-StatePath` | keep the remembered override inside the temp scenario |
| `OSSWITCH_TEST_BYPASS_ELEVATION=1` | skips the *friendly* elevation pre-check so stub scenarios run without an admin prompt. Grants nothing: `bcdedit` still refuses an unelevated process. |

`OSSWITCH_DEBUG=1` prints the failing line when something goes wrong.
`OSSWITCH_TEST_TRACE=1` makes the suite print what each child process printed.

## Desktop shortcuts

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

## Files

```
osswitch.ps1                        the boot-order switcher itself
tools/boot-manjaro.ps1              the Manjaro icon: clear override, restart
tools/osswitch-launch.ps1           the Windows icon: full switcher, elevated
tools/osswitch-shortcut.cmd         entry point; dispatches on the target
tools/install_shortcuts.ps1         creates / removes the desktop icons
tools/make_icon.ps1                 builds manjaro.ico and windows.ico
tests/test_osswitch.ps1             63 checks + 8 mutation checks
tests/test_launcher.ps1             36 checks on the desktop launcher
tests/live_test.ps1                 dry-run test against the real boot store
tests/probe_what_writes.ps1         what bcdedit will and will not write here
tests/fixture-real-firmware-enum.txt  real bcdedit output, replayed in the suite
tests/stub/bcd.cmd                  stub bcdedit entry point
tests/stub/bcd.ps1                  fake firmware: /enum, /set, /deletevalue
tests/stub/shutdown.cmd             stub reboot
assets/                             the icons
```