// Canonical-JSON parser/printer fuzzer over proto2 and proto3 test messages (Any, Struct, Timestamp, ...).
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

#include "google/protobuf/json/json.h"
#include "google/protobuf/test_messages_proto2.pb.h"
#include "google/protobuf/test_messages_proto3.pb.h"

namespace gp = google::protobuf;

template <typename T>
static bool Exercise(std::string_view in, bool lenient) {
  T msg;
  gp::json::ParseOptions opts;
  opts.ignore_unknown_fields = lenient;
  opts.case_insensitive_enum_parsing = lenient;
  if (!gp::json::JsonStringToMessage(in, &msg, opts).ok()) return false;
  std::string out;
  gp::json::PrintOptions popts;
  popts.add_whitespace = lenient;
  popts.always_print_fields_with_no_presence = lenient;
  (void)gp::json::MessageToJsonString(msg, &out, popts);
  return true;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  std::string_view in(reinterpret_cast<const char*>(data), size);
  bool ok = false;
  for (bool lenient : {false, true}) {
    ok |= Exercise<protobuf_test_messages::proto2::TestAllTypesProto2>(in, lenient);
    ok |= Exercise<protobuf_test_messages::proto3::TestAllTypesProto3>(in, lenient);
  }
  return ok ? 0 : -1;
}
