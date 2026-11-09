#include <algorithm>
#include <fstream>
#include <string>
#include <vector>
#include "common_win.hpp"
#include <shellapi.h>
#include "tw/i18n.hpp"

namespace {

using tw::i18n::Key;
using tw::i18n::tr;

#ifndef NIN_BALLOONUSERCLICK
#define NIN_BALLOONUSERCLICK (WM_USER + 5)
#endif

constexpr UINT kTrayMsg = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr UINT_PTR kTimer = 1;
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
  bool expect_notice_restart = false;
};

Guard* g = nullptr;

void reload_language() {
  tw::i18n::load(std::filesystem::path(app::exe_dir() + L"\\userdata\\lang"), GetUserDefaultUILanguage());
}

void load_icons(HINSTANCE inst) {
  int n = GetSystemMetrics(SM_CXSMICON);
  for (int i = 1; i <= 4; ++i) {
    HANDLE h = LoadImageW(inst, MAKEINTRESOURCEW(i), IMAGE_ICON, n, n, LR_DEFAULTCOLOR);
    g->icons[i] = h ? static_cast<HICON>(h) : LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
  }
}

HICON current_icon() {
  switch (g->state) {
    case State::Error: return g->icons[4];
    case State::Paused: return g->icons[2];
    default: return g->icons[1];
  }
}

std::wstring tooltip() {
  std::wstring t = L"Wolium";
  if (g->state == State::Paused) t += std::wstring(L" (") + tr(Key::TipPaused) + L")";
  if (g->state == State::Error) t += std::wstring(L" (") + tr(Key::TipError) + L")";
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
  std::ifstream in(std::filesystem::path(app::exe_dir() + L"\\userdata\\core.pid"));
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

void show_menu() {
  reload_language();
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kCmdOpen, tr(Key::TrayOpen));
  AppendMenuW(menu, MF_STRING, kCmdPause, g->state == State::Paused ? tr(Key::TrayResume) : tr(Key::TrayPause));
  if (g->state == State::Error) AppendMenuW(menu, MF_STRING, kCmdRestart, tr(Key::TrayRestart));
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
  else if (cmd == kCmdExit) DestroyWindow(g->hwnd);
}

void on_timer() {
  if (!app::consent_given()) {
    DestroyWindow(g->hwnd);
    return;
  }
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
    long long age = app::file_age_ms(app::exe_dir() + L"\\userdata\\heartbeat");
    if (age < 0 || age > kHangMs) {
      kill_core();
      on_core_died();
    }
  }
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
          if (g->state == State::Error) restart_from_error();
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
    if (msg == app::kMsgOpenUi) {
      launch_viewer();
      return 0;
    }
  }
  switch (msg) {
    case WM_TIMER:
      if (wp == kTimer) on_timer();
      return 0;
    case WM_QUERYENDSESSION:
      return TRUE;
    case WM_ENDSESSION:
      if (wp && g) stop_core();
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
  Guard guard;
  g = &guard;

  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  for (int i = 1; argv && i < argc; ++i) {
    if (std::wstring(argv[i]) == L"--background") guard.background = true;
  }
  if (argv) LocalFree(argv);

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
  SetTimer(guard.hwnd, kTimer, 1000, nullptr);
  if (!guard.background) launch_viewer();

  MSG m;
  while (GetMessageW(&m, nullptr, 0, 0) > 0) {
    TranslateMessage(&m);
    DispatchMessageW(&m);
  }

  KillTimer(guard.hwnd, kTimer);
  tray_remove();
  stop_core();
  if (guard.viewer) CloseHandle(guard.viewer);
  CloseHandle(mutex);
  return 0;
}
