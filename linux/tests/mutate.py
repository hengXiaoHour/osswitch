#!/usr/bin/env python3
"""Apply one named mutation to the osswitch script, for the -Mutants run.

    usage: mutate.py <source> <output> <mutant-id>

An anchor that is not found exactly the expected number of times is a hard
error, never a silent pass: if the script is refactored past a mutant's anchor,
that mutant stops being tested, and the suite would go on claiming coverage it
does not have. The runner reports it as [skip] instead.

Exit 0 = mutated file written. Exit 3 = anchor mismatch (skip). Exit 1 = other.
"""

from __future__ import annotations

import sys
from pathlib import Path

# id -> list of (old, new, expected_occurrences)
MUTANTS: dict[str, list[tuple[str, str, int]]] = {
    # The switch stops checking that the firmware accepted the write.
    "no-verify": [(
        '[[ $nxt == "$id" ]] || die "firmware refused',
        'true || die "firmware refused',
        1,
    )],
    # ... and checks something that was true before the write instead.
    "verify-stale": [(
        "    local nxt; nxt=$(bootnext_id)\n"
        '    [[ $nxt == "$id" ]] || die "firmware refused',

        "    local nxt; nxt=pending_before\n"
        '    [[ $nxt == "$id" ]] || die "firmware refused',
        1,
    ), (
        '  desc=$(describe_entry "$id")',
        '  pending_before=$(bootnext_id)\n  desc=$(describe_entry "$id")',
        1,
    )],
    # The dry-run gate stops existing.
    "dry-run-ignored": [(
        'if [[ $DRY_RUN == 1 ]]; then',
        'if false; then',
        1,
    )],
    # restore goes back to -b, which is --bootnum, not --delete-bootnext.
    "restore-wrong-flag": [(
        '"$EFIBOOTMGR" -N || die "efibootmgr could not delete BootNext"',
        '"$EFIBOOTMGR" -b || die "efibootmgr could not delete BootNext"',
        1,
    )],
    # restore stops verifying that the delete took effect.
    "restore-no-verify": [(
        '  if [[ -n $(bootnext_id) ]]; then\n'
        '    die "firmware still reports a one-time boot target after deleting it"\n'
        '  fi\n',
        '  :\n',
        1,
    )],
    # A target that is not in the firmware silently falls back to some entry.
    "resolve-fallback": [(
        '[[ -n $out ]] || die "no UEFI boot entry matching \'$1\'. Run: osswitch list"',
        "[[ -n $out ]] || out=$(printf '0004\\tfallback entry')",
        1,
    )],
    # The parser goes back to splitting the line into fields.
    "parser-field-split": [(
        '      desc = rest\n'
        '      if (index(desc, "\\t") > 0) desc = substr(desc, 1, index(desc, "\\t") - 1)\n',
        '      desc = $2\n',
        3,
    )],
    # The GUI error dialog disappears: the failure is silent again.
    "gui-dialog-removed": [(
        'zenity --error --title="osswitch"',
        ': #',
        1,
    )],
    # The launcher stops asking before rebooting.
    "gui-no-confirm": [(
        '    confirm_reboot "$desc"',
        "    :",
        1,
    )],
    # The escalated process forgets it was already asked, and asks again.
    "gui-confirms-twice": [(
        "    ESCALATE_ARGS+=(--confirmed)",
        "    :",
        1,
    )],
    # Escalation forwards only the first argument, so --dry-run and --gui are
    # dropped on the way to root (pkexec strips the environment that used to
    # carry them).
    "escalate-drops-flags": [(
        '    pkexec "$0" "$@" || rc=$?',
        '    pkexec "$0" "$1" || rc=$?',
        1,
    )],
}


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 1
    src, dst, mutant = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    edits = MUTANTS.get(mutant)
    if edits is None:
        print(f"unknown mutant {mutant!r}: have {', '.join(sorted(MUTANTS))}", file=sys.stderr)
        return 1

    text = src.read_text()
    for old, new, expected in edits:
        found = text.count(old)
        if found != expected:
            print(f"anchor matched {found}x, expected {expected}x: {old.splitlines()[0][:60]!r}",
                  file=sys.stderr)
            return 3
        text = text.replace(old, new)

    dst.write_text(text)
    dst.chmod(0o755)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
