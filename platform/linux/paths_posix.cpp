#include "tw/paths.hpp"
#include <cstdlib>
#include <filesystem>

namespace tw {

std::string default_data_dir() {
  std::string base;
  const char* xdg = std::getenv("XDG_DATA_HOME");
  if (xdg && *xdg) {
    base = xdg;
  } else {
    const char* home = std::getenv("HOME");
    if (!home || !*home) return {};
    base = std::string(home) + "/.local/share";
  }
  return base + "/trackwolium";
}

std::string default_db_path() {
  std::string dir = default_data_dir();
  if (dir.empty()) return {};
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  if (ec) return {};
  return dir + "/usage.db";
}

}
