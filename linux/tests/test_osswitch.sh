#!/usr/bin/env bash
# test_osswitch.sh - drive the real linux/osswitch against a stub firmware.
#
# Nothing here can reboot anything: efibootmgr is a stub holding fake boot
# variables in a temp file, systemctl is a stub that writes to a log, and every
# switching scenario runs with --dry-run so even the reboot line is never
# reached. The point is that the suite proves it - see the harness self-test
# below - rather than asking you to trust it.
#
#   ./test_osswitch.sh              run the checks
#   ./test_osswitch.sh -Mutants     additionally break the script eight ways and
#                                   require the suite to catch every one
#
# Exits non-zero if anything fails.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LINUX_DIR=$(dirname "$HERE")
SRC="$LINUX_DIR/osswitch"
STUBS="$HERE/stub"
FIXTURE="$HERE/fixture-real-efibootmgr-enum.txt"
MUTATE="$HERE/mutate.py"

MUTANTS=0
case "${1:-}" in
  -Mutants|--mutants) MUTANTS=1 ;;
  "") ;;
  *) echo "usage: $0 [-Mutants]" >&2; exit 2 ;;
esac

CHECKS=0
FAILED=0
CASE_DIR=""
OUT=""
RC=0
declare -a EXTRA_ENV=()
OSSWITCH_UNDER_TEST="$SRC"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_dim=""; c_off=""; }

# ---------------------------------------------------------------- assertions
a() { # a <ok?> <description> [detail]
  CHECKS=$((CHECKS + 1))
  if [[ $1 -eq 0 ]]; then
    printf '    %sok%s   %s\n' "$c_grn" "$c_off" "$2"
  else
    FAILED=$((FAILED + 1))
    printf '    %sFAIL%s %s\n' "$c_red" "$c_off" "$2"
    [[ -n ${3:-} ]] && printf '         %s\n' "$3"
  fi
  return 0   # always: callers use `cond && a 0 .. || a 1 ..`
}
a_rc()        { local want=$1 d=$2; [[ $RC -eq $want ]] && a 0 "$d" || a 1 "$d" "exit $RC, wanted $want"; }
a_rc_ne()     { local d=$1;        [[ $RC -ne 0 ]]       && a 0 "$d" || a 1 "$d" "exit 0, wanted failure"; }
a_has()       { local s=$1 d=$2;   [[ $OUT == *"$s"* ]] && a 0 "$d" || a 1 "$d" "no '$s' in: $(printf '%s' "$OUT" | head -3 | tr '\n' '|')"; }
a_lacks()     { local s=$1 d=$2;   [[ $OUT != *"$s"* ]] && a 0 "$d" || a 1 "$d" "unexpected '$s' in output"; }
a_reboots()   { local n=$1 d=$2 got=0; [[ -s $OSSWITCH_STUB_REBOOT_LOG ]] && got=$(wc -l <"$OSSWITCH_STUB_REBOOT_LOG"); [[ $got -eq $n ]] && a 0 "$d" || a 1 "$d" "$got reboot requests, wanted $n"; }
a_bootnext()  { local want=$1 d=$2 got; got=$(sed -n 's/.*"bootnext":"\([^"]*\)".*/\1/p' "$OSSWITCH_STUB_STATE" 2>/dev/null); [[ $got == "$want" ]] && a 0 "$d" || a 1 "$d" "BootNext='${got:-<unset>}', wanted '$want'"; }
a_called()    { local want=$1 d=$2; grep -qF -- "$want" "$OSSWITCH_STUB_LOG" && a 0 "$d" || a 1 "$d" "stub was never called with '$want'"; }
a_not_called(){ local bad=$1 d=$2; ! grep -qF -- "$bad" "$OSSWITCH_STUB_LOG" && a 0 "$d" || a 1 "$d" "stub was called with '$bad'"; }
a_file_has()  { local f=$1 s=$2 d=$3; grep -qF -- "$s" "$f" 2>/dev/null && a 0 "$d" || a 1 "$d" "'$s' not in $f"; }
a_file_lacks(){ local f=$1 s=$2 d=$3; ! grep -qF -- "$s" "$f" 2>/dev/null && a 0 "$d" || a 1 "$d" "unexpected '$s' in $f"; }
a_file_empty(){ local f=$1 d=$2; [[ ! -s $f ]] && a 0 "$d" || a 1 "$d" "$f is not empty: $(tr '\n' '|' <"$f" | head -c 120)"; }
a_file_gone() { local f=$1 d=$2; [[ ! -e $f ]] && a 0 "$d" || a 1 "$d" "$f was left behind"; }
a_file_lines(){ local n=$1 f=$2 d=$3 got; got=$(wc -l <"$f" 2>/dev/null || echo -1); [[ $got -eq $n ]] && a 0 "$d" || a 1 "$d" "$got lines in $f, wanted $n"; }

