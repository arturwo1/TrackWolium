#pragma once
#include <array>
#include <cstddef>
#include <chrono>
#include <string>
#include <vector>

namespace tw {

using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;
using Duration = std::chrono::milliseconds;

enum class State : int { Focused = 0, Open = 1, Minimized = 2, Background = 3 };

constexpr int kStateCount = 4;

struct AppSample {
  std::string app;
  State state;
};

struct Interval {
  std::string app;
  State state;
  Duration ms;
};

struct AppRow {
  std::string app;
  bool running = false;
  State state = State::Background;
  std::array<Duration, kStateCount> spent{};

  Duration total() const {
    Duration sum{0};
    for (const auto& d : spent) sum += d;
    return sum;
  }

  Duration visible() const {
    return spent[0] + spent[1] + spent[2];
  }
};

struct Report {
  std::vector<AppRow> rows;
  Duration uptime{0};
  std::size_t hidden = 0;
};

const char* state_name(State s);

}
