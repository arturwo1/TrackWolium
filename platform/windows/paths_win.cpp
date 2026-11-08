#include "tw/paths.hpp"
#include <filesystem>
#include "tw/win_util.hpp"

namespace tw {

std::string default_data_dir() {
  wchar_t buf[MAX_PATH * 2];
  DWORD cap = static_cast<DWORD>(sizeof(buf) / sizeof(buf[0]));
  DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, cap);
  if (n == 0 || n >= cap) return {};
  return to_utf8(std::wstring(buf, n) + L"\\TrackWolium");
}

std::string default_db_path() {
  std::string dir = default_data_dir();
  if (dir.empty()) return {};
  std::error_code ec;
  std::filesystem::create_directories(std::filesystem::path(from_utf8(dir)), ec);
  if (ec) return {};
  return dir + "\\usage.db";
}

}
