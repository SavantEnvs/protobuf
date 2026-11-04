// Known-answer probe for mayhem/test.sh: parses fixed wire bytes / JSON / text with the project's
// normal (unsanitized) libprotobuf and prints canonical results; test.sh diffs them with kat/expected.txt.
#include <cstdio>
#include <string>

#include "google/protobuf/json/json.h"
#include "google/protobuf/text_format.h"
#include "google/protobuf/test_messages_proto2.pb.h"
#include "google/protobuf/test_messages_proto3.pb.h"

namespace gp = google::protobuf;
using M3 = protobuf_test_messages::proto3::TestAllTypesProto3;
using M2 = protobuf_test_messages::proto2::TestAllTypesProto2;

static std::string Hex(const std::string& s) {
  std::string out;
  char buf[3];
  for (unsigned char c : s) { snprintf(buf, sizeof buf, "%02x", c); out += buf; }
  return out;
}

int main() {
  // 1. wire bytes -> fields (optional_int32=150, optional_string="testing", repeated_int32=[1,2,3])
  const std::string wire = std::string("\x08\x96\x01", 3) + std::string("\x72\x07testing", 9) +
                           std::string("\xfa\x01\x03\x01\x02\x03", 6);
  M3 m;
  if (!m.ParseFromString(wire)) { puts("wire parse: FAILED"); return 1; }
  printf("wire.int32=%d\n", m.optional_int32());
  printf("wire.string=%s\n", m.optional_string().c_str());
  printf("wire.repeated=%d,%d,%d\n", m.repeated_int32(0), m.repeated_int32(1), m.repeated_int32(2));

  // 2. fields -> wire
  M3 n;
  n.set_optional_int64(-2);
  n.set_optional_bool(true);
  n.set_optional_bytes(std::string("\xff\x00", 2) + "ab");
  printf("serialized=%s\n", Hex(n.SerializeAsString()).c_str());

  // 3. text format round trip
  std::string text;
  gp::TextFormat::PrintToString(m, &text);
  printf("text=%s", text.c_str());
  M3 t;
  if (!gp::TextFormat::ParseFromString("optional_double: 2.5 optional_nested_message { a: 7 }", &t)) { puts("text parse: FAILED"); return 1; }
  printf("text.double=%g nested.a=%d\n", t.optional_double(), t.optional_nested_message().a());

  // 4. JSON
  std::string js;
  auto st = gp::json::MessageToJsonString(m, &js);
  printf("json.status=%d\njson=%s\n", st.ok() ? 0 : 1, js.c_str());
  M3 j;
  st = gp::json::JsonStringToMessage(
      R"({"optionalInt32": 41, "optionalDuration": "3.5s", "repeatedString": ["a","b"], "optionalFloat": "Infinity"})", &j);
  printf("json.parse.status=%d int32=%d duration=%lld.%d strings=%d float_inf=%d\n", st.ok() ? 0 : 1, j.optional_int32(),
         (long long)j.optional_duration().seconds(), (int)j.optional_duration().nanos(), j.repeated_string_size(),
         (int)(j.optional_float() > 1e38f));
  M3 bad;
  st = gp::json::JsonStringToMessage(R"({"optionalInt32": "not a number"})", &bad);
  printf("json.bad.ok=%d\n", st.ok() ? 1 : 0);

  // 5. proto2: required/default/group and unknown field retention
  M2 p2;
  printf("proto2.default_int32=%d\n", p2.default_int32());
  const std::string unk("\xa0\x1f\x05", 3);  // field 500, varint 5 (unknown)
  M2 u;
  (void)u.ParseFromString(unk);
  printf("proto2.unknown_fields=%d roundtrip=%s\n", u.unknown_fields().field_count(), Hex(u.SerializeAsString()).c_str());
  return 0;
}
