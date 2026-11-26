#include <cstddef>
#include <algorithm>
#include "tw/platform.hpp"
#include "tw/win_helpers.hpp"
#include "tw/win_util.hpp"
#include <dwmapi.h>
#include <winver.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <cwctype>
#include <chrono>
#include <ctime>
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

struct UwpChildSearch {
  DWORD outer_pid;
  std::wstring core_path;
  std::wstring any_path;
};

BOOL CALLBACK find_uwp_child(HWND ch, LPARAM lparam) {
  auto* s = reinterpret_cast<UwpChildSearch*>(lparam);
  DWORD cpid = 0;
  GetWindowThreadProcessId(ch, &cpid);
  if (cpid == 0 || cpid == s->outer_pid) return TRUE;
  std::wstring cpath = image_path(cpid);
  if (cpath.empty()) return TRUE;
  if (should_unwrap_uwp_host(to_utf8(lower(base_name(cpath))))) return TRUE;
  wchar_t cls[64]{};
  GetClassNameW(ch, cls, 64);
  if (wcscmp(cls, L"Windows.UI.Core.CoreWindow") == 0) {
    s->core_path = cpath;
    return FALSE;
  }
  if (s->any_path.empty()) s->any_path = cpath;
  return TRUE;
}

BOOL CALLBACK enum_windows(HWND h, LPARAM lparam) {
  auto* ctx = reinterpret_cast<EnumContext*>(lparam);
  if (!is_app_window(h)) return TRUE;

  DWORD pid = 0;
  GetWindowThreadProcessId(h, &pid);
  std::wstring path = image_path(pid);
  if (path.empty()) return TRUE;

  std::string key = to_utf8(lower(base_name(path)));
  if (should_unwrap_uwp_host(key)) {
    UwpChildSearch search{pid, {}, {}};
    EnumChildWindows(h, find_uwp_child, reinterpret_cast<LPARAM>(&search));
    std::wstring resolved = !search.core_path.empty() ? search.core_path : search.any_path;
    if (!resolved.empty()) {
      path = resolved;
      key = to_utf8(lower(base_name(path)));
    }
  }

  State state = State::Open;
  if (h == ctx->foreground) state = State::Focused;
  else if (IsIconic(h)) state = State::Minimized;

  path_cache().emplace(key, path);
  ctx->out->push_back({key, state});
  return TRUE;
}


