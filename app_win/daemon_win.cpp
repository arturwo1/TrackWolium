#include "tw/win_util.hpp"
#include <shellapi.h>
#include <algorithm>
#include <filesystem>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include "tw/engine.hpp"
#include "tw/ipc.hpp"
#include "tw/paths.hpp"
#include "tw/platform.hpp"
#include "tw/serialize.hpp"
#include "tw/sqlite_store.hpp"

namespace {

constexpr UINT kTrayMsg = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr UINT kCmdOpen = 1001;
constexpr UINT kCmdExit = 1002;
constexpr wchar_t kClassName[] = L"TrackWoliumTrayWindow";
constexpr wchar_t kMutexName[] = L"Local\\TrackWolium.Daemon";

struct Options {
  bool background = false;
  bool no_db = false;
  int interval_ms = 1000;
  std::string db;
};

class PipeSink : public tw::ISink {
public:
  explicit PipeSink(tw::ReportServer& server) : server_(server) {}
  void render(const tw::Report& report) override { server_.publish(tw::serialize(report)); }

private:
  tw::ReportServer& server_;
};

struct App {
  Options opt;
  HWND hwnd = nullptr;
  UINT taskbar_created = 0;
  HICON icon = nullptr;
  bool history = false;
  HANDLE viewer = nullptr;
  std::atomic<bool> stop{false};
  std::thread worker;
  tw::ReportServer server;
  std::shared_ptr<tw::Engine> engine;
};

App* g_app = nullptr;

Options parse_options() {
  Options o;
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return o;
  for (int i = 1; i < argc; ++i) {
    std::wstring k = argv[i];
    if (k == L"--background") o.background = true;
    else if (k == L"--no-db") o.no_db = true;
    else if (k == L"--db" && i + 1 < argc) o.db = tw::to_utf8(argv[++i]);
    else if (k == L"--interval" && i + 1 < argc) {
      int v = _wtoi(argv[++i]);
      if (v >= 100) o.interval_ms = v;
    }
  }
  LocalFree(argv);
  return o;
}

std::wstring sibling_path(const wchar_t* file) {
  wchar_t buf[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
  std::wstring p(buf, n);
  std::size_t slash = p.find_last_of(L"\\/");
  return (slash == std::wstring::npos ? std::wstring() : p.substr(0, slash + 1)) + file;
}

std::string portable_db_path() {
  std::wstring dir = sibling_path(L"userdata");
  std::error_code ec;
  std::filesystem::create_directories(std::filesystem::path(dir), ec);
  if (ec) return {};
  return tw::to_utf8(dir + L"\\usage.db");
}

void launch_viewer(HANDLE* process) {
  std::wstring exe = sibling_path(L"wolium.exe");
  std::wstring cmd = L"\"" + exe + L"\"";
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
    CloseHandle(pi.hThread);
    if (process) *process = pi.hProcess;
    else CloseHandle(pi.hProcess);
  } else {
    MessageBoxW(nullptr, L"wolium.exe was not found next to trackwolium.exe", L"Wolium", MB_OK | MB_ICONWARNING);
  }
}

HICON make_icon() {
  const int n = 32;
  BITMAPV5HEADER bi{};
  bi.bV5Size = sizeof(bi);
  bi.bV5Width = n;
  bi.bV5Height = -n;
  bi.bV5Planes = 1;
  bi.bV5BitCount = 32;
  bi.bV5Compression = BI_BITFIELDS;
  bi.bV5RedMask = 0x00FF0000;
  bi.bV5GreenMask = 0x0000FF00;
  bi.bV5BlueMask = 0x000000FF;
  bi.bV5AlphaMask = 0xFF000000;

  void* bits = nullptr;
  HDC dc = GetDC(nullptr);
  HBITMAP color = CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, dc);
  HBITMAP mask = CreateBitmap(n, n, 1, 1, nullptr);
  if (!color || !mask || !bits) {
    if (color) DeleteObject(color);
    if (mask) DeleteObject(mask);
    return LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
  }

  auto* px = static_cast<std::uint32_t*>(bits);
  const std::uint32_t teal = 0xFF14A098;
  const std::uint32_t white = 0xFFFFFFFF;
  for (int y = 0; y < n; ++y) {
    for (int x = 0; x < n; ++x) {
      bool corner = (x < 3 && y < 3 && (3 - x) * (3 - x) + (3 - y) * (3 - y) > 9) ||
                    (x >= n - 3 && y < 3 && (x - (n - 4)) * (x - (n - 4)) + (3 - y) * (3 - y) > 9) ||
                    (x < 3 && y >= n - 3 && (3 - x) * (3 - x) + (y - (n - 4)) * (y - (n - 4)) > 9) ||
                    (x >= n - 3 && y >= n - 3 && (x - (n - 4)) * (x - (n - 4)) + (y - (n - 4)) * (y - (n - 4)) > 9);
      bool bar = y >= 6 && y < 11 && x >= 6 && x < 26;
      bool stem = y >= 11 && y < 27 && x >= 13 && x < 19;
      px[y * n + x] = corner ? 0u : (bar || stem ? white : teal);
    }
  }

