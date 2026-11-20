#include <cmath>
#include <cstdint>
#include <cstdio>
#include <chrono>
#include <filesystem>
#include <algorithm>
#include <fstream>
#include <string>
#include <vector>
#include <thread>
#include "common_win.hpp"
#include "update_win.hpp"
#include <shellapi.h>
#include <dbt.h>
#include "tw/i18n.hpp"

namespace {

using tw::i18n::Key;
using tw::i18n::tr;

#ifndef NIN_BALLOONUSERCLICK
#define NIN_BALLOONUSERCLICK (WM_USER + 5)
#endif

constexpr UINT kTrayMsg = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr int kHotkeyOpen = 1;
constexpr int kHotkeyPause = 2;
constexpr UINT_PTR kTimer = 1;
constexpr UINT kMsgUpdate = WM_APP + 4;
constexpr UINT kMsgBadge = WM_APP + 5;
constexpr UINT kCmdUpdate = 1005;
constexpr ULONGLONG kTriggerGapMs = 20ULL * 60 * 1000;
constexpr ULONGLONG kRenotifyGapMs = 20ULL * 60 * 1000;
constexpr UINT kWmDisplayChange = 0x007E;
constexpr UINT kWmDeviceChange = 0x0219;
constexpr WPARAM kDeviceArrival = 0x8000;
constexpr WPARAM kDeviceRemoved = 0x8004;
constexpr UINT kWmPowerBroadcast = 0x0218;
constexpr UINT kWmSessionChange = 0x02B1;
constexpr WPARAM kResumeAutomatic = 0x12;
constexpr WPARAM kResumeSuspend = 0x7;
constexpr WPARAM kPowerSettingChange = 0x8013;
constexpr WPARAM kSessionUnlock = 0x8;
const GUID kDisplayState = {0x6fe69556, 0x704a, 0x47a0, {0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47}};
const GUID kMonitorInterface = {0xE6F07B5F, 0xEE97, 0x4A90, {0xB0, 0x76, 0x33, 0xF5, 0x7B, 0xF4, 0xEA, 0xA7}};
const GUID kPowerSource = {0x5d3e9a59, 0xe9d5, 0x4b00, {0xa6, 0xbd, 0xff, 0x34, 0xff, 0x51, 0x65, 0x48}};

struct PowerSetting {
  GUID guid;
  DWORD length;
  UCHAR data[1];
};
constexpr UINT kCmdOpen = 1001;
constexpr UINT kCmdExit = 1002;
constexpr UINT kCmdPause = 1003;
constexpr UINT kCmdRestart = 1004;
constexpr int kMaxCrashes = 3;
constexpr ULONGLONG kCrashWindowMs = 5 * 60 * 1000;
constexpr long long kHangMs = 10000;
constexpr ULONGLONG kStartGraceMs = 8000;

enum class State { Running, Paused, Error };

struct Guard {
  bool background = false;
  HWND hwnd = nullptr;
  UINT taskbar_created = 0;
  HICON icons[5] = {};
  State state = State::Running;
  HANDLE core = nullptr;
  ULONGLONG core_started = 0;
  std::vector<ULONGLONG> crashes;
  HANDLE viewer = nullptr;
  HANDLE clean = nullptr;
  app::Heartbeat beat;
  bool update_pending = false;
  bool update_ready = false;
  std::string update_version;
  HICON badged[5] = {};
  HANDLE check_event = nullptr;
  ULONGLONG renotified = 0;
};

Guard* g = nullptr;

void mark_clean() {
  if (g && g->clean) SetEvent(g->clean);
}

void reload_language() {
  tw::i18n::load(std::filesystem::path(app::data_dir() + L"\\lang"), GetUserDefaultUILanguage());
}

void load_icons(HINSTANCE inst) {
  int n = GetSystemMetrics(SM_CXSMICON);
  for (int i = 1; i <= 4; ++i) {
    HANDLE h = LoadImageW(inst, MAKEINTRESOURCEW(i), IMAGE_ICON, n, n, LR_DEFAULTCOLOR);
    g->icons[i] = h ? static_cast<HICON>(h) : LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
  }
}

int icon_index() {
  switch (g->state) {
    case State::Error: return 4;
    case State::Paused: return 2;
    default: return 1;
  }
}

HICON make_badged(HICON base) {
  int n = GetSystemMetrics(SM_CXSMICON);
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = n;
  bi.bmiHeader.biHeight = -n;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC dc = CreateCompatibleDC(nullptr);
  HBITMAP color = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!color || !bits) {
    DeleteDC(dc);
    return base;
  }
  HGDIOBJ old = SelectObject(dc, color);
  memset(bits, 0, static_cast<size_t>(n) * n * 4);
  DrawIconEx(dc, 0, 0, base, n, n, 0, nullptr, DI_NORMAL);
  GdiFlush();
  uint32_t* px = static_cast<uint32_t*>(bits);
  float r = n * 0.31f;
  float cx = n - r - 0.5f;
  float cy = r + 0.5f;
  for (int y = 0; y < n; ++y) {
    for (int x = 0; x < n; ++x) {
      float dx = x + 0.5f - cx;
      float dy = y + 0.5f - cy;
      float d = std::sqrt(dx * dx + dy * dy);
      if (d > r + 1.2f) continue;
      if (d > r) {
        px[y * n + x] = 0xFF0B0F14;
        continue;
      }
      float ux = dx / r;
      float uy = dy / r;
      bool head = uy >= -0.62f && uy <= 0.05f && std::fabs(ux) <= (uy + 0.62f) * 0.95f;
      bool stem = uy > 0.0f && uy <= 0.58f && std::fabs(ux) <= 0.2f;
      px[y * n + x] = (head || stem) ? 0xFFFFFFFF : 0xFF1E88E5;
    }
  }
  HBITMAP mask = CreateBitmap(n, n, 1, 1, nullptr);
  ICONINFO ii{};
  ii.fIcon = TRUE;
  ii.hbmMask = mask;
  ii.hbmColor = color;
  HICON out = CreateIconIndirect(&ii);
  SelectObject(dc, old);
  DeleteObject(mask);
  DeleteObject(color);
  DeleteDC(dc);
  return out ? out : base;
}

