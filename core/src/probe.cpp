#include "tw/probe.hpp"

namespace tw {

void PushProbe::push(std::vector<AppSample> samples) {
  std::lock_guard<std::mutex> lock(mtx_);
  data_ = std::move(samples);
}

std::vector<AppSample> PushProbe::sample() {
  std::lock_guard<std::mutex> lock(mtx_);
  return data_;
}

}
