// Serialized FileDescriptorProto fuzzer: builds the descriptor in a pool (validation, option
// interpretation, feature resolution) and instantiates a dynamic message for every message type.
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

#include "google/protobuf/descriptor.h"
#include "google/protobuf/descriptor.pb.h"
#include "google/protobuf/dynamic_message.h"
#include "google/protobuf/text_format.h"

namespace gp = google::protobuf;

static void Visit(const gp::Descriptor* d, gp::DynamicMessageFactory& factory) {
  const gp::Message* proto = factory.GetPrototype(d);
  std::unique_ptr<gp::Message> m(proto->New());
  std::string text;
  gp::TextFormat::PrintToString(*m, &text);
  for (int i = 0; i < d->nested_type_count(); i++) Visit(d->nested_type(i), factory);
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  gp::FileDescriptorProto file;
  if (!file.ParseFromArray(data, static_cast<int>(size))) return -1;

  gp::DescriptorPool pool(gp::DescriptorPool::generated_pool());
  const gp::FileDescriptor* fd = pool.BuildFile(file);
  if (fd == nullptr) return 0;
  (void)fd->DebugString();
  gp::DynamicMessageFactory factory(&pool);
  for (int i = 0; i < fd->message_type_count(); i++) Visit(fd->message_type(i), factory);
  return 0;
}
