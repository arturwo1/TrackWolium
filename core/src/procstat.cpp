#include "tw/procstat.hpp"
#include <algorithm>
#include <sstream>

namespace tw {

namespace {
constexpr long long kNewProcessWindowMs = 60000;
}

MetricsConfig parse_metrics(const std::string& text) {
  MetricsConfig c;
  std::istringstream in(text);
  std::string tok;
  while (in >> tok) {
    if (tok == "cpu") c.cpu = true;
    else if (tok == "ram") c.ram = true;
    else if (tok == "peak") c.peak = true;
    else if (tok == "ior") c.io_read = true;
    else if (tok == "iow") c.io_write = true;
    else if (tok == "sysram") c.sys_ram = true;
    else if (tok == "sysdisk") c.sys_disk = true;
    else if (tok == "notime") c.no_time = true;
  }
  return c;
}

std::string format_metrics(const MetricsConfig& c) {
  std::string out;
  auto add = [&](bool on, const char* name) {
    if (!on) return;
    if (!out.empty()) out += ' ';
    out += name;
  };
  add(c.cpu, "cpu");
  add(c.ram, "ram");
  add(c.peak, "peak");
  add(c.io_read, "ior");
  add(c.io_write, "iow");
  add(c.sys_ram, "sysram");
  add(c.sys_disk, "sysdisk");
  add(c.no_time, "notime");
  return out;
}

void ProcTracker::reset() {
  last_.clear();
  primed_ = false;
}

std::map<std::string, AppRes> ProcTracker::update(const std::vector<ProcSnap>& snaps) {
  std::map<std::string, AppRes> out;
  std::map<long long, Last> next;
  for (const auto& s : snaps) {
    AppRes& r = out[s.app];
    auto it = last_.find(s.pid);
    bool same = it != last_.end() && it->second.stamp == s.stamp;
    long long dc = 0, dr = 0, dw = 0;
    long long peak = s.rss_kb;
    if (same) {
      dc = std::max<long long>(0, s.cpu_ms - it->second.cpu_ms);
      dr = std::max<long long>(0, s.io_read - it->second.io_read);
      dw = std::max<long long>(0, s.io_write - it->second.io_write);
      if (s.peak_kb > it->second.peak_kb) peak = std::max(peak, s.peak_kb);
    } else if (primed_ && (s.age_ms < 0 || s.age_ms <= kNewProcessWindowMs)) {
      dc = s.cpu_ms;
      dr = s.io_read;
      dw = s.io_write;
      peak = std::max(peak, s.peak_kb);
    }
    r.cpu_ms += dc;
    r.io_read += dr;
    r.io_write += dw;
    r.rss_kb += s.rss_kb;
    r.peak_kb += peak;
    Last l;
    l.stamp = s.stamp;
    l.cpu_ms = s.cpu_ms;
    l.io_read = s.io_read;
    l.io_write = s.io_write;
    l.peak_kb = s.peak_kb;
    next[s.pid] = l;
  }
  last_.swap(next);
  primed_ = true;
  return out;
}

}