HICON current_icon() {
  int i = icon_index();
  if (!g->update_ready) return g->icons[i];
  if (!g->badged[i]) g->badged[i] = make_badged(g->icons[i]);
  return g->badged[i];
}

std::wstring tooltip() {
  std::wstring t = L"Wolium";
  if (g->state == State::Paused) t += std::wstring(L" (") + tr(Key::TipPaused) + L")";
  if (g->state == State::Error) t += std::wstring(L" (") + tr(Key::TipError) + L")";
  if (g->update_ready) t += std::wstring(L" - ") + tr(Key::TipUpdate);
  return t;
}

NOTIFYICONDATAW base_nid() {
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = g->hwnd;
  nid.uID = kTrayId;
  return nid;
}

void tray_update(bool add) {
  NOTIFYICONDATAW nid = base_nid();
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = kTrayMsg;
  nid.hIcon = current_icon();
  std::wstring tip = tooltip();
  wcsncpy_s(nid.szTip, tip.c_str(), _TRUNCATE);
  Shell_NotifyIconW(add ? NIM_ADD : NIM_MODIFY, &nid);
  if (add) {
    nid.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &nid);
  }
}

void tray_remove() {
  NOTIFYICONDATAW nid = base_nid();
  Shell_NotifyIconW(NIM_DELETE, &nid);
}

void notify(Key title, Key body, DWORD flags) {
  NOTIFYICONDATAW nid = base_nid();
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = flags;
  wcsncpy_s(nid.szInfoTitle, tr(title), _TRUNCATE);
  wcsncpy_s(nid.szInfo, tr(body), _TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY, &nid);
}

void notify_update(const std::string& version) {
  std::wstring body = tr(Key::NotifUpdateBody);
  std::wstring v(version.begin(), version.end());
  size_t at = body.find(L"{version}");
  if (at != std::wstring::npos) body.replace(at, 9, v);
  NOTIFYICONDATAW nid = base_nid();
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = NIIF_INFO;
  wcsncpy_s(nid.szInfoTitle, tr(Key::NotifUpdateTitle), _TRUNCATE);
  wcsncpy_s(nid.szInfo, body.c_str(), _TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY, &nid);
  g->update_pending = true;
}

