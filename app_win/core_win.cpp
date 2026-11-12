#include <algorithm>
#include <ctime>
#include <fstream>
#include <memory>
#include <string>
#include "net_win.hpp"
#include "common_win.hpp"
#include <shellapi.h>
#include "tw/i18n.hpp"
#include "tw/engine.hpp"
#include "tw/ipc.hpp"
#include "tw/platform.hpp"
#include "tw/serialize.hpp"
#include "tw/sqlite_store.hpp"

namespace {

using tw::i18n::Key;
using tw::i18n::tr;

#ifndef NIN_BALLOONUSERCLICK
#define NIN_BALLOONUSERCLICK (WM_USER + 5)
#endif

constexpr UINT kOrphanMsg = WM_APP + 1;
constexpr wchar_t kOrphanClass[] = L"WoliumCoreWindow";

struct Orphan {
  HWND hwnd = nullptr;
  HANDLE guard = nullptr;
  HANDLE clean = nullptr;
  bool shown = false;
  ULONGLONG last_balloon = 0;
};

Orphan* g_orphan = nullptr;

NOTIFYICONDATAW orphan_nid() {
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = g_orphan->hwnd;
  nid.uID = 1;
  return nid;
}

void orphan_balloon() {
  NOTIFYICONDATAW nid = orphan_nid();
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = NIIF_ERROR;
  wcsncpy_s(nid.szInfoTitle, tr(Key::GuardDeadTitle), _TRUNCATE);
  wcsncpy_s(nid.szInfo, tr(Key::GuardDeadBody), _TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY, &nid);
  g_orphan->last_balloon = GetTickCount64();
}

void orphan_show() {
  if (g_orphan->shown) return;
  tw::i18n::load(std::filesystem::path(app::data_dir() + L"\\lang"), GetUserDefaultUILanguage());
  NOTIFYICONDATAW nid = orphan_nid();
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = kOrphanMsg;
  HANDLE ic = LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR);
  nid.hIcon = ic ? static_cast<HICON>(ic) : LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
  wcsncpy_s(nid.szTip, tr(Key::GuardDeadTip), _TRUNCATE);
  Shell_NotifyIconW(NIM_ADD, &nid);
  nid.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &nid);
  g_orphan->shown = true;
  orphan_balloon();
}

void orphan_hide() {
  if (!g_orphan->shown) return;
  NOTIFYICONDATAW nid = orphan_nid();
  Shell_NotifyIconW(NIM_DELETE, &nid);
  g_orphan->shown = false;
}

void revive_guard() {
  std::wstring exe = app::sibling(L"trackwolium.exe");
  std::wstring cmd = L"\"" + exe + L"\" --background";
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
}

