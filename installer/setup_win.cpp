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

namespace {

constexpr UINT kDone = WM_APP + 1;
constexpr int kIdPath = 101;
constexpr int kIdBrowse = 102;
constexpr int kIdAuto = 103;
constexpr int kIdDesk = 104;
constexpr int kIdInstall = 105;
constexpr int kIdStatus = 106;
constexpr char kMagic[8] = {'W', 'O', 'L', 'I', 'U', 'M', 'P', 'K'};

HWND g_path, g_auto, g_desk, g_install, g_status, g_browse;

std::wstring read_text(HWND h) {
  int n = GetWindowTextLengthW(h);
  std::wstring s(static_cast<std::size_t>(n) + 1, L'\0');
  GetWindowTextW(h, &s[0], n + 1);
  s.resize(static_cast<std::size_t>(n));
  return s;
}

void set_status(const wchar_t* t) { SetWindowTextW(g_status, t); }

bool extract_payload(const std::wstring& zip_path, std::wstring* error) {
  std::ifstream in(std::filesystem::path(inst::self_path()), std::ios::binary);
  if (!in) {
    *error = L"Could not read the installer";
    return false;
  }
  in.seekg(0, std::ios::end);
  std::uint64_t total = static_cast<std::uint64_t>(in.tellg());
  if (total < 16) {
    *error = L"The installer is corrupted";
    return false;
  }
  char trailer[16];
  in.seekg(static_cast<std::streamoff>(total - 16));
  in.read(trailer, 16);
  std::uint64_t size = 0;
  std::memcpy(&size, trailer, 8);
  if (std::memcmp(trailer + 8, kMagic, 8) != 0 || size == 0 || size > total - 16) {
    *error = L"The installer has no payload";
    return false;
  }
  in.seekg(static_cast<std::streamoff>(total - 16 - size));
  std::ofstream out(std::filesystem::path(zip_path), std::ios::binary | std::ios::trunc);
  if (!out) {
    *error = L"Could not create a temporary file";
    return false;
  }
  std::vector<char> buf(1 << 16);
  std::uint64_t left = size;
  while (left > 0) {
    std::size_t n = static_cast<std::size_t>(left < buf.size() ? left : buf.size());
    in.read(buf.data(), static_cast<std::streamsize>(n));
    if (static_cast<std::size_t>(in.gcount()) != n) {
      *error = L"The installer is corrupted";
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
  HWND hwnd;
};

void do_install(Job job) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  std::wstring err;
  bool ok = false;
  std::error_code ec;
  inst::kill_in_dir(job.dir);
  std::filesystem::create_directories(job.dir, ec);
  if (ec) {
    err = L"Could not create the folder";
  } else {
    wchar_t tmp[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, tmp);
    std::wstring zip = std::wstring(tmp, n) + L"wolium_payload.zip";
    if (extract_payload(zip, &err)) {
      if (run_tar(zip, job.dir) && inst::looks_installed(job.dir)) {
        ok = true;
      } else {
        err = L"Could not extract the files";
      }
    }
    std::filesystem::remove(zip, ec);
  }
  if (ok) {
    inst::set_autostart(job.dir, job.autostart);
    inst::make_link(inst::start_menu_link(), job.dir + L"\\wolium.exe", job.dir);
    if (job.desktop) inst::make_link(inst::desktop_link(), job.dir + L"\\wolium.exe", job.dir);
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    std::wstring exe = job.dir + L"\\trackwolium.exe";
    std::wstring cmd = L"\"" + exe + L"\"";
    if (CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, job.dir.c_str(), &si, &pi)) {
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    }
  }
  CoUninitialize();
  auto* msg = new std::wstring(ok ? L"" : err);
  PostMessageW(job.hwnd, kDone, ok ? 1 : 0, reinterpret_cast<LPARAM>(msg));
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

std::wstring resolve_target(std::wstring dir) {
  while (dir.size() > 3 && (dir.back() == L'\\' || dir.back() == L'/')) dir.pop_back();
  std::error_code ec;
  std::filesystem::path p(dir);
  if (!std::filesystem::exists(p, ec)) return dir;
  if (inst::looks_installed(dir)) return dir;
  if (std::filesystem::is_empty(p, ec)) return dir;
  return dir + L"\\Wolium";
}

HWND make(const wchar_t* cls, const wchar_t* text, DWORD style, int x, int y, int w, int h, HWND parent, int id) {
  HWND c = CreateWindowExW(cls == std::wstring(L"EDIT") ? WS_EX_CLIENTEDGE : 0, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h,
                           parent, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), nullptr, nullptr);
  SendMessageW(c, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), TRUE);
  return c;
}