void write_update_status(const std::string& current, const std::string& latest, const char* note) {
  SYSTEMTIME t;
  GetLocalTime(&t);
  char when[32];
  snprintf(when, sizeof(when), "%04d-%02d-%02d %02d:%02d", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute);
  std::string text = std::string(when) + " | " + (current.empty() ? "?" : current) + " -> " + (latest.empty() ? "?" : latest) + " | " + note;
  FILE* f = nullptr;
  if (_wfopen_s(&f, app::userdata(L"update.status").c_str(), L"wb") == 0 && f) {
    fwrite(text.data(), 1, text.size(), f);
    fclose(f);
  }
}

std::string read_small(const std::wstring& path) {
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return "";
  char buf[64];
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  return app::trim(std::string(buf, n));
}

void write_small(const std::wstring& path, const std::string& text) {
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"wb") == 0 && f) {
    fwrite(text.data(), 1, text.size(), f);
    fclose(f);
  }
}

bool older_than_hours(const std::wstring& path, int hours) {
  std::error_code ec;
  auto t = std::filesystem::last_write_time(std::filesystem::path(path), ec);
  if (ec) return true;
  return std::filesystem::file_time_type::clock::now() - t >= std::chrono::hours(hours);
}

void launch_viewer();

void post_badge(HWND hwnd, bool ready, const std::string& version) {
  PostMessageW(hwnd, kMsgBadge, ready ? 1 : 0, reinterpret_cast<LPARAM>(new std::string(version)));
}

std::wstring temp_installer() {
  wchar_t tmp[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, tmp);
  return std::wstring(tmp, n) + L"WoliumSetup_update.exe";
}

bool installer_ready(const std::string& latest) {
  const std::wstring path = temp_installer();
  std::string marker = read_small(app::userdata(L"update.ready"));
  std::error_code ec;
  return marker.substr(0, marker.find('\n')) == latest && std::filesystem::exists(path, ec) && std::filesystem::file_size(path, ec) > 1024 * 1024;
}

bool predownload(const std::string& latest) {
  if (installer_ready(latest)) return true;
  const std::wstring path = temp_installer();
  DeleteFileW(app::userdata(L"update.ready").c_str());
  if (!app::http_download(L"https://github.com/arturwo1/trackwolium/releases/latest/download/WoliumSetup.exe", path, 1024 * 1024)) return false;
  std::string text = latest + "\n";
  for (wchar_t c : path) text += c < 128 ? static_cast<char>(c) : '?';
  std::ofstream(std::filesystem::path(app::userdata(L"update.ready")), std::ios::binary) << text;
  return true;
}

bool apply_silently(const std::string& latest) {
  const std::wstring path = temp_installer();
  write_small(app::userdata(L"update_silent"), latest);
  std::wstring cmd = L"\"" + path + L"\" --silent \"" + app::exe_dir() + L"\" --background";
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(path.c_str(), &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr, nullptr, &si, &pi)) {
    DeleteFileW(app::userdata(L"update_silent").c_str());
    return false;
  }
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return true;
}

int check_once(HWND hwnd) {
  if (!app::consent_given()) {
    write_update_status("", "", "no consent");
    return 1;
  }
  if (app::flag(L"noupdates")) {
    write_update_status("", "", "updates disabled");
    post_badge(hwnd, false, "");
    return 1;
  }
  std::string current = app::installed_version();
  std::string latest = app::latest_version();
  if (latest.empty()) {
    write_update_status(current, latest, "check failed");
    return 0;
  }
  if (current.empty()) {
    write_update_status(current, latest, "installed version unknown");
    return 1;
  }
  if (app::compare_versions(current, latest) >= 0) {
    write_update_status(current, latest, "up to date");
    post_badge(hwnd, false, "");
    DeleteFileW(app::userdata(L"update.ready").c_str());
    DeleteFileW(temp_installer().c_str());
    return 1;
  }
  if (!predownload(latest)) {
    write_update_status(current, latest, "download failed");
    post_badge(hwnd, true, latest);
    return 0;
  }
  if (app::do_not_disturb()) {
    write_update_status(current, latest, "ready, deferred (do not disturb)");
    post_badge(hwnd, true, latest);
    return 2;
  }
  if (!app::ui_window_open()) {
    if (apply_silently(latest)) {
      write_update_status(current, latest, "installing silently");
      return 1;
    }
    write_update_status(current, latest, "silent install failed");
  } else {
    write_update_status(current, latest, "ready, waiting for the window");
  }
  post_badge(hwnd, true, latest);
  const std::wstring notified = app::userdata(L"update_notified");
  std::string seen = read_small(notified);
  bool acted = read_small(app::userdata(L"update_acted")) == latest;
  if (seen != latest || (!acted && older_than_hours(notified, 2))) {
    write_small(notified, latest);
    PostMessageW(hwnd, kMsgUpdate, 0, reinterpret_cast<LPARAM>(new std::string(latest)));
  }
  return 1;
}

