#pragma once
#include <set>
#include <string>
#include <vector>

namespace tw {

struct Limit {
  long long seconds = 0;
  std::string label;
  std::string title;
  std::string body;
  std::set<std::string> apps;
};

std::vector<Limit> parse_limits(const std::string& text);

}
