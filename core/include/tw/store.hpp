#pragma once
#include <string>
#include <utility>
#include <vector>
#include "tw/types.hpp"

namespace tw {

struct AppMeta {
  std::string app;
  std::string name;
  std::string path;
};

struct SlotEntry {
  int slot;
  std::string app;
  int state;
  long long ms;
};

struct SessionRec {
  std::string app;
  int state;
  long long start;
  long long stop;
};

class IStore {
public:
  virtual ~IStore() = default;
  virtual bool add(const std::string& day, const std::vector<Interval>& intervals) = 0;
  virtual std::vector<Interval> load_day(const std::string& day) = 0;
  virtual std::vector<std::string> days(int limit) = 0;
  virtual bool add_timeline(const std::string&, const std::vector<SlotEntry>&) { return true; }
  virtual bool add_sessions(const std::vector<SessionRec>&) { return true; }
  virtual bool set_names(const std::vector<AppMeta>&) { return true; }
};

}