void wait_for_traffic() {
  for (int i = 0; i < 10; ++i) {
    if (app::traffic_flowing()) return;
    Sleep(30000);
  }
}

void update_loop(HWND hwnd) {
  WaitForSingleObject(g->check_event, 20000);
  int failures = 0;
  ULONGLONG last = 0;
  bool triggered = false;
  for (;;) {
    ULONGLONG now = GetTickCount64();
    bool skip = triggered && failures == 0 && last != 0 && now - last < kTriggerGapMs;
    DWORD wait = 6 * 60 * 60 * 1000;
    if (skip) {
      wait = static_cast<DWORD>(kTriggerGapMs - (now - last));
    } else {
      if (!triggered) wait_for_traffic();
      if (app::unmetered_connection()) {
        int result = check_once(hwnd);
        last = GetTickCount64();
        failures = result == 0 ? (failures < 4 ? failures + 1 : failures) : 0;
        if (result == 0) wait = (60 * 1000) << (failures - 1);
        if (result == 2) wait = 5 * 60 * 1000;
      } else {
        wait = 10 * 60 * 1000;
      }
    }
    DWORD r = WaitForSingleObject(g->check_event, wait);
    triggered = r == WAIT_OBJECT_0;
    if (triggered) {
      Sleep(8000);
      ResetEvent(g->check_event);
    }
  }
}

void notify_updated() {
  std::wstring marker = app::userdata(L"update_silent");
  std::string version = read_small(marker);
  if (version.empty()) return;
  DeleteFileW(marker.c_str());
  if (app::installed_version() != version) return;
  DeleteFileW(app::userdata(L"update.ready").c_str());
  DeleteFileW(temp_installer().c_str());
  std::wstring body = tr(Key::NotifUpdatedBody);
  std::wstring v(version.begin(), version.end());
  size_t at = body.find(L"{version}");
  if (at != std::wstring::npos) body.replace(at, 9, v);
  NOTIFYICONDATAW nid = base_nid();
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = NIIF_INFO;
  wcsncpy_s(nid.szInfoTitle, tr(Key::NotifUpdatedTitle), _TRUNCATE);
  wcsncpy_s(nid.szInfo, body.c_str(), _TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY, &nid);
}

void network_watch() {
  HMODULE lib = LoadLibraryW(L"iphlpapi.dll");
  if (!lib) return;
  using Notify = DWORD(WINAPI*)(HANDLE*, OVERLAPPED*);
  auto notify = reinterpret_cast<Notify>(reinterpret_cast<void*>(GetProcAddress(lib, "NotifyAddrChange")));
  if (!notify) return;
  for (;;) {
    if (notify(nullptr, nullptr) != NO_ERROR) {
      Sleep(60000);
      continue;
    }
    SetEvent(g->check_event);
  }
}

void register_triggers(HWND hwnd) {
  HMODULE user = GetModuleHandleW(L"user32.dll");
  using Register = HANDLE(WINAPI*)(HANDLE, LPCGUID, DWORD);
  auto reg = user ? reinterpret_cast<Register>(reinterpret_cast<void*>(GetProcAddress(user, "RegisterPowerSettingNotification"))) : nullptr;
  if (reg) {
    reg(hwnd, &kDisplayState, 0);
    reg(hwnd, &kPowerSource, 0);
  }
  DEV_BROADCAST_DEVICEINTERFACE_W filter{};
  filter.dbcc_size = sizeof(filter);
  filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
  filter.dbcc_classguid = kMonitorInterface;
  RegisterDeviceNotificationW(hwnd, &filter, DEVICE_NOTIFY_WINDOW_HANDLE);
  HMODULE wts = LoadLibraryW(L"wtsapi32.dll");
  using Session = BOOL(WINAPI*)(HWND, DWORD);
  auto session = wts ? reinterpret_cast<Session>(reinterpret_cast<void*>(GetProcAddress(wts, "WTSRegisterSessionNotification"))) : nullptr;
  if (session) session(hwnd, 0);
}