namespace {

struct NtUnicode {
  USHORT length;
  USHORT maximum;
  PWSTR buffer;
};

struct NtProcessInfo {
  ULONG next;
  ULONG threads;
  LARGE_INTEGER working_set_private;
  ULONG hard_faults;
  ULONG threads_high;
  ULONGLONG cycle_time;
  LARGE_INTEGER create_time;
  LARGE_INTEGER user_time;
  LARGE_INTEGER kernel_time;
  NtUnicode image_name;
  LONG base_priority;
  HANDLE pid;
  HANDLE parent_pid;
  ULONG handles;
  ULONG session;
  ULONG_PTR key;
  SIZE_T peak_virtual;
  SIZE_T virtual_size;
  ULONG page_faults;
  SIZE_T peak_working_set;
  SIZE_T working_set;
  SIZE_T quota_peak_paged;
  SIZE_T quota_paged;
  SIZE_T quota_peak_nonpaged;
  SIZE_T quota_nonpaged;
  SIZE_T pagefile;
  SIZE_T peak_pagefile;
  SIZE_T private_pages;
  LARGE_INTEGER read_ops;
  LARGE_INTEGER write_ops;
  LARGE_INTEGER other_ops;
  LARGE_INTEGER read_bytes;
  LARGE_INTEGER write_bytes;
  LARGE_INTEGER other_bytes;
};

using NtQuerySystemInformationFn = LONG(NTAPI*)(ULONG, PVOID, ULONG, PULONG);

bool nt_process_snapshot(std::vector<ProcSnap>& out) {
  static_assert(sizeof(void*) == 8 && offsetof(NtProcessInfo, pid) == 80 && offsetof(NtProcessInfo, read_bytes) == 232, "unexpected SYSTEM_PROCESS_INFORMATION layout");
  static NtQuerySystemInformationFn query = reinterpret_cast<NtQuerySystemInformationFn>(
      reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQuerySystemInformation")));
  if (!query) return false;
  static std::vector<unsigned char> buffer(1 << 20);
  ULONG need = 0;
  LONG status = 0;
  for (int attempt = 0; attempt < 6; ++attempt) {
    status = query(5, buffer.data(), static_cast<ULONG>(buffer.size()), &need);
    if (status >= 0) break;
    if (static_cast<ULONG>(status) != 0xC0000004UL) return false;
    buffer.resize(std::max<size_t>(buffer.size() * 2, static_cast<size_t>(need) + (256 << 10)));
  }
  if (status < 0) return false;
  FILETIME now_ft{};
  GetSystemTimeAsFileTime(&now_ft);
  long long now100 = static_cast<long long>((static_cast<unsigned long long>(now_ft.dwHighDateTime) << 32) | now_ft.dwLowDateTime);
  size_t offset = 0;
  for (;;) {
    if (offset + sizeof(NtProcessInfo) > buffer.size()) break;
    const NtProcessInfo* p = reinterpret_cast<const NtProcessInfo*>(buffer.data() + offset);
    unsigned long long pid = reinterpret_cast<unsigned long long>(p->pid);
    if (pid != 0 && pid != 4 && p->image_name.buffer && p->image_name.length > 0) {
      std::wstring name(p->image_name.buffer, p->image_name.length / sizeof(wchar_t));
      ProcSnap s;
      s.pid = static_cast<long long>(pid);
      s.stamp = p->create_time.QuadPart;
      s.app = to_utf8(lower(name));
      s.cpu_ms = (p->user_time.QuadPart + p->kernel_time.QuadPart) / 10000;
      unsigned long long priv = static_cast<unsigned long long>(p->working_set_private.QuadPart);
      if (priv == 0 || priv > p->working_set) priv = std::min<unsigned long long>(p->private_pages, p->working_set);
      unsigned long long peak = std::min<unsigned long long>(p->peak_pagefile, p->peak_working_set);
      if (peak < priv) peak = priv;
      s.rss_kb = static_cast<long long>(priv / 1024);
      s.peak_kb = static_cast<long long>(peak / 1024);
      s.io_read = p->read_bytes.QuadPart;
      s.io_write = p->write_bytes.QuadPart;
      s.age_ms = p->create_time.QuadPart > 0 && now100 >= p->create_time.QuadPart ? (now100 - p->create_time.QuadPart) / 10000 : -1;
      out.push_back(std::move(s));
    }
    if (p->next == 0) break;
    offset += p->next;
  }
  return true;
}

}

class WinProbe : public IProbe {
public:
  explicit WinProbe(bool include_system) : include_system_(include_system) {
    wchar_t buf[MAX_PATH];
    UINT n = GetWindowsDirectoryW(buf, MAX_PATH);
    if (n > 0 && n < MAX_PATH) windows_dir_ = lower(std::wstring(buf, n)) + L"\\";
    last_wall_ = static_cast<long long>(std::time(nullptr));
    last_unbiased_100ns_ = read_unbiased_100ns();
    last_steady_ = std::chrono::steady_clock::now();
  }

  std::vector<SysEvent> take_sys_events() override {
    std::vector<SysEvent> out;
    out.swap(pending_events_);
    return out;
  }

  std::vector<AppSample> sample() override {
    update_power_lock();
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

  long long idle_ms() override {
    LASTINPUTINFO li{};
    li.cbSize = sizeof(li);
    if (!GetLastInputInfo(&li)) return -1;
    return static_cast<long long>(static_cast<DWORD>(GetTickCount() - li.dwTime));
  }

  std::vector<ProcSnap> proc_snapshot() override {
    std::vector<ProcSnap> out;
    if (nt_process_snapshot(out)) return out;
    out.clear();
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
    BatteryStat bat = battery_stat();
    if (bat.valid) {
      st.battery_pct = bat.pct;
      st.battery_charging = bat.charging;
      st.valid = true;
    }
    return st;
  }

  BatteryStat battery_stat() override {
    BatteryStat bat;
    SYSTEM_POWER_STATUS sps{};
    if (GetSystemPowerStatus(&sps) && is_valid_battery_status(sps.ACLineStatus, sps.BatteryFlag, sps.BatteryLifePercent)) {
      bat.pct = static_cast<int>(sps.BatteryLifePercent);
      bat.charging = (sps.ACLineStatus == 1 || (sps.BatteryFlag & 8) != 0) ? 1 : 0;
      bat.valid = true;
    }
    return bat;
  }

private:
  static long long read_unbiased_100ns() {
    using QueryUnbiasedFn = BOOL(WINAPI*)(PULONGLONG);
    static QueryUnbiasedFn fn = reinterpret_cast<QueryUnbiasedFn>(
        reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "QueryUnbiasedInterruptTime")));
    if (fn) {
      ULONGLONG t = 0;
      if (fn(&t)) return static_cast<long long>(t);
    }
    return -1;
  }

