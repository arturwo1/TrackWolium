#pragma once
#include "tw/win_util.hpp"
#include <filesystem>
#include <string>

namespace app {

constexpr wchar_t kGuardMutex[] = L"Local\\TrackWolium.Guard";
constexpr wchar_t kCoreMutex[] = L"Local\\TrackWolium.Core";
constexpr wchar_t kCoreStopEvent[] = L"Local\\TrackWolium.CoreStop";
constexpr wchar_t kGuardClass[] = L"WoliumGuardWindow";
constexpr UINT kMsgEnsure = WM_APP + 2;
constexpr UINT kMsgOpenUi = WM_APP + 3;

inline std::wstring exe_dir() {
  wchar_t buf[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
  std::wstring p(buf, n);
  std::size_t slash = p.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring() : p.substr(0, slash);
}

inline std::wstring sibling(const std::wstring& name) { return exe_dir() + L"\\" + name; }

inline std::wstring userdata(const std::wstring& name) {
  std::error_code ec;
  std::filesystem::create_directories(std::filesystem::path(exe_dir() + L"\\userdata"), ec);
  return exe_dir() + L"\\userdata\\" + name;
}

inline bool exists(const std::wstring& path) {
  std::error_code ec;
  return std::filesystem::exists(std::filesystem::path(path), ec);
}

inline bool consent_given() { return exists(exe_dir() + L"\\userdata\\consent"); }
inline bool paused() { return exists(exe_dir() + L"\\userdata\\paused"); }

inline long long file_age_ms(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA d{};
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &d)) return -1;
  FILETIME now;
  GetSystemTimeAsFileTime(&now);
  ULARGE_INTEGER a, b;
  a.LowPart = now.dwLowDateTime;
  a.HighPart = now.dwHighDateTime;
  b.LowPart = d.ftLastWriteTime.dwLowDateTime;
  b.HighPart = d.ftLastWriteTime.dwHighDateTime;
  if (a.QuadPart < b.QuadPart) return 0;
  return static_cast<long long>((a.QuadPart - b.QuadPart) / 10000);
}

}