# ------------------------------------------------------------------- harness
BASE_PATH="$PATH"
GUI_TOOL=zenity

new_case() { # new_case [zenity|yad] - which dialog tool exists in this case
  GUI_TOOL=${1:-zenity}
  CASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/osswitch-test.XXXXXX")
  export OSSWITCH_STUB_STATE="$CASE_DIR/firmware.json"
  export OSSWITCH_STUB_LOG="$CASE_DIR/efibootmgr.calls"
  export OSSWITCH_STUB_REBOOT_LOG="$CASE_DIR/reboot.calls"
  export OSSWITCH_STUB_DIALOG_LOG="$CASE_DIR/zenity.calls"
  : >"$OSSWITCH_STUB_LOG"; : >"$OSSWITCH_STUB_REBOOT_LOG"; : >"$OSSWITCH_STUB_DIALOG_LOG"; : >"$CASE_DIR/case.env"

  # Each stub is reached through a wrapper that bakes in this case's paths,
  # because a scenario that escalates runs the stubs in a process whose
  # environment pkexec wiped - exactly the production situation. A stub that
  # could only find its state file through the environment would quietly test
  # nothing there.
  mkdir -p "$CASE_DIR/bin"
  for s in efibootmgr systemctl zenity yad pkexec; do
    cat >"$CASE_DIR/bin/$s" <<EOF
#!/usr/bin/env bash
set -a; . "$CASE_DIR/case.env"; set +a
exec "$STUBS/$s" "\$@"
EOF
    chmod +x "$CASE_DIR/bin/$s"
  done

  # Only the one dialog tool this case declares is reachable, so the fallback
  # cannot pass by accident and a test can assert which tool was used. It is a
  # wrapper rather than a symlink for the same reason as the rest: a dialog
  # raised inside the escalated process has to land in THIS case's log, not in
  # a shared default one, or "asked exactly once" quietly becomes "asked once
  # here and once wherever the child happened to write".
  rm -f "$CASE_DIR/bin/zenity" "$CASE_DIR/bin/yad"
  cat >"$CASE_DIR/bin/$GUI_TOOL" <<EOF
#!/usr/bin/env bash
set -a; . "$CASE_DIR/case.env"; set +a
exec "$STUBS/$GUI_TOOL" "\$@"
EOF
  chmod +x "$CASE_DIR/bin/$GUI_TOOL"

  export OSSWITCH_TEST_ASSUME_ROOT=1
  export PATH="$CASE_DIR/bin:$BASE_PATH"
  unset OSSWITCH_STUB_ENTRIES OSSWITCH_STUB_IGNORES_WRITE OSSWITCH_STUB_FAIL_DELETE
  unset OSSWITCH_STUB_PKEXEC_RC OSSWITCH_ERRFILE OSSWITCH_DRY_RUN
  EXTRA_ENV=()
  seed_firmware ""
}