  static bool query_screen_locked() {
    using WtsQueryFn = BOOL(WINAPI*)(HANDLE, DWORD, int, LPWSTR*, DWORD*);
    using WtsFreeFn = VOID(WINAPI*)(PVOID);
    static HMODULE wts = LoadLibraryW(L"wtsapi32.dll");
    static WtsQueryFn wts_query = wts ? reinterpret_cast<WtsQueryFn>(reinterpret_cast<void*>(GetProcAddress(wts, "WTSQuerySessionInformationW"))) : nullptr;
    static WtsFreeFn wts_free = wts ? reinterpret_cast<WtsFreeFn>(reinterpret_cast<void*>(GetProcAddress(wts, "WTSFreeMemory"))) : nullptr;
    if (wts_query && wts_free) {
      LPWSTR buf = nullptr;
      DWORD bytes = 0;
      if (wts_query(nullptr, static_cast<DWORD>(-1), 25, &buf, &bytes) && buf && bytes >= 16) {
        const DWORD level = *reinterpret_cast<const DWORD*>(buf);
        if (level == 1 && bytes >= 24) {
          const LONG flags = *reinterpret_cast<const LONG*>(reinterpret_cast<const unsigned char*>(buf) + 16);
          wts_free(buf);
          if (flags == 0) return true;
          if (flags == 1) return false;
        } else {
          wts_free(buf);
        }
      }
    }
    HDESK d = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!d) return GetLastError() == ERROR_ACCESS_DENIED;
    wchar_t name[64]{};
    DWORD need = 0;
    bool is_lock = false;
    if (GetUserObjectInformationW(d, UOI_NAME, name, sizeof(name), &need)) {
      is_lock = _wcsicmp(name, L"Winlogon") == 0;
    }
    CloseDesktop(d);
    return is_lock;
  }

  void update_power_lock() {
    long long wall = static_cast<long long>(std::time(nullptr));
    long long unbiased = read_unbiased_100ns();
    auto steady = std::chrono::steady_clock::now();
    if (unbiased >= 0 && last_unbiased_100ns_ >= 0) {
      long long wall_d = wall - last_wall_;
      long long unb_d = (unbiased - last_unbiased_100ns_) / 10000000LL;
      long long sleep_s = wall_d - unb_d;
      if (sleep_s >= 20 && sleep_s < 86400LL * 90) {
        pending_events_.push_back({last_wall_, "sleep", sleep_s * 1000LL, ""});
      }
    } else {
      long long wall_d = wall - last_wall_;
      long long steady_d = std::chrono::duration_cast<std::chrono::seconds>(steady - last_steady_).count();
      long long sleep_s = wall_d - steady_d;
      if (sleep_s >= 20 && sleep_s < 86400LL * 90) {
        pending_events_.push_back({last_wall_, "sleep", sleep_s * 1000LL, ""});
      }
    }
    last_wall_ = wall;
    last_unbiased_100ns_ = unbiased;
    last_steady_ = steady;

    bool is_locked = query_screen_locked();
    if (is_locked && !locked_) {
      locked_ = true;
      lock_start_ = wall;
    } else if (!is_locked && locked_) {
      locked_ = false;
      long long dur_s = wall - lock_start_;
      if (dur_s >= 3 && dur_s < 86400LL * 90) {
        pending_events_.push_back({lock_start_, "lock", dur_s * 1000LL, ""});
      }
    }
  }

  bool include_system_;
  std::wstring windows_dir_;
  long long last_wall_ = 0;
  long long last_unbiased_100ns_ = -1;
  std::chrono::steady_clock::time_point last_steady_;
  bool locked_ = false;
  long long lock_start_ = 0;
  std::vector<SysEvent> pending_events_;
};

}

std::unique_ptr<IProbe> make_native_probe(const ProbeOptions& options) {
  return std::make_unique<WinProbe>(options.include_system);
}

}