  ICONINFO ii{};
  ii.fIcon = TRUE;
  ii.hbmColor = color;
  ii.hbmMask = mask;
  HICON icon = CreateIconIndirect(&ii);
  DeleteObject(color);
  DeleteObject(mask);
  return icon ? icon : LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
}

void tray_add(App& app) {
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = app.hwnd;
  nid.uID = kTrayId;
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = kTrayMsg;
  nid.hIcon = app.icon;
  const wchar_t* tip = app.history ? L"Wolium" : L"Wolium (history is not saved)";
  wcsncpy_s(nid.szTip, tip, _TRUNCATE);
  Shell_NotifyIconW(NIM_ADD, &nid);
  nid.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &nid);
}

void tray_remove(App& app) {
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = app.hwnd;
  nid.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &nid);
}

void open_viewer(App& app) {
  if (app.viewer && WaitForSingleObject(app.viewer, 0) == WAIT_TIMEOUT) return;
  if (app.viewer) {
    CloseHandle(app.viewer);
    app.viewer = nullptr;
  }
  launch_viewer(&app.viewer);
}

void show_menu(App& app) {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kCmdOpen, L"Open");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdExit, L"Exit");
  SetMenuDefaultItem(menu, kCmdOpen, FALSE);
  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(app.hwnd);
  UINT cmd = static_cast<UINT>(TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0, app.hwnd, nullptr));
  PostMessageW(app.hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (cmd == kCmdOpen) open_viewer(app);
  else if (cmd == kCmdExit) DestroyWindow(app.hwnd);
}

void start_worker(App& app) {
  app.server.start(tw::default_pipe_name());

  tw::ProbeOptions po;
  std::shared_ptr<tw::IProbe> probe = tw::make_native_probe(po);
  app.engine = std::make_shared<tw::Engine>(probe, tw::Duration(std::max(5000, app.opt.interval_ms * 3)));

  if (!app.opt.no_db) {
    std::string path = app.opt.db.empty() ? portable_db_path() : app.opt.db;
    if (!path.empty()) {
      std::string err;
      auto store = tw::SqliteStore::open(path, &err);
      if (store) {
        app.engine->set_store(std::shared_ptr<tw::IStore>(std::move(store)), tw::Duration(3000));
        app.history = true;
      }
    }
  }
  app.engine->add_sink(std::make_shared<PipeSink>(app.server));

  app.worker = std::thread([&app] {
    app.engine->run(tw::Duration(app.opt.interval_ms), [&app] { return app.stop.load(); });
    app.engine->finish();
  });
}

void stop_worker(App& app) {
  app.stop = true;
  if (app.worker.joinable()) app.worker.join();
  app.server.stop();
}

LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  App* app = g_app;
  if (app) {
    if (msg == kTrayMsg) {
      switch (LOWORD(lp)) {
        case WM_LBUTTONDBLCLK:
          open_viewer(*app);
          break;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          show_menu(*app);
          break;
      }
      return 0;
    }
    if (msg == app->taskbar_created) {
      tray_add(*app);
      return 0;
    }
  }
  switch (msg) {
    case WM_QUERYENDSESSION:
      return TRUE;
    case WM_ENDSESSION:
      if (wp && app) stop_worker(*app);
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
  App app;
  g_app = &app;
  app.opt = parse_options();

  HANDLE mutex = CreateMutexW(nullptr, TRUE, kMutexName);
  if (!mutex) return 1;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    if (!app.opt.background) {
      launch_viewer(nullptr);
    }
    CloseHandle(mutex);
    return 0;
  }

  WNDCLASSW wc{};
  wc.lpfnWndProc = wnd_proc;
  wc.hInstance = inst;
  wc.lpszClassName = kClassName;
  if (!RegisterClassW(&wc)) return 1;
  app.hwnd = CreateWindowExW(0, kClassName, L"TrackWolium", 0, 0, 0, 0, 0, nullptr, nullptr, inst, nullptr);
  if (!app.hwnd) return 1;

  app.taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  app.icon = make_icon();
  start_worker(app);
  tray_add(app);
  if (!app.opt.background) open_viewer(app);

  MSG m;
  while (GetMessageW(&m, nullptr, 0, 0) > 0) {
    TranslateMessage(&m);
    DispatchMessageW(&m);
  }

  tray_remove(app);
  stop_worker(app);
  if (app.viewer) CloseHandle(app.viewer);
  if (app.icon) DestroyIcon(app.icon);
  CloseHandle(mutex);
  return 0;
}
