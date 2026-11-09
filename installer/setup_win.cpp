#include <objbase.h>
#include <shobjidl.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <thread>
#include <vector>
#include "inst_common.hpp"
#include "theme_win.hpp"

namespace {

using tw::i18n::Key;
using tw::i18n::tr;

constexpr UINT kDone = WM_APP + 1;
constexpr int kIdPath = 101;
constexpr int kIdBrowse = 102;
constexpr int kIdAuto = 103;
constexpr int kIdDesk = 104;
constexpr int kIdInstall = 105;
constexpr int kIdStatus = 106;
constexpr int kIdLabel = 107;
constexpr int kIdTitle = 108;
constexpr int kIdSub = 109;
constexpr int kIdUninstall = 110;
constexpr int kIdLang = 200;
constexpr char kMagic[8] = {'W', 'O', 'L', 'I', 'U', 'M', 'P', 'K'};

using theme::kBg;
using theme::kError;
using theme::kMuted;
using theme::kPanel;
using theme::kText;

#ifndef TW_VERSION_STR
#define TW_VERSION_STR "0.0.0"
#endif

HWND g_main, g_path, g_status, g_install, g_browse, g_lang, g_uninst;
bool g_auto = false;
bool g_desk = true;
bool g_busy = false;
bool g_error = false;
bool g_installing = false;
bool g_done = false;
std::wstring g_status_text;

std::wstring read_text(HWND h) {
  int n = GetWindowTextLengthW(h);
  std::wstring s(static_cast<std::size_t>(n) + 1, L'\0');
  GetWindowTextW(h, &s[0], n + 1);
  s.resize(static_cast<std::size_t>(n));
  return s;
}

void set_status(const std::wstring& text, bool error) {
  g_status_text = text;
  g_error = error;
  SetWindowTextW(g_status, text.c_str());
  InvalidateRect(g_status, nullptr, TRUE);
}

enum class InstallState { None, Update, Same };

std::wstring build_version() {
  std::wstring v;
  for (const char* p = TW_VERSION_STR; *p; ++p) v += static_cast<wchar_t>(*p);
  return v;
}

std::wstring current_dir() {
  std::wstring dir = read_text(g_path);
  while (dir.size() > 3 && (dir.back() == L'\\' || dir.back() == L'/')) dir.pop_back();
  return dir;
}

InstallState install_state() {
  std::wstring dir = current_dir();
  if (dir.size() < 4 || !inst::looks_installed(dir)) return InstallState::None;
  return inst::compare_versions(inst::installed_version(dir), build_version()) < 0 ? InstallState::Update : InstallState::Same;
}

void show_hint() {
  InstallState st = install_state();
  const wchar_t* text = st == InstallState::Update ? tr(Key::SetupUpdateAvailable) : (st == InstallState::Same ? tr(Key::SetupUpToDate) : tr(Key::SetupHint));
  set_status(text, false);
  if (!g_done && !g_busy) {
    SetWindowTextW(g_install, st == InstallState::Update ? tr(Key::Update) : (st == InstallState::Same ? tr(Key::Reinstall) : tr(Key::Install)));
    ShowWindow(g_uninst, st == InstallState::None ? SW_HIDE : SW_SHOW);
  }
}

void apply_texts() {
  SetWindowTextW(g_main, tr(Key::SetupTitle));
  SetWindowTextW(GetDlgItem(g_main, kIdTitle), L"Wolium");
  SetWindowTextW(GetDlgItem(g_main, kIdSub), tr(Key::SetupSubtitle));
  SetWindowTextW(GetDlgItem(g_main, kIdLabel), tr(Key::InstallFolder));
  SetWindowTextW(g_browse, tr(Key::Browse));
  SetWindowTextW(g_uninst, tr(Key::UninstallBtn));
  SetWindowTextW(GetDlgItem(g_main, kIdAuto), tr(Key::AutoStart));
  SetWindowTextW(GetDlgItem(g_main, kIdDesk), tr(Key::DesktopShortcut));
  if (g_done) SetWindowTextW(g_install, tr(Key::Close));
  if (g_done) set_status(tr(Key::InstallDone), false);
  if (!g_error && !g_installing && !g_done) show_hint();
  SetWindowTextW(g_lang, tw::i18n::name(tw::i18n::current()));
  InvalidateRect(g_main, nullptr, TRUE);
}

bool extract_payload(const std::wstring& zip_path, Key* error) {
  std::ifstream in(std::filesystem::path(inst::self_path()), std::ios::binary);
  if (!in) {
    *error = Key::ErrReadInstaller;
    return false;
  }
  in.seekg(0, std::ios::end);
  std::uint64_t total = static_cast<std::uint64_t>(in.tellg());
  if (total < 16) {
    *error = Key::ErrCorrupt;
    return false;
  }
  char trailer[16];
  in.seekg(static_cast<std::streamoff>(total - 16));
  in.read(trailer, 16);
  std::uint64_t size = 0;
  std::memcpy(&size, trailer, 8);
  if (std::memcmp(trailer + 8, kMagic, 8) != 0 || size == 0 || size > total - 16) {
    *error = Key::ErrNoPayload;
    return false;
  }
  in.seekg(static_cast<std::streamoff>(total - 16 - size));
  std::ofstream out(std::filesystem::path(zip_path), std::ios::binary | std::ios::trunc);
  if (!out) {
    *error = Key::ErrTempFile;
    return false;
  }
  std::vector<char> buf(1 << 16);
  std::uint64_t left = size;
  while (left > 0) {
    std::size_t n = static_cast<std::size_t>(left < buf.size() ? left : buf.size());
    in.read(buf.data(), static_cast<std::streamsize>(n));
    if (static_cast<std::size_t>(in.gcount()) != n) {
      *error = Key::ErrCorrupt;
      return false;
    }
    out.write(buf.data(), static_cast<std::streamsize>(n));
    left -= n;
  }
  return true;
}

bool run_tar(const std::wstring& zip, const std::wstring& dir) {
  wchar_t sys[MAX_PATH];
  UINT n = GetSystemDirectoryW(sys, MAX_PATH);
  std::wstring tar = std::wstring(sys, n) + L"\\tar.exe";
  std::wstring cmd = L"\"" + tar + L"\" -xf \"" + zip + L"\" -C \"" + dir + L"\"";
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(tar.c_str(), &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) return false;
  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return code == 0;
}

struct Job {
  std::wstring dir;
  bool autostart;
  bool desktop;
  int lang;
  HWND hwnd;
};

void do_install(Job job) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  Key err = Key::ErrExtract;
  bool ok = false;
  std::error_code ec;
  inst::kill_in_dir(job.dir);
  std::filesystem::create_directories(job.dir, ec);
  if (ec) {
    err = Key::ErrCreateDir;
  } else {
    wchar_t tmp[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, tmp);
    std::wstring zip = std::wstring(tmp, n) + L"wolium_payload.zip";
    if (extract_payload(zip, &err)) {
      if (run_tar(zip, job.dir) && inst::looks_installed(job.dir)) {
        ok = true;
      } else {
        err = Key::ErrExtract;
      }
    }
    std::filesystem::remove(zip, ec);
  }
  if (ok) {
    std::error_code ec2;
    std::filesystem::create_directories(inst::data_dir(), ec2);
    tw::i18n::write_code(std::filesystem::path(inst::lang_file(job.dir)), tw::i18n::code(job.lang));
    std::wstring ver;
    for (const char* p = TW_VERSION_STR; *p; ++p) ver += static_cast<wchar_t>(*p);
    inst::write_version(job.dir, ver);
    inst::register_uninstall(job.dir, ver);
    inst::set_autostart(job.dir, job.autostart);
    inst::make_link(inst::start_menu_link(), job.dir + L"\\wolium.exe", job.dir);
    if (job.desktop) inst::make_link(inst::desktop_link(), job.dir + L"\\wolium.exe", job.dir);
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    std::wstring exe = job.dir + L"\\wolium.exe";
    std::wstring cmd = L"\"" + exe + L"\"";
    if (CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, job.dir.c_str(), &si, &pi)) {
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    }
  }
  CoUninitialize();
  PostMessageW(job.hwnd, kDone, ok ? 1 : 0, static_cast<LPARAM>(err));
}

