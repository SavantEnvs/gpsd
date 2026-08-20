#!/usr/bin/env bash
#
# gpsd/mayhem/test.sh — RUN gpsd's OWN self-contained unit / known-answer tests (built with NORMAL
# flags by mayhem/build.sh), emitting a CTRF summary. exit 0 iff none failed.
#
# PATCH-grade oracle: these are gpsd's real regression unit tests (tests/test_*.c). Each one is a
# known-answer test that calls exit(EXIT_FAILURE) on any mismatch:
#   test_packet  — drives the packet lexer over a fixed table of NMEA/AIS/binary packets and prints
#                  per-case results; we diff its output against the committed golden test/packet.test.chk
#                  (BYTE-EXACT), so a no-op / "return success" patch to the lexer cannot pass.
#   test_json    — round-trips JSON reports through the parser and asserts every decoded field.
#   test_bits    — bitfield extraction KAT (ubits/sbits/...); nonzero exit on any failure.
#   test_crc     — RTCM/NMEA/etc checksum KAT.   test_mktime/test_timespec — time math KAT.
#   test_geoid   — geoid/variation model KAT.     test_matrix/test_trig — DOP/trig math KAT.
#   test_libgps  — libgps client-side sentence decoder: batch mode (-b) decodes the committed
#                  test/clientlib/multipacket.log and we diff the result against its golden .chk
#                  (upstream's unpack-regress), so an empty or no-op decode fails.
# They assert concrete values / byte-exact output, so they're a genuine functional oracle, not a stub.
#
# This script never compiles: rlenv runs it as the unprivileged runner, so mayhem/build.sh builds the
# tests (normal flags, independent of the sanitized fuzz build) and this only RUNS them. Scratch goes
# to a fresh $TMPDIR dir — never fixed /tmp paths, which a build-time run leaves owned by the builder.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
SRC="${SRC:-$(pwd)}"
cd "$SRC"

: "${MAYHEM_JOBS:=$(nproc)}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# No case reads stdin; close it so none can block on an inherited never-EOF pipe.
exec </dev/null

# scons' variant dir gpsd-<version>~dev/ holds the tests mayhem/build.sh built.
BUILDDIR="$(ls -d "$SRC"/gpsd-*~dev/ 2>/dev/null | head -1)"
BUILDDIR="${BUILDDIR%/}"
if [ -z "$BUILDDIR" ] || [ ! -d "$BUILDDIR/tests" ]; then
  echo "gpsd unit tests missing (no gpsd-*~dev/tests) — mayhem/build.sh must build them" >&2
  emit_ctrf "gpsd-unit" 0 1 0; exit 2
fi
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gpsd-test.XXXXXX")"

PASSED=0; FAILED=0
run_case() {
  # run_case <name> <command...>
  local name="$1"; shift
  if [ ! -x "$BUILDDIR/tests/$name" ]; then
    echo "MISS  $name (binary not built)"; FAILED=$((FAILED+1)); return
  fi
  echo "--- $name ---"
  if "$@" >"$SCRATCH/$name.out" 2>&1; then
    echo "PASS  $name"; PASSED=$((PASSED+1))
  else
    echo "FAIL  $name (rc=$?)"; tail -15 "$SCRATCH/$name.out"; FAILED=$((FAILED+1))
  fi
}

TB="$BUILDDIR/tests"

# test_packet: byte-exact golden-output KAT — diff its output vs committed test/packet.test.chk.
run_case test_packet bash -c '"'"$TB"'/test_packet" | diff -u "'"$SRC"'/test/packet.test.chk" -'

# The rest exit nonzero on any KAT mismatch.
run_case test_bits     "$TB/test_bits" --quiet
run_case test_crc      "$TB/test_crc"
run_case test_json     "$TB/test_json"
run_case test_mktime   "$TB/test_mktime"
run_case test_geoid    "$TB/test_geoid"
run_case test_matrix   "$TB/test_matrix" --quiet
run_case test_timespec "$TB/test_timespec" --quiet
run_case test_trig     "$TB/test_trig"
# test_libgps -b is BATCH mode: it gps_unpack()s JSON lines from stdin until EOF (without -b it wants a
# live daemon). Fed nothing it asserts nothing, so feed it the committed clientlib log and diff the
# decode against its golden .chk — exactly upstream's unpack-regress (regress-driver -c).
run_case test_libgps bash -c '"'"$TB"'/test_libgps" -b < "'"$SRC"'/test/clientlib/multipacket.log" | diff -u "'"$SRC"'/test/clientlib/multipacket.log.chk" -'

emit_ctrf "gpsd-unit" "$PASSED" "$FAILED" 0
