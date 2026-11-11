#pragma once
#include "tw/win_util.hpp"
#include <cstring>
#include <filesystem>
#include <string>

namespace app {

constexpr wchar_t kGuardMutex[] = L"Local\\TrackWolium.Guard";
constexpr wchar_t kCoreMutex[] = L"Local\\TrackWolium.Core";
constexpr wchar_t kCoreStopEvent[] = L"Local\\TrackWolium.CoreStop";
constexpr wchar_t kCoreFlushEvent[] = L"Local\\TrackWolium.CoreFlush";
constexpr wchar_t kHeartbeatMap[] = L"Local\\TrackWolium.Heartbeat";
constexpr wchar_t kGuardCleanEvent[] = L"Local\\TrackWolium.GuardClean";
constexpr wchar_t kLiveMap[] = L"Local\\TrackWolium.Live";
constexpr DWORD kLiveSize = 256 * 1024;
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

inline std::wstring data_dir() {
  wchar_t buf[MAX_PATH * 2];
  DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
  std::wstring base = (n > 0 && n < sizeof(buf) / sizeof(buf[0])) ? std::wstring(buf, n) : exe_dir();
  return base + L"\\DTSys\\Wolium";
}

inline bool exists(const std::wstring& path) {
  std::error_code ec;
  return std::filesystem::exists(std::filesystem::path(path), ec);
}

inline void migrate_legacy_data() {
  std::error_code ec;
  std::filesystem::path legacy(exe_dir() + L"\\userdata");
  std::filesystem::path now(data_dir());
  if (!std::filesystem::exists(legacy, ec) || std::filesystem::exists(now, ec)) return;
  std::filesystem::create_directories(now.parent_path(), ec);
  std::filesystem::rename(legacy, now, ec);
  if (ec) {
    ec.clear();
    std::filesystem::copy(legacy, now, std::filesystem::copy_options::recursive, ec);
  }
}

inline std::wstring userdata(const std::wstring& name) {
  std::error_code ec;
  std::filesystem::create_directories(std::filesystem::path(data_dir()), ec);
  return data_dir() + L"\\" + name;
}

inline bool flag(const wchar_t* name) {
  return exists(data_dir() + L"\\" + name);
}

inline bool consent_given() { return exists(data_dir() + L"\\consent"); }
inline bool paused() { return exists(data_dir() + L"\\paused"); }

class Heartbeat {
public:
  ~Heartbeat() { close(); }

  bool create() {
    close();
    map_ = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(ULONGLONG), kHeartbeatMap);
    return map_ && view(FILE_MAP_WRITE);
  }

  void beat() {
    if (ptr_) InterlockedExchange64(reinterpret_cast<volatile LONG64*>(ptr_), static_cast<LONG64>(GetTickCount64()));
  }

  long long age_ms() {
    if (!ptr_) {
      map_ = OpenFileMappingW(FILE_MAP_READ, FALSE, kHeartbeatMap);
      if (!map_ || !view(FILE_MAP_READ)) {
        close();
        return -1;
      }
    }
    LONG64 v = *reinterpret_cast<volatile LONG64*>(ptr_);
    if (v == 0) return -1;
    return static_cast<long long>(GetTickCount64()) - v;
  }

  void close() {
    if (ptr_) UnmapViewOfFile(const_cast<ULONGLONG*>(ptr_));
    if (map_) CloseHandle(map_);
    ptr_ = nullptr;
    map_ = nullptr;
  }

private:
  bool view(DWORD access) {
    void* p = MapViewOfFile(map_, access, 0, 0, sizeof(ULONGLONG));
    ptr_ = static_cast<volatile ULONGLONG*>(p);
    return ptr_ != nullptr;
  }

  HANDLE map_ = nullptr;
  volatile ULONGLONG* ptr_ = nullptr;
};

class LiveShare {
public:
  ~LiveShare() {
    if (ptr_) UnmapViewOfFile(ptr_);
    if (map_) CloseHandle(map_);
  }

  bool create() {
    map_ = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, kLiveSize, kLiveMap);
    if (!map_) return false;
    ptr_ = static_cast<char*>(MapViewOfFile(map_, FILE_MAP_WRITE, 0, 0, kLiveSize));
    return ptr_ != nullptr;
  }

  void write(const std::string& text) {
    if (!ptr_) return;
    std::size_t n = text.size();
    if (n > kLiveSize - 8) {
      n = text.rfind('\n', kLiveSize - 9);
      if (n == std::string::npos) return;
      ++n;
    }
    volatile LONG* len = reinterpret_cast<volatile LONG*>(ptr_);
    InterlockedExchange(len, 0);
    std::memcpy(ptr_ + 8, text.data(), n);
    InterlockedExchange(len, static_cast<LONG>(n));
  }

  void clear() {
    if (ptr_) InterlockedExchange(reinterpret_cast<volatile LONG*>(ptr_), 0);
  }

private:
  HANDLE map_ = nullptr;
  char* ptr_ = nullptr;
};

}