std::wstring browse(HWND owner) {
  std::wstring result;
  IFileOpenDialog* dlg = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_IFileOpenDialog, reinterpret_cast<void**>(&dlg)))) {
    DWORD opts = 0;
    dlg->GetOptions(&opts);
    dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
    if (SUCCEEDED(dlg->Show(owner))) {
      IShellItem* item = nullptr;
      if (SUCCEEDED(dlg->GetResult(&item))) {
        PWSTR p = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &p)) && p) result = p;
        CoTaskMemFree(p);
        item->Release();
      }
    }
    dlg->Release();
  }
  return result;
}

HWND make(const wchar_t* cls, const wchar_t* text, DWORD style, int x, int y, int w, int h, HWND parent, int id, HFONT font) {
  HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, parent,
                           reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), nullptr, nullptr);
  SendMessageW(c, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
  return c;
}

void draw_button(const DRAWITEMSTRUCT* d) {
  int id = static_cast<int>(d->CtlID);
  bool disabled = (d->itemState & ODS_DISABLED) != 0;
  bool pressed = (d->itemState & ODS_SELECTED) != 0;
  std::wstring label = read_text(d->hwndItem);
  POINT p;
  GetCursorPos(&p);
  RECT wr;
  GetWindowRect(d->hwndItem, &wr);
  bool hover = !disabled && PtInRect(&wr, p) != 0;
  if (id == kIdAuto || id == kIdDesk) {
    theme::paint_check(d->hDC, d->rcItem, label, id == kIdAuto ? g_auto : g_desk, disabled);
  } else if (id == kIdLang) {
    theme::paint_button(d->hDC, d->rcItem, label, theme::Look::Normal, disabled, pressed, true, hover);
  } else {
    theme::paint_button(d->hDC, d->rcItem, label, id == kIdInstall ? theme::Look::Accent : theme::Look::Normal, disabled, pressed, false, hover);
  }
}

