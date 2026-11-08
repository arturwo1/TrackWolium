#pragma once
#include "tw/types.hpp"

namespace tw {

class ISink {
public:
  virtual ~ISink() = default;
  virtual void render(const Report& report) = 0;
};

}