LRESULT CALLBACK orphan_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == kOrphanMsg && g_orphan) {
    UINT ev = LOWORD(lp);
    if (ev == NIN_BALLOONUSERCLICK || ev == WM_LBUTTONUP || ev == WM_LBUTTONDBLCLK) revive_guard();
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

bool attach_guard(Orphan& o) {
  HWND w = FindWindowW(app::kGuardClass, nullptr);
  if (!w) return false;
  DWORD pid = 0;
  GetWindowThreadProcessId(w, &pid);
  if (!pid) return false;
  HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (!h) return false;
  if (o.guard) CloseHandle(o.guard);
  if (o.clean) CloseHandle(o.clean);
  o.guard = h;
  o.clean = OpenEventW(SYNCHRONIZE, FALSE, app::kGuardCleanEvent);
  return true;
}

void watch_guard(Orphan& o, HINSTANCE inst, HANDLE stop) {
  if (o.guard) {
    if (WaitForSingleObject(o.guard, 0) != WAIT_OBJECT_0) return;
    bool clean = o.clean && WaitForSingleObject(o.clean, 0) == WAIT_OBJECT_0;
    CloseHandle(o.guard);
    o.guard = nullptr;
    if (clean) {
      SetEvent(stop);
      return;
    }
    if (!o.hwnd) {
      WNDCLASSW wc{};
      wc.lpfnWndProc = orphan_proc;
      wc.hInstance = inst;
      wc.lpszClassName = kOrphanClass;
      RegisterClassW(&wc);
      o.hwnd = CreateWindowExW(0, kOrphanClass, L"Wolium", 0, 0, 0, 0, 0, nullptr, nullptr, inst, nullptr);
    }
    orphan_show();
    return;
  }
  if (attach_guard(o)) orphan_hide();
  else if (o.shown && GetTickCount64() - o.last_balloon > 120000) orphan_balloon();
}

class LiveSink : public tw::ISink {
public:
  LiveSink(app::LiveShare& live, app::LocalApi& api) : live_(live), api_(api) {}
  void render(const tw::Report& report) override {
    live_.write(tw::serialize(report));
    if (api_.running()) api_.set_body(tw::current_json(report));
  }

private:
  app::LiveShare& live_;
  app::LocalApi& api_;
};

struct Options {
  bool no_db = false;
  int interval_ms = 2000;
  std::string db;
};

Options parse_options() {
  Options o;
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return o;
  for (int i = 1; i < argc; ++i) {
    std::wstring k = argv[i];
    if (k == L"--no-db") o.no_db = true;
    else if (k == L"--db" && i + 1 < argc) o.db = tw::to_utf8(argv[++i]);
    else if (k == L"--interval" && i + 1 < argc) {
      int v = _wtoi(argv[++i]);
      if (v >= 100) o.interval_ms = v;
    }
  }
  LocalFree(argv);
  return o;
}

void write_text(const std::wstring& path, const std::string& text) {
  std::ofstream out(std::filesystem::path(path), std::ios::trunc);
  out << text;
}

}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
  HANDLE mutex = CreateMutexW(nullptr, TRUE, app::kCoreMutex);
  if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) return 0;
  app::migrate_legacy_data();
  if (!app::consent_given()) return 0;

  Options opt = parse_options();
  HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, app::kCoreStopEvent);
  HANDLE flush = CreateEventW(nullptr, FALSE, FALSE, app::kCoreFlushEvent);
  if (!stop || !flush) return 1;
  app::Heartbeat heartbeat;
  heartbeat.create();
  heartbeat.beat();

  write_text(app::userdata(L"core.pid"), std::to_string(GetCurrentProcessId()));

  app::LiveShare live;
  live.create();

  tw::ProbeOptions po;
  std::shared_ptr<tw::IProbe> probe = tw::make_native_probe(po);
  tw::Engine engine(probe, tw::Duration(std::max(5000, opt.interval_ms * 3)));
  if (!opt.no_db) {
    std::string path = opt.db.empty() ? tw::to_utf8(app::userdata(L"usage.db")) : opt.db;
    std::string err;
    auto store = tw::SqliteStore::open(path, &err);
    if (store) engine.set_store(std::shared_ptr<tw::IStore>(std::move(store)), tw::Duration(180000));
  }
  app::LocalApi api;
  engine.add_sink(std::make_shared<LiveSink>(live, api));

  Orphan orphan;
  g_orphan = &orphan;
  attach_guard(orphan);
  bool allowed = true;
  bool is_paused = false;
  ULONGLONG last_check = 0;
  HANDLE waits[2] = {stop, flush};
  for (;;) {
    ULONGLONG now = GetTickCount64();
    heartbeat.beat();
    if (now - last_check >= 4000 || last_check == 0) {
      allowed = app::consent_given();
      is_paused = app::paused();
      if (app::flag(L"localapi")) api.start();
      else api.stop();
      last_check = now;
    }
    if (!allowed) break;
    if (!is_paused) engine.step(tw::Clock::now());
    watch_guard(orphan, inst, stop);
    DWORD w = MsgWaitForMultipleObjects(2, waits, FALSE, static_cast<DWORD>(opt.interval_ms), QS_ALLINPUT);
    MSG m;
    while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&m);
      DispatchMessageW(&m);
    }
    if (w == WAIT_OBJECT_0) break;
    if (w == WAIT_OBJECT_0 + 1) engine.flush();
  }

  api.stop();
  orphan_hide();
  engine.finish();
  live.clear();
  CloseHandle(stop);
  CloseHandle(flush);
  CloseHandle(mutex);
  return 0;
}