void request_update() {
  g->update_pending = false;
  write_small(app::userdata(L"update_acted"), read_small(app::userdata(L"update_notified")));
  std::ofstream(std::filesystem::path(app::userdata(L"update_request"))) << "1";
  launch_viewer();
}

void set_state(State s) {
  g->state = s;
  tray_update(false);
}

bool start_core() {
  if (g->core) {
    CloseHandle(g->core);
    g->core = nullptr;
  }
  std::wstring exe = app::sibling(L"trackwolium-core.exe");
  std::wstring cmd = L"\"" + exe + L"\"";
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) return false;
  CloseHandle(pi.hThread);
  g->core = pi.hProcess;
  g->core_started = GetTickCount64();
  return true;
}

void attach_or_start_core() {
  std::ifstream in(std::filesystem::path(app::data_dir() + L"\\core.pid"));
  DWORD pid = 0;
  if (in >> pid && pid != 0) {
    HANDLE h = OpenProcess(SYNCHRONIZE | PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (h) {
      wchar_t buf[MAX_PATH * 2];
      DWORD n = static_cast<DWORD>(sizeof(buf) / sizeof(buf[0]));
      std::wstring want = app::sibling(L"trackwolium-core.exe");
      if (QueryFullProcessImageNameW(h, 0, buf, &n) && _wcsicmp(std::wstring(buf, n).c_str(), want.c_str()) == 0 &&
          WaitForSingleObject(h, 0) == WAIT_TIMEOUT) {
        g->core = h;
        g->core_started = GetTickCount64();
        return;
      }
      CloseHandle(h);
    }
  }
  start_core();
}

void stop_core() {
  if (!g->core) return;
  HANDLE ev = OpenEventW(EVENT_MODIFY_STATE, FALSE, app::kCoreStopEvent);
  if (ev) {
    SetEvent(ev);
    CloseHandle(ev);
  }
  if (WaitForSingleObject(g->core, 4000) == WAIT_TIMEOUT) TerminateProcess(g->core, 1);
  CloseHandle(g->core);
  g->core = nullptr;
}

void kill_core() {
  if (!g->core) return;
  TerminateProcess(g->core, 1);
  WaitForSingleObject(g->core, 2000);
  CloseHandle(g->core);
  g->core = nullptr;
}

void restart_from_error() {
  g->crashes.clear();
  start_core();
  set_state(app::paused() ? State::Paused : State::Running);
}

void on_core_died() {
  if (g->core) {
    CloseHandle(g->core);
    g->core = nullptr;
  }
  ULONGLONG now = GetTickCount64();
  g->crashes.erase(std::remove_if(g->crashes.begin(), g->crashes.end(), [&](ULONGLONG t) { return now - t > kCrashWindowMs; }), g->crashes.end());
  g->crashes.push_back(now);
  if (static_cast<int>(g->crashes.size()) < kMaxCrashes && start_core()) {
    notify(Key::NotifRestartedTitle, Key::NotifRestartedBody, NIIF_WARNING);
    return;
  }
  set_state(State::Error);
  notify(Key::NotifDeadTitle, Key::NotifDeadBody, NIIF_ERROR);
}

void launch_viewer() {
  if (g->viewer && WaitForSingleObject(g->viewer, 0) == WAIT_TIMEOUT) return;
  if (g->viewer) {
    CloseHandle(g->viewer);
    g->viewer = nullptr;
  }
  std::wstring exe = app::sibling(L"wolium.exe");
  std::wstring cmd = L"\"" + exe + L"\"";
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
    CloseHandle(pi.hThread);
    g->viewer = pi.hProcess;
  }
}

void open_or_raise_viewer() {
  if (!g->viewer || WaitForSingleObject(g->viewer, 0) != WAIT_TIMEOUT) {
    launch_viewer();
    return;
  }
  DWORD want = GetProcessId(g->viewer);
  HWND h = nullptr;
  while ((h = FindWindowExW(nullptr, h, L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr)) != nullptr) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid != want) continue;
    ShowWindow(h, IsIconic(h) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(h);
    return;
  }
}

void toggle_pause() {
  std::wstring flag = app::userdata(L"paused");
  if (app::exists(flag)) {
    DeleteFileW(flag.c_str());
    set_state(State::Running);
  } else {
    std::ofstream(std::filesystem::path(flag)) << "1";
    set_state(State::Paused);
  }
}

