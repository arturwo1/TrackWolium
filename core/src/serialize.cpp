#include "tw/serialize.hpp"
#include <sstream>

namespace tw {

std::string serialize(const Report& r) {
  std::ostringstream o;
  o << "TW1\n";
  o << "U " << r.uptime.count() << ' ' << r.hidden << '\n';
  for (const auto& row : r.rows) {
    std::string name = row.app;
    for (auto& c : name) {
      if (c == '\n' || c == '\r') c = ' ';
    }
    o << "A " << (row.running ? 1 : 0) << ' ' << static_cast<int>(row.state);
    for (const auto& d : row.spent) o << ' ' << d.count();
    o << ' ' << name << '\n';
  }
  return o.str();
}

bool deserialize(const std::string& data, Report& out) {
  std::istringstream in(data);
  std::string line;
  if (!std::getline(in, line) || line != "TW1") return false;

  Report r;
  if (!std::getline(in, line)) return false;
  {
    std::istringstream l(line);
    std::string tag;
    long long uptime = 0;
    std::size_t hidden = 0;
    if (!(l >> tag >> uptime >> hidden) || tag != "U") return false;
    r.uptime = Duration(uptime);
    r.hidden = hidden;
  }

  while (std::getline(in, line)) {
    if (line.empty()) continue;
    std::istringstream l(line);
    std::string tag;
    int running = 0;
    int state = 0;
    if (!(l >> tag >> running >> state) || tag != "A" || state < 0 || state >= kStateCount) return false;
    AppRow row;
    row.running = running != 0;
    row.state = static_cast<State>(state);
    for (int i = 0; i < kStateCount; ++i) {
      long long ms = 0;
      if (!(l >> ms)) return false;
      row.spent[static_cast<std::size_t>(i)] = Duration(ms);
    }
    l.get();
    std::getline(l, row.app);
    r.rows.push_back(std::move(row));
  }
  out = std::move(r);
  return true;
}

}
