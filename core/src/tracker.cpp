#include "tw/tracker.hpp"
#include <algorithm>

namespace tw {

const char* state_name(State s) {
  switch (s) {
    case State::Focused: return "focused";
    case State::Open: return "open";
    case State::Minimized: return "minimized";
    case State::Background: return "background";
  }
  return "unknown";
}

Tracker::Tracker(Duration max_gap) : max_gap_(max_gap) {}

std::vector<Interval> Tracker::tick(const std::vector<AppSample>& samples, TimePoint now) {
  std::vector<Interval> out;
  if (started_) {
    auto dt = std::chrono::duration_cast<Duration>(now - last_);
    if (dt >= Duration(0) && dt <= max_gap_) {
      for (auto& kv : entries_) {
        if (!kv.second.running) continue;
        kv.second.spent[static_cast<int>(kv.second.state)] += dt;
        if (dt > Duration(0)) out.push_back({kv.first, kv.second.state, dt});
      }
      uptime_ += dt;
    }
  }

  for (auto& kv : entries_) kv.second.running = false;
  for (const auto& s : samples) {
    auto& e = entries_[s.app];
    if (!e.running || static_cast<int>(s.state) < static_cast<int>(e.state)) e.state = s.state;
    e.running = true;
  }

  last_ = now;
  started_ = true;
  return out;
}

void Tracker::seed(const std::vector<Interval>& intervals) {
  for (const auto& iv : intervals) {
    entries_[iv.app].spent[static_cast<int>(iv.state)] += iv.ms;
  }
}

Report Tracker::report() const {
  Report r;
  r.uptime = uptime_;
  r.rows.reserve(entries_.size());
  for (const auto& kv : entries_) {
    AppRow row;
    row.app = kv.first;
    row.running = kv.second.running;
    row.state = kv.second.state;
    row.spent = kv.second.spent;
    r.rows.push_back(std::move(row));
  }
  std::sort(r.rows.begin(), r.rows.end(), [](const AppRow& a, const AppRow& b) {
    if (a.visible() != b.visible()) return a.visible() > b.visible();
    if (a.total() != b.total()) return a.total() > b.total();
    return a.app < b.app;
  });
  return r;
}

}
