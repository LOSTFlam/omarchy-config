#!/bin/bash
# Shape and safety tests for the update scan and the boundary it runs behind.
#
# These run against the real system, read-only. They assert the contract the
# QML panel depends on: always valid JSON, always exit 0, always under the byte
# and row caps that keep a runaway process from growing the shell. They also
# assert the runtime boundary itself, because every property of it, the process
# group, the deadline, the cap and the private database, is invisible in the
# output and would rot without something exercising it.
#
# Model.js has its own suite next door; this file runs it too, so one command
# covers the producer and the intake that re-caps what it produces.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCAN=./bin/omarchy-update-scan
pass=0
fail=0

ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

echo "omarchy-update-scan"

# --- contract --------------------------------------------------------------

out=$("$SCAN" --nosync --no-aur)
rc=$?

check "exits 0 even when it has nothing good to say" "(( rc == 0 ))"
check "emits valid JSON" "jq -e . >/dev/null 2>&1 <<<\"\$out\""
check "carries every key the panel reads" \
  "jq -e 'has(\"ok\") and has(\"error\") and has(\"omarchy\") and has(\"packages\") and has(\"aur\") and has(\"dev\") and has(\"totalBytes\") and has(\"restartCount\") and has(\"counts\") and has(\"omitted\")' >/dev/null <<<\"\$out\""
check "counts and omitted are complete, so the panel never reads undefined" \
  "jq -e '(.counts | has(\"packages\") and has(\"aur\") and has(\"dev\")) and (.omitted | has(\"packages\") and has(\"aur\") and has(\"dev\"))' >/dev/null <<<\"\$out\""

if jq -e '.ok' >/dev/null <<<"$out"; then
  check "every package has a name and both versions" \
    "jq -e '(.packages | map(select((.name | length) > 0 and (.from | length) > 0 and (.to | length) > 0)) | length) == (.packages | length)' >/dev/null <<<\"\$out\""
  check "every tag is one the panel knows how to render" \
    "jq -e '(.packages | map(select(.tag == \"\" or .tag == \"reboot\" or .tag == \"restart\")) | length) == (.packages | length)' >/dev/null <<<\"\$out\""
  check "no package byte count is negative" \
    "jq -e '[.packages[] | select(.bytes < 0)] | length == 0' >/dev/null <<<\"\$out\""
  check "totalBytes covers at least the package list" \
    "jq -e '.totalBytes >= ([.packages[].bytes] | add // 0)' >/dev/null <<<\"\$out\""
  check "restartCount matches the tagged rows" \
    "jq -e '.restartCount == ([.packages[] | select(.tag != \"\")] | length)' >/dev/null <<<\"\$out\""
  check "omarchy is lifted out of the package list, not duplicated" \
    "jq -e '[.packages[] | select(.name == \"omarchy\" or .name == \"omarchy-dev\")] | length == 0' >/dev/null <<<\"\$out\""
  check "counts never claim fewer rows than were printed" \
    "jq -e '.counts.packages >= (.packages | length) and .counts.aur >= (.aur | length)' >/dev/null <<<\"\$out\""
  check "nothing is omitted when nothing was cut" \
    "jq -e '.omitted.packages == (.counts.packages - (.packages | length)) and .omitted.aur == (.counts.aur - (.aur | length))' >/dev/null <<<\"\$out\""
else
  check "a failure still reads as a sentence to a person" \
    "jq -e '(.error | length) > 10 and (.error | endswith(\".\"))' >/dev/null <<<\"\$out\""
fi

# --- the byte cap ----------------------------------------------------------
#
# StdioCollector has no size limit, so this cap is the only thing standing
# between a runaway process and the shell's memory. Prove it fires, and that
# it fires as a readable error rather than as truncated JSON.

tiny=$(OMARCHY_UPDATE_SCAN_MAX_OUTPUT=64 "$SCAN" --nosync --no-aur)
check "output cap produces valid JSON, not a truncated document" \
  "jq -e . >/dev/null 2>&1 <<<\"\$tiny\""
check "output cap reports failure rather than a short list" \
  "jq -e '.ok == false and (.error | length) > 10' >/dev/null <<<\"\$tiny\""

tinylist=$(OMARCHY_UPDATE_SCAN_MAX_LIST=64 "$SCAN" --nosync --no-aur)
check "input cap produces valid JSON" "jq -e . >/dev/null 2>&1 <<<\"\$tinylist\""

# --- the row cap -----------------------------------------------------------
#
# Every row printed here becomes a Repeater delegate in the persistent shell,
# so cardinality is capped as well as bytes. Proven against a stub checkupdates
# rather than against whatever this machine happens to have pending, so the
# assertions below are the same on every machine.

stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT
{
  echo '#!/bin/bash'
  # A kernel, deliberately last in name order, to prove the cap cannot drop it.
  echo 'for i in $(seq 1 400); do echo "pkg$i 1.0 -> 2.0"; done'
  echo 'echo "linux 6.1 -> 6.2"'
} >"$stub/checkupdates"
chmod +x "$stub/checkupdates"

big=$(PATH="$stub:$PATH" "$SCAN" --nosync --no-aur)

check "a huge pending list is still valid JSON" "jq -e . >/dev/null 2>&1 <<<\"\$big\""
check "rows are capped at 250, whatever checkupdates says" \
  "jq -e '(.packages | length) == 250' >/dev/null <<<\"\$big\""
check "the count is the whole update, not the part that fits" \
  "jq -e '.counts.packages == 401' >/dev/null <<<\"\$big\""
check "it says how many rows it is not showing" \
  "jq -e '.omitted.packages == 151' >/dev/null <<<\"\$big\""
check "the row that forces a reboot survives the cap" \
  "jq -e '[.packages[] | select(.name == \"linux\")] | length == 1' >/dev/null <<<\"\$big\""
check "tagged rows are ordered ahead of the ones that can be dropped" \
  "jq -e '.packages[0].tag != \"\"' >/dev/null <<<\"\$big\""
check "restartCount still counts the whole update" \
  "jq -e '.restartCount >= 1' >/dev/null <<<\"\$big\""

small=$(PATH="$stub:$PATH" OMARCHY_UPDATE_SCAN_MAX_ROWS=5 "$SCAN" --nosync --no-aur)
check "the row cap is the one configured, not a hardcoded one" \
  "jq -e '(.packages | length) == 5 and .omitted.packages == 396' >/dev/null <<<\"\$small\""

# --- missing dependencies --------------------------------------------------

missing=$(PATH=/nonexistent "$SCAN" --nosync --no-aur 2>/dev/null)
check "says what is missing instead of dying when nothing is on PATH" \
  "jq -e '.ok == false and (.error | length) > 10' >/dev/null <<<\"\$missing\""

# --- the boundary ----------------------------------------------------------
#
# The producers are trees, not processes. QML can only stop the child it
# started, so the guarantee that a stopped scan is actually over lives here, in
# a launcher that owns a process group. None of this shows up in the JSON, so
# it is exercised directly.

echo
echo "omarchy-update-bounded"

BOUNDED=./bin/omarchy-update-bounded

b_out=$("$BOUNDED" 10 1000 -- echo hi)
b_rc=$?
check "passes a producer's output straight through" "[[ \$b_out == hi ]]"
check "passes a producer's exit status straight through" "(( b_rc == 0 ))"

"$BOUNDED" 10 1000 -- bash -c 'exit 7' >/dev/null 2>&1
b_status=$?
check "does not flatten a failure into a success" "(( b_status == 7 ))"

b_capped=$("$BOUNDED" 10 100 -- yes 2>/dev/null)
b_capped_rc=$?
check "caps a producer that never stops talking" "(( \${#b_capped} <= 100 ))"
check "says it hit the cap instead of passing off a truncated answer" \
  "(( b_capped_rc == 125 ))"

b_started=$SECONDS
"$BOUNDED" 1 1000 -- sleep 60 >/dev/null 2>&1
b_deadline_rc=$?
check "stops a producer that overruns its deadline" "(( b_deadline_rc == 124 ))"
check "and stops it at the deadline, not whenever it finishes" \
  "(( SECONDS - b_started < 10 ))"

# A tree three deep, so that killing the immediate child would visibly not be
# enough. The marker is distinctive so pgrep cannot match anything else.
{
  echo '#!/bin/bash'
  echo '( ( sleep 4747 & sleep 4747 ) & sleep 4747 ) &'
  echo 'sleep 4747'
} >"$stub/tree"
chmod +x "$stub/tree"

"$BOUNDED" 120 1000 -- "$stub/tree" >/dev/null 2>&1 &
b_pid=$!
sleep 1
b_spawned=$(pgrep -fc 'sleep 4747')
kill -TERM "$b_pid" 2>/dev/null
wait "$b_pid" 2>/dev/null
b_cancel_rc=$?
b_left=$(pgrep -fc 'sleep 4747')
pkill -f 'sleep 4747' 2>/dev/null

check "the producer really did have descendants to lose" "(( b_spawned >= 3 ))"
# Read immediately after wait returns: this asserts both that the group was
# taken down and that cancellation waited for it rather than returning early.
check "cancelling takes the whole process group, not just the child" \
  "(( b_left == 0 ))"
check "cancelling reports that it was cancelled" "(( b_cancel_rc == 143 ))"

