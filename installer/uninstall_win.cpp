#include <objbase.h>
#include <shellapi.h>
#include <algorithm>
#include <functional>
#include <fstream>
#include <set>
#include <string>
#include <vector>
#include "inst_common.hpp"
#include "theme_win.hpp"

namespace {

using tw::i18n::Key;
using tw::i18n::tr;

bool safe_relative(const std::wstring& p) {
  if (p.empty() || p.find(L"..") != std::wstring::npos) return false;
  if (p[0] == L'\\' || p[0] == L'/') return false;
  return p.find(L':') == std::wstring::npos;
}

std::wstring widen(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(static_cast<std::size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
  return w;
}

std::vector<std::wstring> read_manifest(const std::wstring& dir) {
  std::vector<std::wstring> out;
  std::ifstream in(std::filesystem::path(dir + L"\\manifest.txt"));
  std::string line;
  while (std::getline(in, line)) {
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    std::wstring w = widen(line);
    for (auto& c : w) {
      if (c == L'/') c = L'\\';
    }
    if (safe_relative(w)) out.push_back(w);
  }
  return out;
}

bool delete_file_retry(const std::wstring& path) {
  for (int i = 0; i < 20; ++i) {
    std::error_code ec;
    if (!std::filesystem::exists(std::filesystem::path(path), ec)) return true;
    std::filesystem::remove(std::filesystem::path(path), ec);
    if (!std::filesystem::exists(std::filesystem::path(path), ec)) return true;
    Sleep(250);
  }
  return false;
}

bool remove_tree_retry(const std::wstring& path) {
  for (int i = 0; i < 20; ++i) {
    std::error_code ec;
    std::filesystem::remove_all(std::filesystem::path(path), ec);
    if (!std::filesystem::exists(std::filesystem::path(path), ec)) return true;
    Sleep(250);
  }
  return false;
}

int finish(const std::wstring& dir, bool keep_data) {
  inst::apply_language(dir);
  if (!inst::looks_installed(dir)) {
    theme::dialog(L"Wolium", tr(Key::UnNotWolium), {tr(Key::Close)}, 0);
    return 1;
  }
  Sleep(500);
  inst::kill_in_dir(dir);
  inst::set_autostart(dir, false);
  inst::unregister_uninstall();
  std::error_code ec;
  std::filesystem::remove(inst::desktop_link(), ec);
  std::filesystem::remove(inst::start_menu_link(), ec);

  bool ok = true;
  std::set<std::wstring, std::greater<std::wstring>> dirs;
  for (const auto& rel : read_manifest(dir)) {
    if (!delete_file_retry(dir + L"\\" + rel)) ok = false;
    std::wstring parent = inst::dir_of(rel);
    while (!parent.empty()) {
      dirs.insert(parent);
      parent = inst::dir_of(parent);
    }
  }
  if (!delete_file_retry(dir + L"\\manifest.txt")) ok = false;
  if (!delete_file_retry(dir + L"\\uninstall.exe")) ok = false;
  for (const auto& d : dirs) RemoveDirectoryW((dir + L"\\" + d).c_str());

  if (!keep_data) {
    if (!remove_tree_retry(inst::data_dir())) ok = false;
    RemoveDirectoryW(inst::dir_of(inst::data_dir()).c_str());
  }
  DeleteFileW(inst::version_file(dir).c_str());
  if (RemoveDirectoryW(dir.c_str())) {
    std::wstring parent = inst::dir_of(dir);
    std::wstring leaf = parent.substr(parent.find_last_of(L"\\/") == std::wstring::npos ? 0 : parent.find_last_of(L"\\/") + 1);
    if (inst::lower(leaf) == L"dtsys") RemoveDirectoryW(parent.c_str());
  }

  const wchar_t* text = !ok ? tr(Key::UnPartial) : (keep_data ? tr(Key::UnDoneKeep) : tr(Key::UnDoneAll));
  theme::dialog(L"Wolium", text, {tr(Key::Close)}, 0);
  return ok ? 0 : 1;
}

}

namespace {

constexpr int kIdTitle = 1;
constexpr int kIdSub = 2;
constexpr int kIdLabel = 3;
constexpr int kIdPath = 4;
constexpr int kIdKeep = 5;
constexpr int kIdAll = 6;
constexpr int kIdGo = 7;
constexpr int kIdCancel = 8;

HWND g_main;
bool g_keep = true;
std::wstring g_dir;

HWND make(const wchar_t* text, DWORD style, int x, int y, int w, int h, HWND parent, int id, const wchar_t* cls = L"STATIC") {
  HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, parent,
                           reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), nullptr, nullptr);
  SendMessageW(c, WM_SETFONT, reinterpret_cast<WPARAM>(id == kIdTitle ? theme::res().big : theme::res().font), TRUE);
  return c;
}

void start_finish() {
  wchar_t tmp[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, tmp);
  std::wstring copy = std::wstring(tmp, n) + L"wolium_uninstall_" + std::to_wstring(GetCurrentProcessId()) + L".exe";
  if (!CopyFileW(inst::self_path().c_str(), copy.c_str(), FALSE)) {
    theme::dialog(L"Wolium", tr(Key::UnPrepare), {tr(Key::Close)}, 0);
    return;
  }
  std::wstring cmd = L"\"" + copy + L"\" --finish \"" + g_dir + L"\" " + (g_keep ? L"keep" : L"all");
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (CreateProcessW(copy.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, tmp, &si, &pi)) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
  DestroyWindow(g_main);
}

