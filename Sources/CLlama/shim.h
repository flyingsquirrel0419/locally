#ifndef LOCALLY_CLLAMA_SHIM_H
#define LOCALLY_CLLAMA_SHIM_H

// Wraps the llama.cpp C API installed by scripts/build-llama-linux.sh into
// .deps/llama-install (Linux). The modulemap resolves the header through
// the symlinked `include` directory next to this file, so no -I flags are
// needed. On Apple the SwiftPM binary target provides the same symbols via
// the official xcframework.
#include "include/llama.h"

#endif
