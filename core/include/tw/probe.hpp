#pragma once
#include <mutex>
#include <vector>
#include "tw/types.hpp"

namespace tw {

class IProbe {
public:
  virtual ~IProbe() = default;
  virtual std::vector<AppSample> sample() = 0;
  virtual bool reports_windows() const { return true; }
};

class PushProbe : public IProbe {
public:
  void push(std::vector<AppSample> samples);
  std::vector<AppSample> sample() override;

private:
  std::mutex mtx_;
  std::vector<AppSample> data_;
};

}
