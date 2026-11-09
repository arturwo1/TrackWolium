#pragma once
#include <string>
#include <utility>
#include <vector>
#include "tw/types.hpp"

namespace tw {

struct SlotEntry {
  int slot;
  std::string app;
  int state;
  long long ms;
};

class IStore {
public:
  virtual ~IStore() = default;
  virtual bool add(const std::string& day, const std::vector<Interval>& intervals) = 0;
  virtual std::vector<Interval> load_day(const std::string& day) = 0;
  virtual std::vector<std::string> days(int limit) = 0;
  virtual bool add_timeline(const std::string&, const std::vector<SlotEntry>&) { return true; }
  virtual bool set_names(const std::vector<std::pair<std::string, std::string>>&) { return true; }
};

}