void set_busy(bool busy) {
  g_busy = busy;
  EnableWindow(g_install, !busy);
  EnableWindow(g_browse, !busy);
  EnableWindow(g_uninst, !busy);
  EnableWindow(g_path, !busy);
}

LRESULT CALLBACK proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_CREATE: {
      g_main = hwnd;
      theme::init();
      theme::dark_title(hwnd);
      HFONT font = theme::res().font;
      make(L"STATIC", L"", 0, 24, 18, 200, 34, hwnd, kIdTitle, theme::res().big);
      make(L"STATIC", L"", 0, 26, 54, 220, 20, hwnd, kIdSub, font);
      g_lang = make(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, 480 - 24 - 150, 22, 150, 34, hwnd, kIdLang, font);
      make(L"STATIC", L"", 0, 24, 98, 430, 20, hwnd, kIdLabel, font);
      g_path = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_BORDER | ES_AUTOHSCROLL | WS_TABSTOP, 24, 122, 340, 30, hwnd,
                               reinterpret_cast<HMENU>(static_cast<INT_PTR>(kIdPath)), nullptr, nullptr);
      SendMessageW(g_path, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
      g_browse = make(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, 372, 121, 84, 32, hwnd, kIdBrowse, font);
      make(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, 24, 170, 430, 24, hwnd, kIdAuto, font);
      make(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, 24, 200, 430, 24, hwnd, kIdDesk, font);
      g_status = make(L"STATIC", L"", 0, 24, 240, 430, 40, hwnd, kIdStatus, font);
      g_install = make(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, 296, 288, 160, 36, hwnd, kIdInstall, font);
      g_uninst = make(L"BUTTON", L"", BS_OWNERDRAW | WS_TABSTOP, 24, 288, 190, 36, hwnd, kIdUninstall, font);
      std::wstring def = inst::known_folder(FOLDERID_LocalAppData) + L"\\Programs\\DTSys\\Wolium";
      SetWindowTextW(g_path, def.c_str());
      tw::i18n::load(std::filesystem::path(), GetUserDefaultUILanguage());
      apply_texts();
      return 0;
    }
    case WM_CTLCOLORSTATIC: {
      HDC dc = reinterpret_cast<HDC>(wp);
      HWND c = reinterpret_cast<HWND>(lp);
      int id = GetDlgCtrlID(c);
      COLORREF col = kText;
      if (id == kIdSub || id == kIdLabel) col = kMuted;
      if (id == kIdStatus) col = g_error ? kError : (g_done ? kText : kMuted);
      SetTextColor(dc, col);
      SetBkColor(dc, kBg);
      return reinterpret_cast<LRESULT>(theme::res().bg);
    }
    case WM_CTLCOLOREDIT: {
      HDC dc = reinterpret_cast<HDC>(wp);
      SetTextColor(dc, kText);
      SetBkColor(dc, kPanel);
      return reinterpret_cast<LRESULT>(theme::res().panel);
    }
    case WM_ERASEBKGND: {
      RECT r;
      GetClientRect(hwnd, &r);
      FillRect(reinterpret_cast<HDC>(wp), &r, theme::res().bg);
      return 1;
    }
    case WM_DRAWITEM:
      draw_button(reinterpret_cast<const DRAWITEMSTRUCT*>(lp));
      return TRUE;
    case WM_COMMAND: {
      int id = LOWORD(wp);
      if (id == kIdLang) {
        RECT r;
        GetWindowRect(g_lang, &r);
        std::vector<std::wstring> names;
        for (int i = 0; i < tw::i18n::count(); ++i) names.push_back(tw::i18n::name(i));
        int pick = theme::popup_list(hwnd, r, names, tw::i18n::current());
        if (pick >= 0) {
          tw::i18n::set(pick);
          apply_texts();
        }
        InvalidateRect(g_lang, nullptr, TRUE);
      } else if (id == kIdAuto || id == kIdDesk) {
        (id == kIdAuto ? g_auto : g_desk) = !(id == kIdAuto ? g_auto : g_desk);
        InvalidateRect(GetDlgItem(hwnd, id), nullptr, TRUE);
      } else if (id == kIdBrowse) {
        std::wstring p = browse(hwnd);
        if (!p.empty()) SetWindowTextW(g_path, p.c_str());
        if (!g_error) show_hint();
      } else if (id == kIdPath && HIWORD(wp) == EN_CHANGE) {
        if (!g_error && !g_installing && !g_done) show_hint();
      } else if (id == kIdUninstall && !g_busy) {
        std::wstring exe = current_dir() + L"\\uninstall.exe";
        std::wstring cmd = L"\"" + exe + L"\"";
        STARTUPINFOW si{};
        si.cb = sizeof(si);
        PROCESS_INFORMATION pi{};
        if (CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
          CloseHandle(pi.hThread);
          CloseHandle(pi.hProcess);
          DestroyWindow(hwnd);
        }
      } else if (id == kIdInstall && g_done) {
        DestroyWindow(hwnd);
      } else if (id == kIdInstall && !g_busy) {
        std::wstring dir = read_text(g_path);
        while (dir.size() > 3 && (dir.back() == L'\\' || dir.back() == L'/')) dir.pop_back();
        if (dir.size() < 4) {
          set_status(tr(Key::ChooseFolder), true);
          return 0;
        }
        set_busy(true);
        g_installing = true;
        set_status(tr(Key::Installing), false);
        Job job{dir, g_auto, g_desk, tw::i18n::current(), hwnd};
        std::thread(do_install, job).detach();
      }
      return 0;
    }
    case kDone:
      g_installing = false;
      if (wp) {
        g_done = true;
        g_busy = false;
        EnableWindow(g_install, TRUE);
        ShowWindow(g_uninst, SW_HIDE);
        SetWindowTextW(g_install, tr(Key::Close));
        set_status(tr(Key::InstallDone), false);
      } else {
        set_status(tr(static_cast<Key>(lp)), true);
        set_busy(false);
      }
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  WNDCLASSW wc{};
  wc.lpfnWndProc = proc;
  wc.hInstance = inst;
  wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
  wc.hbrBackground = nullptr;
  wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
  wc.lpszClassName = L"WoliumSetup";
  RegisterClassW(&wc);
  RECT r{0, 0, 480, 344};
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
