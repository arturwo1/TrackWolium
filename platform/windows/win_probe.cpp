#include <algorithm>
#include "tw/platform.hpp"
#include "tw/win_util.hpp"
#include <dwmapi.h>
#include <winver.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <cwctype>
#include <map>
#include <string>

#ifndef DWMWA_CLOAKED
#define DWMWA_CLOAKED 14
#endif

namespace tw {
namespace {

std::wstring lower(std::wstring s) {
  for (auto& c : s) c = static_cast<wchar_t>(std::towlower(c));
  return s;
}

std::wstring image_path(DWORD pid) {
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!h) return {};
  wchar_t buf[MAX_PATH * 4];
  DWORD len = static_cast<DWORD>(sizeof(buf) / sizeof(buf[0]));
  std::wstring out;
  if (QueryFullProcessImageNameW(h, 0, buf, &len)) out.assign(buf, len);
  CloseHandle(h);
  return out;
}

std::wstring base_name(const std::wstring& path) {
  size_t p = path.find_last_of(L"\\/");
  return p == std::wstring::npos ? path : path.substr(p + 1);
}

bool is_app_window(HWND h) {
  if (!IsWindowVisible(h)) return false;
  if (GetWindow(h, GW_OWNER) != nullptr) return false;
  LONG ex = GetWindowLongW(h, GWL_EXSTYLE);
  if ((ex & WS_EX_TOOLWINDOW) && !(ex & WS_EX_APPWINDOW)) return false;
  if (GetWindowTextLengthW(h) == 0) return false;
  DWORD cloaked = 0;
  if (SUCCEEDED(DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked != 0) return false;
  return true;
}

std::map<std::string, std::wstring>& path_cache() {
  static std::map<std::string, std::wstring> cache;
  return cache;
}

std::wstring version_string(const std::wstring& path, const wchar_t* key) {
  DWORD handle = 0;
  DWORD size = GetFileVersionInfoSizeW(path.c_str(), &handle);
  if (!size) return {};
  std::vector<char> data(size);
  if (!GetFileVersionInfoW(path.c_str(), 0, size, data.data())) return {};
  struct Lang {
    WORD lang;
    WORD page;
  }* tr = nullptr;
  UINT len = 0;
  if (!VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation", reinterpret_cast<LPVOID*>(&tr), &len) || len < sizeof(Lang)) return {};
  wchar_t sub[96];
  swprintf(sub, 96, L"\\StringFileInfo\\%04x%04x\\%ls", tr->lang, tr->page, key);
  wchar_t* val = nullptr;
  UINT vlen = 0;
  if (!VerQueryValueW(data.data(), sub, reinterpret_cast<LPVOID*>(&val), &vlen) || !val || !vlen) return {};
  return std::wstring(val);
}

struct EnumContext {
  HWND foreground;
  std::vector<AppSample>* out;
};

BOOL CALLBACK enum_windows(HWND h, LPARAM lparam) {
  auto* ctx = reinterpret_cast<EnumContext*>(lparam);
  if (!is_app_window(h)) return TRUE;

  DWORD pid = 0;
  GetWindowThreadProcessId(h, &pid);
  std::wstring path = image_path(pid);
  if (path.empty()) return TRUE;

  State state = State::Open;
  if (h == ctx->foreground) state = State::Focused;
  else if (IsIconic(h)) state = State::Minimized;

  std::string key = to_utf8(lower(base_name(path)));
  path_cache().emplace(key, path);
  ctx->out->push_back({key, state});
  return TRUE;
}

class WinProbe : public IProbe {
public:
  explicit WinProbe(bool include_system) : include_system_(include_system) {
    wchar_t buf[MAX_PATH];
    UINT n = GetWindowsDirectoryW(buf, MAX_PATH);
    if (n > 0 && n < MAX_PATH) windows_dir_ = lower(std::wstring(buf, n)) + L"\\";
  }

  std::vector<AppSample> sample() override {
    std::vector<AppSample> out;

    HWND fg = GetForegroundWindow();
    EnumContext ctx{fg ? GetAncestor(fg, GA_ROOTOWNER) : nullptr, &out};
    EnumWindows(enum_windows, reinterpret_cast<LPARAM>(&ctx));

    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap != INVALID_HANDLE_VALUE) {
      PROCESSENTRY32W pe;
      pe.dwSize = sizeof(pe);
      if (Process32FirstW(snap, &pe)) {
        do {
          if (pe.th32ProcessID == 0 || pe.th32ProcessID == 4) continue;
          std::wstring path = image_path(pe.th32ProcessID);
          if (path.empty()) continue;
          std::wstring low = lower(path);
          if (!include_system_ && !windows_dir_.empty() && low.compare(0, windows_dir_.size(), windows_dir_) == 0) continue;
          std::string key = to_utf8(base_name(low));
          path_cache().emplace(key, path);
          out.push_back({key, State::Background});
        } while (Process32NextW(snap, &pe));
      }
      CloseHandle(snap);
    }
    return out;
  }

  std::string display_name(const std::string& app) override {
    auto it = path_cache().find(app);
    if (it == path_cache().end()) return {};
    std::wstring name = version_string(it->second, L"FileDescription");
    if (name.empty()) name = version_string(it->second, L"ProductName");
    while (!name.empty() && std::iswspace(name.back())) name.pop_back();
    return to_utf8(name);
  }

  std::string exe_path(const std::string& app) override {
    auto it = path_cache().find(app);
    return it == path_cache().end() ? std::string() : to_utf8(it->second);
  }

  bool supports_metrics() const override { return true; }

  std::vector<ProcSnap> proc_snapshot() override {
    std::vector<ProcSnap> out;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return out;
    PROCESSENTRY32W pe;
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
      do {
        if (pe.th32ProcessID == 0 || pe.th32ProcessID == 4) continue;
        HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
        if (!h) continue;
        wchar_t buf[MAX_PATH * 4];
        DWORD len = static_cast<DWORD>(sizeof(buf) / sizeof(buf[0]));
        FILETIME created{}, exited{}, kernel{}, user{};
        bool ok = QueryFullProcessImageNameW(h, 0, buf, &len) && GetProcessTimes(h, &created, &exited, &kernel, &user);
        if (ok) {
          std::wstring low = lower(std::wstring(buf, len));
          if (include_system_ || windows_dir_.empty() || low.compare(0, windows_dir_.size(), windows_dir_) != 0) {
            auto u64 = [](const FILETIME& f) { return (static_cast<unsigned long long>(f.dwHighDateTime) << 32) | f.dwLowDateTime; };
            ProcSnap p;
            p.pid = pe.th32ProcessID;
            p.stamp = static_cast<long long>(u64(created));
            p.app = to_utf8(base_name(low));
            p.cpu_ms = static_cast<long long>((u64(kernel) + u64(user)) / 10000ULL);
            PROCESS_MEMORY_COUNTERS_EX mc{};
            mc.cb = sizeof(mc);
            if (GetProcessMemoryInfo(h, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&mc), sizeof(mc))) {
              unsigned long long priv = std::min<unsigned long long>(mc.PrivateUsage, mc.WorkingSetSize);
              unsigned long long peak = std::min<unsigned long long>(mc.PeakPagefileUsage, mc.PeakWorkingSetSize);
              if (peak < priv) peak = priv;
              p.rss_kb = static_cast<long long>(priv / 1024);
              p.peak_kb = static_cast<long long>(peak / 1024);
            }
            IO_COUNTERS io{};
            if (GetProcessIoCounters(h, &io)) {
              p.io_read = static_cast<long long>(io.ReadTransferCount);
              p.io_write = static_cast<long long>(io.WriteTransferCount);
            }
            out.push_back(std::move(p));
          }
        }
        CloseHandle(h);
      } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return out;
  }

  SysStat sys_stat() override {
    SysStat st;
    MEMORYSTATUSEX ms{};
    ms.dwLength = sizeof(ms);
    if (GlobalMemoryStatusEx(&ms)) {
      st.ram_total_kb = static_cast<long long>(ms.ullTotalPhys / 1024);
      st.ram_avail_kb = static_cast<long long>(ms.ullAvailPhys / 1024);
      st.valid = true;
    }
    DWORD mask = GetLogicalDrives();
    for (int i = 0; i < 26; ++i) {
      if (!(mask & (1u << i))) continue;
      wchar_t root[4] = {static_cast<wchar_t>(L'A' + i), L':', L'\\', 0};
      if (GetDriveTypeW(root) != DRIVE_FIXED) continue;
      ULARGE_INTEGER avail{}, total{}, freeb{};
      if (!GetDiskFreeSpaceExW(root, &avail, &total, &freeb)) continue;
      DiskStat d;
      d.mount = std::string(1, static_cast<char>('A' + i)) + ":";
      d.total_kb = static_cast<long long>(total.QuadPart / 1024ULL);
      d.free_kb = static_cast<long long>(freeb.QuadPart / 1024ULL);
      st.disks.push_back(std::move(d));
    }
    return st;
  }

private:
  bool include_system_;
  std::wstring windows_dir_;
};

}

std::unique_ptr<IProbe> make_native_probe(const ProbeOptions& options) {
  return std::make_unique<WinProbe>(options.include_system);
}

}
