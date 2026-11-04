// .proto source parser fuzzer (protoc's compiler::Parser), followed by descriptor building on success.
#include <cstddef>
#include <cstdint>
#include <string>

#include "google/protobuf/compiler/parser.h"
#include "google/protobuf/descriptor.h"
#include "google/protobuf/descriptor.pb.h"
#include "google/protobuf/io/tokenizer.h"
#include "google/protobuf/io/zero_copy_stream_impl_lite.h"

namespace gp = google::protobuf;

namespace {
class NullCollector : public gp::io::ErrorCollector {
 public:
  void RecordError(int, gp::io::ColumnNumber, absl::string_view) override {}
};
}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  gp::io::ArrayInputStream input(data, static_cast<int>(size));
  NullCollector errors;
  gp::io::Tokenizer tokenizer(&input, &errors);
  gp::compiler::Parser parser;
  parser.RecordErrorsTo(&errors);
  gp::FileDescriptorProto file;
  if (!parser.Parse(&tokenizer, &file)) return -1;
  file.set_name("fuzz.proto");

  gp::DescriptorPool pool(gp::DescriptorPool::generated_pool());
  pool.EnforceWeakDependencies(false);
  if (const gp::FileDescriptor* fd = pool.BuildFile(file)) {
    (void)fd->DebugString();
    gp::FileDescriptorProto round;
    fd->CopyTo(&round);
    fd->CopyJsonNameTo(&round);
    fd->CopySourceCodeInfoTo(&round);
  }
  return 0;
}
