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

struct ResEntry {
  int slot = 0;
  std::string app;
  long long cpu_ms = 0;
  long long ram_sum_kb = 0;
  long long ram_n = 0;
  long long peak_kb = 0;
  long long io_read = 0;
  long long io_write = 0;
};

struct SysEntry {
  long long ts = 0;
  std::string kind;
  long long a = 0;
  long long b = 0;
};

struct SysEvent {
  long long ts = 0;
  std::string kind;
  long long duration_ms = 0;
  std::string extra;
};

struct AppStatEntry {
  std::string app;
  std::string kind;
  long long n = 0;
};

struct SlotStatEntry {
  int slot = 0;
  std::string app;
  std::string kind;
  long long n = 0;
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
  virtual bool add_resources(const std::string&, const std::vector<ResEntry>&) { return true; }
  virtual bool add_system(const std::vector<SysEntry>&) { return true; }
  virtual bool add_sys_events(const std::vector<SysEvent>&) { return true; }
  virtual bool add_afk(const std::string&, const std::vector<SlotEntry>&) { return true; }
  virtual bool add_app_stats(const std::string&, const std::vector<AppStatEntry>&) { return true; }
  virtual bool add_slot_stats(const std::string&, const std::vector<SlotStatEntry>&) { return true; }
};

}
