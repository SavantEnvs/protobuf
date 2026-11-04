// Wire-format parser fuzzer: the C++ port of the legacy Jazzer ProtobufFuzzer, which fed raw bytes to
// the generated parseFrom() of several test messages.
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>

#include "google/protobuf/descriptor.h"
#include "google/protobuf/dynamic_message.h"
#include "google/protobuf/message.h"
#include "google/protobuf/test_messages_proto2.pb.h"
#include "google/protobuf/test_messages_proto3.pb.h"

namespace gp = google::protobuf;

static bool Exercise(gp::Message& msg, std::string_view in) {
  if (!msg.ParseFromString(in)) return false;
  std::string out;
  msg.SerializeToString(&out);
  (void)msg.ByteSizeLong();
  std::unique_ptr<gp::Message> copy(msg.New());
  copy->CopyFrom(msg);
  copy->MergeFrom(msg);
  return true;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  std::string_view in(reinterpret_cast<const char*>(data), size);
  bool ok = false;
  protobuf_test_messages::proto2::TestAllTypesProto2 m2;
  ok |= Exercise(m2, in);
  protobuf_test_messages::proto3::TestAllTypesProto3 m3;
  ok |= Exercise(m3, in);

  gp::DynamicMessageFactory factory;
  const gp::Descriptor* d =
      protobuf_test_messages::proto2::TestAllTypesProto2::descriptor();
  std::unique_ptr<gp::Message> dyn(factory.GetPrototype(d)->New());
  ok |= Exercise(*dyn, in);
  return ok ? 0 : -1;
}
