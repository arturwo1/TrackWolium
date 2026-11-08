#pragma once
#include <map>
#include <string>
#include "tw/types.hpp"

namespace tw {

class Tracker {
public:
  explicit Tracker(Duration max_gap = Duration(5000));

  std::vector<Interval> tick(const std::vector<AppSample>& samples, TimePoint now);
  void seed(const std::vector<Interval>& intervals);
  Report report() const;

private:
  struct Entry {
    std::array<Duration, kStateCount> spent{};
    bool running = false;
    State state = State::Background;
  };

  std::map<std::string, Entry> entries_;
  TimePoint last_{};
  bool started_ = false;
  Duration max_gap_;
  Duration uptime_{0};
};

}
