#pragma once
#include <map>
#include <string>
#include <vector>

namespace tw {

struct ProcSnap {
  long long pid = 0;
  long long stamp = 0;
  std::string app;
  long long cpu_ms = 0;
  long long rss_kb = 0;
  long long peak_kb = 0;
  long long io_read = 0;
  long long io_write = 0;
};

struct AppRes {
  long long cpu_ms = 0;
  long long rss_kb = 0;
  long long peak_kb = 0;
  long long io_read = 0;
  long long io_write = 0;
};

struct DiskStat {
  std::string mount;
  long long total_kb = 0;
  long long free_kb = 0;
};

struct SysStat {
  long long ram_total_kb = 0;
  long long ram_avail_kb = 0;
  std::vector<DiskStat> disks;
  bool valid = false;
};

struct MetricsConfig {
  bool cpu = false;
  bool ram = false;
  bool peak = false;
  bool io_read = false;
  bool io_write = false;
  bool sys_ram = false;
  bool sys_disk = false;
  bool no_time = false;

  bool any_proc() const { return cpu || ram || peak || io_read || io_write; }
  bool any_sys() const { return sys_ram || sys_disk; }
  bool any() const { return any_proc() || any_sys(); }
  bool operator==(const MetricsConfig& o) const {
    return cpu == o.cpu && ram == o.ram && peak == o.peak && io_read == o.io_read && io_write == o.io_write && sys_ram == o.sys_ram && sys_disk == o.sys_disk && no_time == o.no_time;
  }
  bool operator!=(const MetricsConfig& o) const { return !(*this == o); }
};

MetricsConfig parse_metrics(const std::string& text);
std::string format_metrics(const MetricsConfig& c);

class ProcTracker {
public:
  std::map<std::string, AppRes> update(const std::vector<ProcSnap>& snaps);
  void reset();

private:
  struct Last {
    long long stamp = 0;
    long long cpu_ms = 0;
    long long io_read = 0;
    long long io_write = 0;
    long long peak_kb = 0;
  };
  std::map<long long, Last> last_;
  bool primed_ = false;
};

}
