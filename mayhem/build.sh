#!/usr/bin/env bash
#
# mayhem/build.sh — builds protobuf twice from one tree:
#   mayhem/build/san     sanitized (ASan+UBSan, SanCov on the library) libprotobuf/libprotoc/libupb + the fuzz harnesses
#   mayhem/build/normal  project-default flags: protoc + libprotobuf + upstream's ctest suites (lite-test, full-test,
#                        lazily-build-dependencies-test, upb-test), run by mayhem/test.sh together with the KATs
# Everything resolves from the image: abseil and googletest come from /opt/toolchains/deps (pinned in the
# Dockerfile), so re-running this script offline works.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
M="$SRC/mayhem"
B="$M/build"
ABSL=/opt/toolchains/deps/abseil-cpp
GTEST=/opt/toolchains/deps/googletest

COMMON=(-G Ninja
  -DCMAKE_CXX_STANDARD=17 -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -Dprotobuf_BUILD_CONFORMANCE=OFF -Dprotobuf_BUILD_SHARED_LIBS=OFF
  -Dprotobuf_INSTALL=OFF -Dprotobuf_WITH_ZLIB=OFF -Dprotobuf_ABSL_PROVIDER=module
  -DABSL_PROPAGATE_CXX_STD=ON -DABSL_BUILD_TESTING=OFF -DABSL_ENABLE_INSTALL=OFF
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON -DFETCHCONTENT_SOURCE_DIR_ABSL="$ABSL" -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST="$GTEST")

# 1) Normal build (oracle): protoc + libprotobuf + upstream's test suites, project-default flags.
cmake -S "$SRC" -B "$B/normal" "${COMMON[@]}" -Dprotobuf_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$B/normal" -j"$MAYHEM_JOBS" --target protoc libprotobuf \
  lite-test tests lazily-build-dependencies-test upb-test fake_plugin test_plugin
PROTOC="$B/normal/protoc"

# Generated code for the harnesses/probe (identical to what the sanitized runtime expects: same sources).
GEN="$B/gen"; mkdir -p "$GEN"
"$PROTOC" -I "$SRC/src" --cpp_out="$GEN" \
  "$SRC/src/google/protobuf/test_messages_proto2.proto" \
  "$SRC/src/google/protobuf/test_messages_proto3.proto"

# KAT probe for test.sh: normal flags, dynamically linked.
mkdir -p "$B/probe"
"$CXX" -std=c++17 -O1 $COVERAGE_FLAGS -I"$GEN" -I"$SRC/src" -I"$ABSL" -I"$SRC/third_party/utf8_range" "$M/kat/kat_probe.cc" \
  "$GEN/google/protobuf/test_messages_proto2.pb.cc" "$GEN/google/protobuf/test_messages_proto3.pb.cc" \
  -Wl,--start-group $(find "$B/normal" -name '*.a' ! -name '*test*' ! -name '*gmock*' ! -name '*gtest*') -Wl,--end-group -lpthread \
  -o /mayhem/kat_probe

# 2) Sanitized build: SanCov (fuzzer-no-link) on the library so the fuzzed code reports edges.
SAN_C="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1"
cmake -S "$SRC" -B "$B/san" "${COMMON[@]}" -Dprotobuf_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE= \
  -DCMAKE_C_FLAGS="$SAN_C" -DCMAKE_CXX_FLAGS="$SAN_C"
cmake --build "$B/san" -j"$MAYHEM_JOBS" --target libprotobuf libprotoc libupb utf8_validity

LIBS=$(find "$B/san" -name '*.a')
INC=(-I"$GEN" -I"$SRC/src" -I"$SRC" -I"$ABSL" -I"$SRC/third_party/utf8_range")
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/lsan_off.cc" -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

# One object per generated test proto, compiled once.
for p in test_messages_proto2 test_messages_proto3; do
  $CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link "${INC[@]}" \
    -c "$GEN/google/protobuf/$p.pb.cc" -o "$B/$p.pb.o"
done

build_harness() {  # <name> <source> <extra objects...>
  local name="$1" src="$2"; shift 2
  $CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link "${INC[@]}" -c "$src" -o "$B/$name.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/$name.o" "$@" "$B/lsan_off.o" \
    -Wl,--start-group $LIBS -Wl,--end-group -lpthread -o "/mayhem/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$B/$name.o" "$@" "$B/standalone_main.o" "$B/lsan_off.o" \
    -Wl,--start-group $LIBS -Wl,--end-group -lpthread -o "/mayhem/$name-standalone"
}

PB2="$B/test_messages_proto2.pb.o"; PB3="$B/test_messages_proto3.pb.o"
build_harness ProtobufFuzzer      "$M/harnesses/ProtobufFuzzer.cc"      "$PB2" "$PB3"
build_harness text_format_fuzzer  "$M/harnesses/text_format_fuzzer.cc"  "$PB2" "$PB3"
build_harness json_fuzzer         "$M/harnesses/json_fuzzer.cc"         "$PB2" "$PB3"
build_harness proto_parser_fuzzer "$M/harnesses/proto_parser_fuzzer.cc"
build_harness descriptor_fuzzer   "$M/harnesses/descriptor_fuzzer.cc"
# Upstream's own libFuzzer harness for utf8_range.
build_harness utf8_validity_fuzzer "$SRC/third_party/utf8_range/fuzz/utf8_validity_fuzzer.cc"
