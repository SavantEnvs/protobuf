#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's own CMake/ctest suites (lite-test, full-test, lazily-build-dependencies-test,
# upb-test) plus a set of known-answer checks (KATs: fixed input -> exact expected bytes/text/diagnostics)
# against the normal (unsanitized) build that mayhem/build.sh left in mayhem/build/normal.
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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


NORMAL="$SRC/mayhem/build/normal"
PROTOC="$NORMAL/protoc"
PROBE="$SRC/kat_probe"
KAT="$SRC/mayhem/kat"
for f in "$PROTOC" "$PROBE" "$KAT/expected.txt"; do
  [ -e "$f" ] || { echo "missing $f (mayhem/build.sh should have produced it)" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 1; }
done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 0. Upstream's ctest suites. gtest writes one JSON report per binary (GTEST_OUTPUT, a directory form);
#    the per-test-case counts of those reports are what is folded into the CTRF summary.
SUITES="lite-test tests lazily-build-dependencies-test upb-test"
for t in $SUITES; do
  [ -x "$NORMAL/$t" ] || { echo "missing $NORMAL/$t (mayhem/build.sh should have produced it)" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 1; }
done
mkdir -p "$TMP/gtest"
GTEST_OUTPUT="json:$TMP/gtest/" ctest --test-dir "$NORMAL" --output-on-failure --timeout 3000 > "$TMP/ctest.log" 2>&1
ctest_rc=$?
tail -n 25 "$TMP/ctest.log"
read -r passed failed skipped < <(python3 - "$TMP/gtest" $SUITES <<'PY'
import json, os, sys
d, suites = sys.argv[1], sys.argv[2:]
p = f = s = 0
for name in suites:
    path = os.path.join(d, name + ".json")
    if not os.path.exists(path):
        f += 1
        print(f"no gtest report for {name}", file=sys.stderr)
        continue
    with open(path) as fh:
        report = json.load(fh)
    n = 0
    for suite in report.get("testsuites", []):
        for case in suite.get("testsuite", []):
            n += 1
            if case.get("result") == "SKIPPED" or case.get("status") == "NOTRUN":
                s += 1
            elif case.get("failures"):
                f += 1
                print(f"FAIL {name}: {suite['name']}.{case['name']}", file=sys.stderr)
            else:
                p += 1
    if n == 0:
        f += 1
        print(f"gtest report for {name} holds no test", file=sys.stderr)
print(p, f, s)
PY
)
[ "$ctest_rc" -eq 0 ] || [ "$failed" -gt 0 ] || { echo "ctest exited $ctest_rc with no failing test case" >&2; failed=1; }
echo "upstream suites: passed=$passed failed=$failed skipped=$skipped"

check() {  # <name> <expected> <actual>
  if [ "$2" == "$3" ]; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL $1" >&2; echo "  expected: $2" >&2; echo "  actual:   $3" >&2; fi
}
hex() { od -An -tx1 -v | tr -d ' \n'; }
T3=protobuf_test_messages.proto3.TestAllTypesProto3
P3=google/protobuf/test_messages_proto3.proto

# 1. kat_probe (libprotobuf: wire/text/JSON parse+print) line by line against the golden output.
"$PROBE" > "$TMP/probe.out" 2>"$TMP/probe.err" || echo "kat_probe exited non-zero" >&2
n=0
while IFS= read -r want; do
  n=$((n+1)); got="$(sed -n "${n}p" "$TMP/probe.out")"
  check "probe line $n" "$want" "$got"
done < "$KAT/expected.txt"
check "probe line count" "$(wc -l < "$KAT/expected.txt")" "$(wc -l < "$TMP/probe.out")"

# 2. protoc --encode: text -> wire bytes.
check "encode" "089601720774657374696e67" "$(printf 'optional_int32: 150 optional_string: "testing"' | "$PROTOC" -I "$SRC/src" --encode=$T3 $P3 | hex)"
check "encode nested+packed" "9201020807fa0103010203" "$(printf 'repeated_int32: [1,2,3] optional_nested_message { a: 7 }' | "$PROTOC" -I "$SRC/src" --encode=$T3 $P3 | hex)"

# 3. protoc --decode: wire bytes -> text.
check "decode" "optional_int32: 150 optional_string: \"testing\" repeated_int32: 1 repeated_int32: 2" \
  "$(printf '\x08\x96\x01\x72\x07testing\xfa\x01\x02\x01\x02' | "$PROTOC" -I "$SRC/src" --decode=$T3 $P3 | tr '\n' ' ' | sed 's/ $//')"
check "decode_raw" "1: 150 14: \"testing\"" "$(printf '\x08\x96\x01\x72\x07testing' | "$PROTOC" --decode_raw | tr '\n' ' ' | sed 's/ $//')"

# 4. protoc compiles a .proto into a descriptor set carrying the declared names / numbers / json_name.
SMALL="$SRC/mayhem/proto_parser_fuzzer/testsuite/small.proto"
"$PROTOC" -I "$SRC/mayhem/proto_parser_fuzzer/testsuite" -I "$SRC/src" --descriptor_set_out="$TMP/ds.bin" "$SMALL"
"$PROTOC" -I "$SRC/src" --decode=google.protobuf.FileDescriptorSet google/protobuf/descriptor.proto < "$TMP/ds.bin" > "$TMP/ds.txt"
check "descriptor package" "1" "$(grep -c '^  package: "a.b"$' "$TMP/ds.txt")"
check "descriptor json_name" "1" "$(grep -c 'json_name: "ID"' "$TMP/ds.txt")"
check "descriptor map entry" "1" "$(grep -c 'name: "MEntry"' "$TMP/ds.txt")"
check "descriptor service" "1" "$(grep -c 'server_streaming: true' "$TMP/ds.txt")"

# 5. protoc rejects invalid input with a specific diagnostic and a non-zero exit.
printf 'syntax = "proto3";\nmessage M { int32 a = 1; extensions 100 to 199; }\n' > "$TMP/bad.proto"
out="$("$PROTOC" -I "$TMP" --descriptor_set_out="$TMP/bad.bin" "$TMP/bad.proto" 2>&1)"; rc=$?
check "bad proto diagnostic" "bad.proto:2:37: Extension ranges are not allowed in proto3." "${out#$TMP/}"
check "bad proto exit" "1" "$rc"
printf 'syntax = "proto2";\nmessage M { required int32 a = 1; required int32 a = 2; }\n' > "$TMP/dup.proto"
out="$("$PROTOC" -I "$TMP" --descriptor_set_out="$TMP/dup.bin" "$TMP/dup.proto" 2>&1)"
check "duplicate field diagnostic" "1" "$(printf '%s' "$out" | grep -c '"a" is already defined in "M"')"

emit_ctrf "cmake-ctest" "$passed" "$failed" "$skipped"
