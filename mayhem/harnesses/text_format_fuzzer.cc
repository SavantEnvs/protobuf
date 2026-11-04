// Text-format parser fuzzer over proto2 (groups, extensions, required) and proto3 (Any, WKTs) messages.
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

#include "google/protobuf/text_format.h"
#include "google/protobuf/test_messages_proto2.pb.h"
#include "google/protobuf/test_messages_proto3.pb.h"

namespace gp = google::protobuf;

template <typename T>
static bool Exercise(std::string_view in) {
  T msg;
  gp::TextFormat::Parser parser;
  parser.AllowPartialMessage(true);
  if (!parser.ParseFromString(std::string(in), &msg)) return false;
  std::string text;
  gp::TextFormat::PrintToString(msg, &text);
  std::string wire;
  msg.SerializePartialToString(&wire);
  return true;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  std::string_view in(reinterpret_cast<const char*>(data), size);
  bool ok = false;
  ok |= Exercise<protobuf_test_messages::proto2::TestAllTypesProto2>(in);
  ok |= Exercise<protobuf_test_messages::proto3::TestAllTypesProto3>(in);
  return ok ? 0 : -1;
}