LRESULT CALLBACK proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_CREATE: {
      g_main = hwnd;
      theme::init();
      theme::dark_title(hwnd);
      SetWindowTextW(hwnd, tr(Key::UnTitle));
      make(L"Wolium", 0, 24, 18, 300, 34, hwnd, kIdTitle);
      make(tr(Key::UnTitle), 0, 26, 54, 300, 20, hwnd, kIdSub);
      make(tr(Key::UnFolder), 0, 24, 98, 430, 20, hwnd, kIdLabel);
      make(g_dir.c_str(), SS_PATHELLIPSIS, 24, 120, 432, 22, hwnd, kIdPath);
      make(tr(Key::UnKeepOption), BS_OWNERDRAW | WS_TABSTOP, 24, 164, 430, 26, hwnd, kIdKeep, L"BUTTON");
      make(tr(Key::UnAllOption), BS_OWNERDRAW | WS_TABSTOP, 24, 198, 430, 26, hwnd, kIdAll, L"BUTTON");
      make(tr(Key::Cancel), BS_OWNERDRAW | WS_TABSTOP, 196, 258, 120, 36, hwnd, kIdCancel, L"BUTTON");
      make(tr(Key::UnAction), BS_OWNERDRAW | WS_TABSTOP, 328, 258, 128, 36, hwnd, kIdGo, L"BUTTON");
      return 0;
    }
    case WM_CTLCOLORSTATIC: {
      HDC dc = reinterpret_cast<HDC>(wp);
      int id = GetDlgCtrlID(reinterpret_cast<HWND>(lp));
      SetTextColor(dc, (id == kIdSub || id == kIdLabel) ? theme::kMuted : theme::kText);
      SetBkColor(dc, theme::kBg);
      return reinterpret_cast<LRESULT>(theme::res().bg);
    }
    case WM_ERASEBKGND: {
      RECT r;
      GetClientRect(hwnd, &r);
      FillRect(reinterpret_cast<HDC>(wp), &r, theme::res().bg);
      return 1;
    }
    case WM_DRAWITEM: {
      const DRAWITEMSTRUCT* d = reinterpret_cast<const DRAWITEMSTRUCT*>(lp);
      int id = static_cast<int>(d->CtlID);
      int len = GetWindowTextLengthW(d->hwndItem);
      std::wstring label(static_cast<std::size_t>(len) + 1, L'\0');
      GetWindowTextW(d->hwndItem, &label[0], len + 1);
      label.resize(static_cast<std::size_t>(len));
      if (id == kIdKeep || id == kIdAll) {
        theme::paint_radio(d->hDC, d->rcItem, label, id == kIdKeep ? g_keep : !g_keep, false);
      } else {
        POINT p;
        GetCursorPos(&p);
        RECT wr;
        GetWindowRect(d->hwndItem, &wr);
        theme::paint_button(d->hDC, d->rcItem, label, id == kIdGo ? theme::Look::Accent : theme::Look::Normal, false,
                            (d->itemState & ODS_SELECTED) != 0, false, PtInRect(&wr, p) != 0);
      }
      return TRUE;
    }
    case WM_COMMAND: {
      int id = LOWORD(wp);
      if (id == kIdKeep || id == kIdAll) {
        g_keep = id == kIdKeep;
        InvalidateRect(GetDlgItem(hwnd, kIdKeep), nullptr, TRUE);
        InvalidateRect(GetDlgItem(hwnd, kIdAll), nullptr, TRUE);
      } else if (id == kIdCancel) {
        DestroyWindow(hwnd);
      } else if (id == kIdGo) {
        start_finish();
      }
      return 0;
    }
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv && argc >= 4 && std::wstring(argv[1]) == L"--finish") {
    std::wstring dir = argv[2];
    bool keep = std::wstring(argv[3]) == L"keep";
    LocalFree(argv);
    return finish(dir, keep);
  }
  if (argv) LocalFree(argv);

  g_dir = inst::dir_of(inst::self_path());
  inst::apply_language(g_dir);
  if (!inst::looks_installed(g_dir)) {
    theme::dialog(L"Wolium", tr(Key::UnRunFromFolder), {tr(Key::Close)}, 0);
    return 1;
  }
  WNDCLASSW wc{};
  wc.lpfnWndProc = proc;
  wc.hInstance = inst;
  wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
  wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
  wc.lpszClassName = L"WoliumUninstall";
  RegisterClassW(&wc);
  RECT r{0, 0, 480, 318};
  AdjustWindowRect(&r, WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, FALSE);
  HWND w = CreateWindowExW(0, wc.lpszClassName, L"Wolium", WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, CW_USEDEFAULT, CW_USEDEFAULT,
                           r.right - r.left, r.bottom - r.top, nullptr, nullptr, inst, nullptr);
  ShowWindow(w, show);
  MSG m;
  while (GetMessageW(&m, nullptr, 0, 0) > 0) {
    if (!IsDialogMessageW(w, &m)) {
      TranslateMessage(&m);
      DispatchMessageW(&m);
    }
  }
  CoUninitialize();
  return 0;
}