void sync_pause_state() {
  if (g->state == State::Error) return;
  State want = app::paused() ? State::Paused : State::Running;
  if (g->state != want) set_state(want);
}

void show_menu() {
  sync_pause_state();
  reload_language();
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kCmdOpen, tr(Key::TrayOpen));
  AppendMenuW(menu, MF_STRING, kCmdPause, g->state == State::Paused ? tr(Key::TrayResume) : tr(Key::TrayPause));
  if (g->state == State::Error) AppendMenuW(menu, MF_STRING, kCmdRestart, tr(Key::TrayRestart));
  if (g->update_ready) {
    std::wstring label = std::wstring(tr(Key::TrayUpdate)) + L" (" + std::wstring(g->update_version.begin(), g->update_version.end()) + L")";
    AppendMenuW(menu, MF_STRING, kCmdUpdate, label.c_str());
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdExit, tr(Key::TrayExit));
  SetMenuDefaultItem(menu, kCmdOpen, FALSE);
  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(g->hwnd);
  UINT cmd = static_cast<UINT>(TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0, g->hwnd, nullptr));
  PostMessageW(g->hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (cmd == kCmdOpen) launch_viewer();
  else if (cmd == kCmdPause) toggle_pause();
  else if (cmd == kCmdRestart) restart_from_error();
  else if (cmd == kCmdUpdate) request_update();
  else if (cmd == kCmdExit) {
    mark_clean();
    DestroyWindow(g->hwnd);
  }
}

void on_timer() {
  if (!app::consent_given()) {
    mark_clean();
    DestroyWindow(g->hwnd);
    return;
  }
  sync_pause_state();
  if (g->state == State::Error) return;
  if (!g->core) {
    on_core_died();
    return;
  }
  if (WaitForSingleObject(g->core, 0) == WAIT_OBJECT_0) {
    on_core_died();
    return;
  }
  if (GetTickCount64() - g->core_started > kStartGraceMs) {
    long long age = g->beat.age_ms();
    if (age < 0 || age > kHangMs) {
      kill_core();
      on_core_died();
    }
  }
}

void screen_returned() {
  if (!g->check_event) return;
  SetEvent(g->check_event);
  if (!g->update_ready || g->update_version.empty()) return;
  if (g->state == State::Error) return;
  if (read_small(app::userdata(L"update_acted")) == g->update_version) return;
  ULONGLONG now = GetTickCount64();
  if (g->renotified != 0 && now - g->renotified < kRenotifyGapMs) return;
  if (app::do_not_disturb() || app::ui_window_open()) return;
  g->renotified = now;
  notify_update(g->update_version);
}

LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (g) {
    if (msg == kTrayMsg) {
      switch (LOWORD(lp)) {
        case WM_LBUTTONDBLCLK:
          launch_viewer();
          break;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          show_menu();
          break;
        case NIN_BALLOONUSERCLICK:
          if (g->state == State::Error) {
            restart_from_error();
          } else if (g->update_pending || g->update_ready) {
            request_update();
          }
          break;
      }
      return 0;
    }
    if (msg == g->taskbar_created) {
      tray_update(true);
      return 0;
    }
    if (msg == app::kMsgEnsure) {
      if (g->state == State::Error) restart_from_error();
      return 0;
    }
    if (msg == kMsgUpdate) {
      std::string* v = reinterpret_cast<std::string*>(lp);
      if (v) {
        if (g->state != State::Error) notify_update(*v);
        delete v;
      }
      return 0;
    }
    if (msg == kMsgBadge) {
      std::string* v = reinterpret_cast<std::string*>(lp);
      bool ready = wp != 0;
      if (ready != g->update_ready || (v && *v != g->update_version)) {
        g->update_ready = ready;
        g->update_version = v ? *v : std::string();
        tray_update(false);
      }
      delete v;
      return 0;
    }
    if (msg == kWmPowerBroadcast) {
      bool trigger = wp == kResumeAutomatic || wp == kResumeSuspend;
      bool screen = false;
      if (wp == kPowerSettingChange && lp) {
        const PowerSetting* ps = reinterpret_cast<const PowerSetting*>(lp);
        if (ps->length > 0 && IsEqualGUID(ps->guid, kDisplayState)) {
          trigger = true;
          screen = ps->data[0] != 0;
        } else if (ps->length > 0 && IsEqualGUID(ps->guid, kPowerSource)) {
          trigger = true;
        }
      }
      if (screen || wp == kResumeAutomatic || wp == kResumeSuspend) {
        screen_returned();
      } else if (trigger && g->check_event) {
        SetEvent(g->check_event);
      }
      return TRUE;
    }
    if (msg == kWmDisplayChange) {
      screen_returned();
      return 0;
    }
    if (msg == kWmDeviceChange) {
      if (wp == kDeviceArrival || wp == kDeviceRemoved) screen_returned();
      return TRUE;
    }
    if (msg == kWmSessionChange) {
      if (wp == kSessionUnlock) screen_returned();
      return 0;
    }
    if (msg == app::kMsgOpenUi) {
      launch_viewer();
      return 0;
    }
  }
  switch (msg) {
    case WM_TIMER:
      if (wp == kTimer) on_timer();
      return 0;
    case WM_HOTKEY:
      if (g && wp == kHotkeyOpen) open_or_raise_viewer();
      else if (g && wp == kHotkeyPause) toggle_pause();
      return 0;
    case WM_QUERYENDSESSION:
      return TRUE;
    case WM_ENDSESSION:
      if (wp && g) {
        mark_clean();
        stop_core();
      }
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

}

