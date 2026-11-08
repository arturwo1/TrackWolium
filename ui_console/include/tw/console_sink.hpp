#pragma once
#include <cstddef>
#include <ostream>
#include <string>
#include "tw/sink.hpp"

namespace tw {

struct ConsoleOptions {
  bool color = true;
  bool live = true;
  std::size_t top = 20;
  std::string title = "TrackWolium";
  bool show_uptime = true;
};

class ConsoleSink : public ISink {
public:
  ConsoleSink(std::ostream& out, ConsoleOptions options);
  ~ConsoleSink() override;

  void render(const Report& report) override;

private:
  std::ostream& out_;
  ConsoleOptions opt_;
  bool started_ = false;
};

std::string format_duration(Duration d);
bool console_setup();

}
