#include "tw/limits.hpp"
#include <cstdlib>

namespace tw {

namespace {

std::vector<std::string> split(const std::string& s, char sep) {
  std::vector<std::string> out;
  std::size_t start = 0;
  for (;;) {
    std::size_t at = s.find(sep, start);
    if (at == std::string::npos) {
      out.push_back(s.substr(start));
      return out;
    }
    out.push_back(s.substr(start, at - start));
    start = at + 1;
  }
}

}

std::vector<Limit> parse_limits(const std::string& text) {
  std::vector<Limit> out;
  for (std::string line : split(text, '\n')) {
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    if (line.empty()) continue;
    auto parts = split(line, '\t');
    if (parts.size() < 3) continue;
    bool digits = !parts[0].empty() && parts[0].size() <= 7;
    for (char c : parts[0]) {
      if (c < '0' || c > '9') digits = false;
    }
    if (!digits || parts[1].empty()) continue;
    Limit l;
    l.seconds = std::atoll(parts[0].c_str());
    if (l.seconds < 60) continue;
    l.label = parts[1];
    for (auto& a : split(parts[2], '\x1f')) {
      if (!a.empty()) l.apps.insert(a);
    }
    if (l.apps.empty()) continue;
    l.title = parts.size() > 3 && !parts[3].empty() ? parts[3] : l.label;
    l.body = parts.size() > 4 && !parts[4].empty() ? parts[4] : l.label;
    out.push_back(std::move(l));
  }
  return out;
}

}