void enable_dark_menus() {
  HMODULE ux = LoadLibraryW(L"uxtheme.dll");
  if (!ux) return;
  using SetMode = int(WINAPI*)(int);
  using Flush = void(WINAPI*)();
  auto set = reinterpret_cast<SetMode>(reinterpret_cast<void*>(GetProcAddress(ux, MAKEINTRESOURCEA(135))));
  auto flush = reinterpret_cast<Flush>(reinterpret_cast<void*>(GetProcAddress(ux, MAKEINTRESOURCEA(136))));
  if (set) set(1);
  if (flush) flush();
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
  enable_dark_menus();
  Guard guard;
  g = &guard;

  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  for (int i = 1; argv && i < argc; ++i) {
    if (std::wstring(argv[i]) == L"--background") guard.background = true;
  }
  if (argv) LocalFree(argv);

  app::migrate_legacy_data();
  if (!app::consent_given()) return 0;

  HANDLE mutex = CreateMutexW(nullptr, TRUE, app::kGuardMutex);
  if (!mutex) return 1;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND other = FindWindowW(app::kGuardClass, nullptr);
    if (other) {
      PostMessageW(other, app::kMsgEnsure, 0, 0);
      if (!guard.background) PostMessageW(other, app::kMsgOpenUi, 0, 0);
    }
    CloseHandle(mutex);
    return 0;
  }

  guard.clean = CreateEventW(nullptr, TRUE, FALSE, app::kGuardCleanEvent);
  if (guard.clean) ResetEvent(guard.clean);
  reload_language();
  WNDCLASSW wc{};
  wc.lpfnWndProc = wnd_proc;
  wc.hInstance = inst;
  wc.lpszClassName = app::kGuardClass;
  if (!RegisterClassW(&wc)) return 1;
  guard.hwnd = CreateWindowExW(0, app::kGuardClass, L"Wolium", 0, 0, 0, 0, 0, nullptr, nullptr, inst, nullptr);
  if (!guard.hwnd) return 1;

  guard.taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  load_icons(inst);
  guard.state = app::paused() ? State::Paused : State::Running;
  attach_or_start_core();
  tray_update(true);
  notify_updated();
  SetTimer(guard.hwnd, kTimer, 1000, nullptr);
  if (!guard.background) launch_viewer();
  guard.check_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  register_triggers(guard.hwnd);
  RegisterHotKey(guard.hwnd, kHotkeyOpen, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'W');
  RegisterHotKey(guard.hwnd, kHotkeyPause, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'P');
  std::thread(update_loop, guard.hwnd).detach();
  std::thread(network_watch).detach();

  MSG m;
  while (GetMessageW(&m, nullptr, 0, 0) > 0) {
    TranslateMessage(&m);
    DispatchMessageW(&m);
  }

  UnregisterHotKey(guard.hwnd, kHotkeyOpen);
  UnregisterHotKey(guard.hwnd, kHotkeyPause);
  KillTimer(guard.hwnd, kTimer);
  tray_remove();
  stop_core();
  if (guard.viewer) CloseHandle(guard.viewer);
  if (guard.clean) CloseHandle(guard.clean);
  CloseHandle(mutex);
  return 0;
}