# --- the private package database ------------------------------------------
#
# checkupdates would otherwise sync into a predictable name in a directory the
# whole machine can write to, and what it holds decides which versions and
# sizes a person is shown before they agree to an update.

echo
echo "omarchy-update-db.sh"

me=$(id -u)
dbw=$stub/dbw
mkdir -p "$dbw"

db_line=$(source ./bin/omarchy-update-db.sh
  resolve_update_db "$dbw" && printf '%s|%s' "$UPDATE_DB" "$UPDATE_DB_EPHEMERAL")
db_path=${db_line%|*}
db_mode=$(stat -c '%F %u %a' "$db_path" 2>/dev/null)

check "resolves a database at all" "[[ -n \$db_path ]]"
check "and one that is a real directory, owned by this user, private" \
  "[[ \$db_mode == \"directory \$me 700\" ]]"

ln -sfn /tmp "$stub/runtime-symlink"
db_symlink=$(XDG_RUNTIME_DIR="$stub/runtime-symlink" bash -c \
  'source ./bin/omarchy-update-db.sh; resolve_update_db "$1" && printf %s "$UPDATE_DB_EPHEMERAL"' _ "$dbw")
check "refuses a runtime directory that is a symlink, and takes a fresh one" \
  "[[ \$db_symlink == 1 ]]"

mkdir -p "$stub/runtime/omarchy-update-review"
chmod 700 "$stub/runtime"
chmod 777 "$stub/runtime/omarchy-update-review"
db_loose=$(XDG_RUNTIME_DIR="$stub/runtime" bash -c \
  'source ./bin/omarchy-update-db.sh; resolve_update_db "$1" && printf %s "$UPDATE_DB_EPHEMERAL"' _ "$dbw")
db_loose_mode=$(stat -c %a "$stub/runtime/omarchy-update-review")
check "refuses a database directory left open to the group or the world" \
  "[[ \$db_loose == 1 ]]"
check "refuses it rather than tightening a directory it did not create" \
  "[[ \$db_loose_mode == 777 ]]"

shared=${TMPDIR:-/tmp}/checkup-db-$me
shared_before=$(stat -c %Y "$shared" 2>/dev/null || echo none)
"$SCAN" --nosync --no-aur >/dev/null
shared_after=$(stat -c %Y "$shared" 2>/dev/null || echo none)
check "a scan never touches the shared predictable database path" \
  "[[ \$shared_before == \$shared_after ]]"

# --- the producers, statically ---------------------------------------------

echo
echo "producers"

check "the scan runs behind the boundary rather than as the shell's own child" \
  "grep -qE '^[[:space:]]*exec .*omarchy-update-bounded' bin/omarchy-update-scan"
check "the availability check does too" \
  "grep -qE '^[[:space:]]*exec .*omarchy-update-bounded' bin/omarchy-update-check"
check "no producer reaches for a shared temporary path" \
  "! grep -hvE '^[[:space:]]*#' bin/omarchy-update-scan bin/omarchy-update-db.sh bin/omarchy-update-check | grep -q 'TMPDIR'"
check "pacman -Si is given a deadline" \
  "grep -qE 'timeout [0-9]+ pacman -Si' bin/omarchy-update-scan"
check "pacman -Si is given an output cap" \
  "grep -q 'MAX_SI_BYTES' bin/omarchy-update-scan"
check "the shell asks the boundary for the availability answer, not the tool" \
  "! grep -q 'omarchy-update-available' Service.qml"
check "and the panel tells it where that boundary is" \
  "grep -q 'omarchy-update-check' SystemUpdate.qml"

# --- the panel, statically ---------------------------------------------------
#
# Two properties of SystemUpdate.qml that no unit test can reach but that both
# came out of marketplace review, so they are worth a guard against quietly
# coming back.

echo
echo "SystemUpdate.qml"

# The binding, not the comment explaining why there is not one.
check "nothing keyboard-activates the update" \
  "! grep -qE '^[[:space:]]*onActivateRequested' SystemUpdate.qml"
check "the update has exactly three ways to start: right click, u, the button" \
  "(( \$(grep -c 'root.runUpdate()' SystemUpdate.qml) == 3 ))"
check "every Text in the panel renders as plain text" \
  "(( \$(grep -cE '^[[:space:]]*Text \{[[:space:]]*\$' SystemUpdate.qml) == \$(grep -c 'textFormat: Text.PlainText' SystemUpdate.qml) ))"

# --- the intake next door --------------------------------------------------

echo
if command -v node >/dev/null 2>&1; then
  echo "Model.js"
  if node test/model.test.js; then
    ok "Model.js suite passed"
  else
    no "Model.js suite failed"
  fi
else
  echo "Model.js  (skipped, node is not installed)"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
