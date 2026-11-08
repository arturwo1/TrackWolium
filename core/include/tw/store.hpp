#pragma once
#include <string>
#include <vector>
#include "tw/types.hpp"

namespace tw {

class IStore {
public:
  virtual ~IStore() = default;
  virtual bool add(const std::string& day, const std::vector<Interval>& intervals) = 0;
  virtual std::vector<Interval> load_day(const std::string& day) = 0;
  virtual std::vector<std::string> days(int limit) = 0;
};

}