LRESULT CALLBACK proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_CREATE: {
      make(L"STATIC", L"Install folder:", 0, 16, 16, 400, 18, hwnd, 0);
      g_path = make(L"EDIT", L"", ES_AUTOHSCROLL, 16, 38, 330, 24, hwnd, kIdPath);
      g_browse = make(L"BUTTON", L"Browse…", BS_PUSHBUTTON, 356, 37, 80, 26, hwnd, kIdBrowse);
      g_auto = make(L"BUTTON", L"Start with Windows", BS_AUTOCHECKBOX, 16, 76, 400, 20, hwnd, kIdAuto);
      g_desk = make(L"BUTTON", L"Desktop shortcut", BS_AUTOCHECKBOX, 16, 100, 400, 20, hwnd, kIdDesk);
      g_status = make(L"STATIC", L"Everything lives in one folder. Deleting it removes Wolium.", 0, 16, 134, 420, 36, hwnd, kIdStatus);
      g_install = make(L"BUTTON", L"Install", BS_DEFPUSHBUTTON, 336, 178, 100, 30, hwnd, kIdInstall);
      SendMessageW(g_desk, BM_SETCHECK, BST_CHECKED, 0);
      std::wstring def = inst::known_folder(FOLDERID_Profile) + L"\\Wolium";
      SetWindowTextW(g_path, def.c_str());
      return 0;
    }
    case WM_COMMAND:
      if (LOWORD(wp) == kIdBrowse) {
        std::wstring p = browse(hwnd);
        if (!p.empty()) SetWindowTextW(g_path, p.c_str());
      } else if (LOWORD(wp) == kIdInstall) {
        std::wstring dir = resolve_target(read_text(g_path));
        if (dir.size() < 4) {
          set_status(L"Choose a folder.");
          return 0;
        }
        SetWindowTextW(g_path, dir.c_str());
        EnableWindow(g_install, FALSE);
        EnableWindow(g_browse, FALSE);
        EnableWindow(g_path, FALSE);
        set_status(L"Installing…");
        Job job{dir, SendMessageW(g_auto, BM_GETCHECK, 0, 0) == BST_CHECKED, SendMessageW(g_desk, BM_GETCHECK, 0, 0) == BST_CHECKED, hwnd};
        std::thread(do_install, job).detach();
      }
      return 0;
    case kDone: {
      std::unique_ptr<std::wstring> err(reinterpret_cast<std::wstring*>(lp));
      if (wp) {
        MessageBoxW(hwnd, L"Wolium is installed and running, look for the tray icon.", L"Wolium", MB_OK | MB_ICONINFORMATION);
        DestroyWindow(hwnd);
      } else {
        set_status(err->c_str());
        EnableWindow(g_install, TRUE);
        EnableWindow(g_browse, TRUE);
        EnableWindow(g_path, TRUE);
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
  WNDCLASSW wc{};
  wc.lpfnWndProc = proc;
  wc.hInstance = inst;
  wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
  wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
  wc.hIcon = LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
  wc.lpszClassName = L"WoliumSetup";
  RegisterClassW(&wc);
  RECT r{0, 0, 452, 226};
  AdjustWindowRect(&r, WS_CAPTION | WS_SYSMENU, FALSE);
  HWND w = CreateWindowExW(0, wc.lpszClassName, L"Wolium Setup", WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, CW_USEDEFAULT, CW_USEDEFAULT,
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
