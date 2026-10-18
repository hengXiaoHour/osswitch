#!/usr/bin/env python3
"""Capture `efibootmgr -v` into tests/fixture-real-efibootmgr-enum.txt.

The fixture is committed, so the suite never needs this - it is here so the
fixture can be refreshed honestly, from real hardware, rather than being edited
by hand until it looks like what we hoped efibootmgr prints.

One thing is redacted: the disk serial number, which efibootmgr prints in the
entry description and which identifies the machine. It is blanked to the same
length so every field stays byte-aligned and the file still looks like real
firmware output rather than a tidied-up version of it.

The GUIDs are left intact on purpose. They are randomly generated at install
time, identify no hardware, and keeping the real ones is what makes this a
fixture rather than a sketch - the partition GUID appears inside the hex device
paths too, and a hand-written stand-in would not exercise the same parsing.

    usage: capture_fixture.py [output-path]
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SERIAL = "S6H3NF0X239580"


def utf16_hex(s: str) -> str:
    return " ".join(f"{b:02x}" for b in s.encode("utf-16-le"))


def main() -> int:
    dest = Path(sys.argv[1] if len(sys.argv) > 1
                else Path(__file__).with_name("fixture-real-efibootmgr-enum.txt"))
    text = subprocess.run(["efibootmgr", "-v"], check=True, capture_output=True,
                          text=True).stdout

    if "Boot0000" not in text:
        print("refusing to write: efibootmgr -v did not look like an entry dump",
              file=sys.stderr)
        return 1

    blank = "X" * len(SERIAL)
    for needle in (SERIAL, utf16_hex(SERIAL)):
        if needle not in text:
            print(f"note: {needle[:16]!r} not found in the output - if efibootmgr "
                  f"has started printing the serial somewhere new, add a redaction "
                  f"for it here", file=sys.stderr)
        text = text.replace(needle, blank if needle == SERIAL else " " * len(needle))

    if SERIAL in text or utf16_hex(SERIAL) in text:
        print("refusing to write: the disk serial survived redaction", file=sys.stderr)
        return 1

    dest.write_text(
        "# Real `efibootmgr -v` from this machine (Alienware x14 R2), captured by\n"
        "# tests/capture_fixture.py with the disk serial blanked. Structure, field\n"
        "# order, GUIDs and hex noise are untouched - the parser has to survive\n"
        "# exactly this, not a tidy version of it.\n" + text)
    print(f"wrote {dest} ({len(text.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
