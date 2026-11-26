#pragma once

#include <string>

namespace tw {

inline bool is_valid_battery_status(unsigned char ac_line, unsigned char flag, unsigned char pct) {
  if (flag == 255 || (flag & 128) != 0) return false;
  if (pct > 100) return false;
  if (ac_line == 1 && flag == 0 && pct == 0) return false;
  return true;
}

inline bool should_unwrap_uwp_host(const std::string& exe_lower) {
  return exe_lower == "applicationframehost.exe";
}

}