# Snapshot the stub knobs into the wrapper's env file, so whatever the scenario
# set is what the stubs see - including in the escalated process.
write_case_env() {
  : >"$CASE_DIR/case.env"
  local v
  for v in OSSWITCH_STUB_STATE OSSWITCH_STUB_LOG OSSWITCH_STUB_REBOOT_LOG \
           OSSWITCH_STUB_DIALOG_LOG OSSWITCH_STUB_ENTRIES OSSWITCH_STUB_IGNORES_WRITE \
           OSSWITCH_STUB_FAIL_DELETE OSSWITCH_STUB_PKEXEC_RC OSSWITCH_ERRFILE \
           OSSWITCH_STUB_DIALOG_RC OSSWITCH_DRY_RUN; do
    [[ -n ${!v:-} ]] && printf '%s=%q\n' "$v" "${!v}" >>"$CASE_DIR/case.env"
  done
  # EXTRA_ENV already holds NAME=value strings, so they are written verbatim.
  (( ${#EXTRA_ENV[@]} > 0 )) && printf '%s\n' "${EXTRA_ENV[@]}" >>"$CASE_DIR/case.env"
  return 0
}

seed_firmware() {
  printf '{"bootorder":"0003,0004,0000,0001","bootnext":"%s"}\n' "$1" >"$OSSWITCH_STUB_STATE"
}

# The script is always pointed at the stubs through ARGV, never through the
# environment: that is what a real pkexec does to the environment, so the suite
# exercises the same path the desktop button does.
run() {
  write_case_env
  OUT=$(env ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$OSSWITCH_UNDER_TEST" \
        --efibootmgr "$CASE_DIR/bin/efibootmgr" --systemctl "$CASE_DIR/bin/systemctl" "$@" 2>&1)
  RC=$?
}

cleanup() { [[ -n $CASE_DIR && -d $CASE_DIR ]] && rm -rf "$CASE_DIR"; }
trap cleanup EXIT

# ----------------------------------------------------------------- scenarios
sc_status_clean() {
  new_case; run status
  a_rc 0 "status exits 0"
  a_has "One-time target   : (none" "status says no one-time boot is pending"
  a_has "Normal boot order : 0003,0004,0000,0001" "status shows the firmware boot order"
  a_has "Boot0003* Manjaro" "status lists Manjaro in full (sed [^\t] would truncate it to 'Manjar')"
  a_has "Boot0004* Windows Boot Manager" "status lists the Windows entry"
  a_lacks "dp:" "status does not leak efibootmgr's hex continuation lines"
}

sc_status_pending() {
  new_case; seed_firmware 0004; run status
  a_rc 0 "status with a pending override exits 0"
  a_has "One-time target   : 0004  (Windows Boot Manager)" "pending override is named, not just numbered"
}

sc_list() {
  new_case; run list
  a_rc 0 "list exits 0"
  a_has "Boot0000* UEFI PM9A1 NVMe Samsung" "list shows every entry"
  a_has "Manjaro" "list shows Manjaro"
  a_lacks "BootOrder" "list is entries only"
  a_lacks "dp:" "list skips the hex noise"
}

sc_dry_run_windows() {
  new_case; run windows --dry-run
  a_rc 0 "windows --dry-run exits 0"
  a_bootnext 0004 "BootNext is set to the Windows entry"
  a_reboots 0 "nothing rebooted"
  a_has "DRY RUN" "the dry run says so out loud"
  a_has "Windows Boot Manager (0004)" "the resolved entry is named with its id"
}

sc_dry_run_manjaro() {
  new_case; run manjaro --dry-run
  a_rc 0 "manjaro --dry-run exits 0"
  a_bootnext 0003 "BootNext is set to the Manjaro entry"
  a_reboots 0 "nothing rebooted"
}

sc_dry_run_env_gate() {
  new_case; EXTRA_ENV=(OSSWITCH_DRY_RUN=1); run windows
  a_rc 0 "OSSWITCH_DRY_RUN=1 exits 0"
  a_bootnext 0004 "OSSWITCH_DRY_RUN=1 still applies the change"
  a_reboots 0 "OSSWITCH_DRY_RUN=1 still does not reboot"
}

sc_write_refused() {
  new_case; OSSWITCH_STUB_IGNORES_WRITE=1 run windows --dry-run
  a_rc_ne "firmware that ignores the write is an error"
  a_has "refused" "the error says the firmware refused"
  a_reboots 0 "nothing rebooted after a refused write"
}

sc_restore() {
  new_case; seed_firmware 0004; run restore
  a_rc 0 "restore exits 0"
  a_bootnext "" "restore clears BootNext"
  a_called "-N" "restore used efibootmgr -N / --delete-bootnext"
  a_not_called " -b" "restore did NOT use -b (that is --bootnum, the original bug)"
  a_reboots 0 "restore never reboots"
}

sc_restore_alias() {
  new_case; seed_firmware 0004; run cancel
  a_rc 0 "cancel is still accepted as an alias for restore"
  a_bootnext "" "cancel clears BootNext too"
}

sc_restore_nothing_pending() {
  new_case; run restore
  a_rc 0 "restore with nothing pending is not an error"
  a_bootnext "" "BootNext stays unset"
}

sc_restore_refused() {
  new_case; seed_firmware 0004; OSSWITCH_STUB_FAIL_DELETE=1 run restore
  a_rc_ne "a restore the firmware ignores is an error"
  a_has "still reports" "the error says the override survived"
  a_lacks "cleared" "no false success message"
}

sc_missing_entry() {
  new_case
  printf 'BootOrder: 0000\nBoot0000* Something Else\tHD(1,GPT,0,0,0)/x.efi\n' >"$CASE_DIR/entries.txt"
  export OSSWITCH_STUB_ENTRIES="$CASE_DIR/entries.txt"
  run manjaro --dry-run
  a_rc_ne "switching to a target that is not in the firmware fails"
  a_has "no UEFI boot entry matching 'Manjaro'" "the error names what it looked for"
  a_has "osswitch list" "the error says how to look"
  a_bootnext "" "no fallback entry was booted instead"
  a_reboots 0 "nothing rebooted"
}

sc_real_fixture() {
  new_case; export OSSWITCH_STUB_ENTRIES="$FIXTURE"
  run windows --dry-run
  a_rc 0 "real captured efibootmgr output parses (windows)"
  a_bootnext 0004 "real output resolves to the Windows entry"

  run manjaro --dry-run
  a_rc 0 "real captured efibootmgr output parses (manjaro)"
  a_bootnext 0003 "real output resolves to the Manjaro entry"

  run status
  a_has "UEFI PM9A1 NVMe Samsung" "real output: the disk entry parses"
  a_has "Manjaro" "real output: Manjaro survives parsing in full"
  a_lacks "dp:" "real output: hex noise is ignored"
}

sc_already_pending() {
  new_case; seed_firmware 0004; run windows --dry-run
  a_rc 0 "switching to what is already queued is not an error"
  a_has "already the one-time target" "it says the change is a no-op"
  a_bootnext 0004 "BootNext is unchanged"
  a_reboots 0 "nothing rebooted"
}

sc_bad_input() {
  new_case; run bogus
  a_rc_ne "an unknown command fails"
  a_has "unknown command" "and says so"

  run windows --bogus
  a_rc_ne "an unknown option fails"
  a_lacks "not rebooting" "an unknown option never reaches the reboot"
  a_reboots 0 "nothing rebooted"
}

sc_help() {
  new_case; run --help
  a_rc 0 "--help exits 0"
  a_has "osswitch restore" "help documents restore"
  a_has "--dry-run" "help documents the dry run"
}

# --- escalation: everything below goes through the stub pkexec, which wipes the
# environment the way real polkit does and then runs us as "root".
sc_escalated_dry_run() {
  new_case; unset OSSWITCH_TEST_ASSUME_ROOT; EXTRA_ENV=(); run windows --gui --dry-run
  a_rc 0 "a --dry-run survives pkexec's environment wipe and exits 0"
  a_bootnext 0004 "the switch was applied through the escalation"
  a_reboots 0 "and it still did not reboot - argv flags, not env vars"
  a_file_lacks "$OSSWITCH_STUB_DIALOG_LOG" "--error" "no error dialog for a clean run"
  a_file_has "$OSSWITCH_STUB_DIALOG_LOG" "--question" "the confirmation survived the wipe too"
  a_file_lines 1 "$OSSWITCH_STUB_DIALOG_LOG" "and it was asked exactly once, not again after escalating"
}

sc_escalated_real_switch() {
  new_case; unset OSSWITCH_TEST_ASSUME_ROOT; EXTRA_ENV=(); run windows
  a_rc 0 "an undry-run switch escalates and exits 0"
  a_reboots 1 "and this time it reboots exactly once"
}

sc_escalation_denied() {
  new_case; unset OSSWITCH_TEST_ASSUME_ROOT; EXTRA_ENV=(OSSWITCH_STUB_PKEXEC_RC=126); run windows --dry-run
  a_rc_ne "a dismissed password prompt is an error, not a silent no-op"
  a_has "privilege escalation failed" "the error explains what happened"
  a_has "sudo" "and offers a terminal alternative"
  a_reboots 0 "nothing rebooted"
}

# --- GUI: launched from a desktop launcher, where a failure that prints nothing
# is indistinguishable from a broken button, and a double-click should never be
# enough to restart a machine.
sc_gui_asks_before_reboot() {
  new_case; run windows --gui
  a_rc 0 "the launcher switch succeeds"
  a_file_has "$OSSWITCH_STUB_DIALOG_LOG" "--question" "it asks before rebooting"
  a_file_has "$OSSWITCH_STUB_DIALOG_LOG" "Windows Boot Manager" "the question names where it is going"
  a_reboots 1 "and reboots once the question is answered"
}

# Neither dialog tool is installed by default on every GNOME box, so the script
# takes whichever one is there.
sc_gui_yad_fallback() {
  new_case yad; run windows --gui
  a_rc 0 "the switch works with yad instead of zenity"
  a_file_has "$OSSWITCH_STUB_DIALOG_LOG" "--button" "yad is asked with its own button syntax"
  a_reboots 1 "and reboots once answered"
}

sc_gui_cancelled() {
  new_case; OSSWITCH_STUB_DIALOG_RC=1 run windows --gui
  a_rc 0 "answering No is not an error"
  a_bootnext "" "and nothing was written to the firmware"
  a_reboots 0 "and nothing rebooted"
  a_lacks "failed" "no error dialog is thrown at someone who simply cancelled"
}

sc_gui_dialog_on_failure() {
  new_case; OSSWITCH_STUB_IGNORES_WRITE=1 run windows --gui --dry-run
  a_rc_ne "the switch fails"
  a_file_has "$OSSWITCH_STUB_DIALOG_LOG" "refused" "a dialog shows the real reason"
  a_file_empty "$OSSWITCH_STUB_REBOOT_LOG" "and nothing rebooted"
}

sc_gui_error_file_cleaned() {
  new_case; OSSWITCH_STUB_IGNORES_WRITE=1 OSSWITCH_ERRFILE="$CASE_DIR/err.txt" run windows --gui --dry-run
  a_file_gone "$CASE_DIR/err.txt" "the temporary error file is cleaned up"
}

# --- the suite itself. A harness that reports "nothing happened" must be able to
# tell the difference between "nothing happened" and "I was not looking".
sc_harness_self_test() {
  new_case; run status
  a_rc 0 "harness can run the script"
  a_file_has "$OSSWITCH_STUB_LOG" "-v" "harness can see that the firmware stub was actually invoked"
  a_reboots 0 "harness knows a reboot did not happen"
  EXTRA_ENV=(); run windows --dry-run
  a_file_has "$OSSWITCH_STUB_LOG" "-n 0004" "harness can see a firmware write"
  # And it must be capable of failing: break the script on purpose and require
  # the check above to notice.
  local broken="$CASE_DIR/broken"
  sed 's/^main "\$@"$/exit 42/' "$SRC" >"$broken"; chmod +x "$broken"
  local saved=$OSSWITCH_UNDER_TEST
  OSSWITCH_UNDER_TEST="$broken"; run status; OSSWITCH_UNDER_TEST="$saved"
  a_rc_ne "harness can see a failing script (not just a passing one)"
  rm -f "$broken"
}

ALL_SCENARIOS=(
  sc_status_clean sc_status_pending sc_list
  sc_dry_run_windows sc_dry_run_manjaro sc_dry_run_env_gate
  sc_write_refused
  sc_restore sc_restore_alias sc_restore_nothing_pending sc_restore_refused
  sc_missing_entry sc_real_fixture sc_already_pending
  sc_bad_input sc_help
  sc_escalated_dry_run sc_escalated_real_switch sc_escalation_denied
  sc_gui_dialog_on_failure sc_gui_error_file_cleaned
  sc_gui_asks_before_reboot sc_gui_cancelled sc_gui_yad_fallback
  sc_harness_self_test
)

# --------------------------------------------------------------------- runner
run_scenario() {
  local fn=$1
  FAILED=0
  printf '  %s\n' "${fn#sc_}"
  "$fn"
  return $FAILED
}

section() { printf '\n%s\n' "$1"; }
trim() { local v=${1-}; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf '%s' "$v"; }

if [[ ! -x $SRC ]]; then
  printf 'osswitch is not executable: %s\n' "$SRC" >&2
  exit 2
fi
if [[ ! -r $FIXTURE ]]; then
  printf 'missing fixture: %s\n' "$FIXTURE" >&2
  exit 2
fi

printf 'osswitch linux suite  %sscript%s %s\n' "$c_dim" "$c_off" "$SRC"
section "checks"
BEFORE=$CHECKS
SUITE_FAILED=0
for sc in "${ALL_SCENARIOS[@]}"; do
  run_scenario "$sc" || SUITE_FAILED=$((SUITE_FAILED + 1))
done
SCENARIO_CHECKS=$((CHECKS - BEFORE))
printf '\n%d checks in %d scenarios, %d failed\n' "$SCENARIO_CHECKS" "${#ALL_SCENARIOS[@]}" "$SUITE_FAILED"

# A suite that ran nothing is not a passing suite. This fired for real during
# development, when a broken loop made every scenario a no-op and the runner
# cheerfully reported "0 checks, 0 failed".
if (( SCENARIO_CHECKS < 40 )); then
  printf '\n%sFAILED%s only %d checks ran - the suite is not doing its job.\n' \
    "$c_red" "$c_off" "$SCENARIO_CHECKS"
  exit 1
fi

MUTANT_FAILED=0
MUTANT_SKIPPED=0
if (( MUTANTS )); then
  section "mutants (each must break a scenario above)"
  while IFS='|' read -r raw_id raw_desc raw_scenario; do
    id=$(trim "$raw_id"); desc=$(trim "$raw_desc"); scenario=$(trim "$raw_scenario")
    [[ -n $id ]] || continue
    case "$id" in \#*) continue ;; esac
    mutated=$(mktemp "${TMPDIR:-/tmp}/osswitch-mutant.XXXXXX")
    chmod +x "$mutated"
    if ! err=$(python3 "$MUTATE" "$SRC" "$mutated" "$id" 2>&1); then
      printf '  %sskip%s  %-22s %s\n' "$c_dim" "$c_off" "$id" "$(trim "$err")"
      MUTANT_SKIPPED=$((MUTANT_SKIPPED + 1))
      rm -f "$mutated"; continue
    fi
    saved=$OSSWITCH_UNDER_TEST
    OSSWITCH_UNDER_TEST="$mutated"
    printf '  %s\n' "$id - $desc"
    run_scenario "$scenario" >/dev/null 2>&1
    caught=$?
    OSSWITCH_UNDER_TEST="$saved"
    rm -f "$mutated"
    if (( caught > 0 )); then
      printf '    %sok%s   caught by %s\n' "$c_grn" "$c_off" "${scenario#sc_}"
    else
      printf '    %sFAIL%s %s survived %s - the suite is not proving anything here\n' \
        "$c_red" "$c_off" "$id" "${scenario#sc_}"
      MUTANT_FAILED=$((MUTANT_FAILED + 1))
    fi
  done <"$HERE/mutants.tsv"
  printf '\n%d mutant(s), %d survived, %d skipped\n' \
    "$(grep -cvE '^\s*(#|$)' "$HERE/mutants.tsv")" "$MUTANT_FAILED" "$MUTANT_SKIPPED"
fi

if (( SUITE_FAILED > 0 || MUTANT_FAILED > 0 )); then
  printf '\n%sFAILED%s\n' "$c_red" "$c_off"
  exit 1
fi
printf '\n%sPASS%s  %d checks, nothing rebooted.\n' "$c_grn" "$c_off" "$SCENARIO_CHECKS"
