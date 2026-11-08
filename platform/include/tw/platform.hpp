#pragma once
#include <memory>
#include "tw/probe.hpp"

namespace tw {

struct ProbeOptions {
  bool include_system = false;
};

std::unique_ptr<IProbe> make_native_probe(const ProbeOptions& options);

}
