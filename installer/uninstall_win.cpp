#include <objbase.h>
#include <shellapi.h>
#include <string>
#include "inst_common.hpp"

namespace {

bool remove_tree(const std::wstring& dir) {
  for (int i = 0; i < 20; ++i) {
    std::error_code ec;
    std::filesystem::remove_all(std::filesystem::path(dir), ec);
    if (!std::filesystem::exists(std::filesystem::path(dir), ec)) return true;
    Sleep(500);
  }
  return false;
}

int finish(const std::wstring& dir) {
  if (!inst::looks_installed(dir)) {
    MessageBoxW(nullptr, L"This is not a Wolium folder, nothing was deleted.", inst::kAppName, MB_OK | MB_ICONWARNING);
    return 1;
  }
  Sleep(500);
  inst::kill_in_dir(dir);
  inst::set_autostart(dir, false);
  std::error_code ec;
  std::filesystem::remove(inst::desktop_link(), ec);
  std::filesystem::remove(inst::start_menu_link(), ec);
  bool ok = remove_tree(dir);
  MessageBoxW(nullptr, ok ? L"Wolium and its history were removed." : L"Some files could not be removed. Close programs using this folder and delete it manually.",
              inst::kAppName, MB_OK | (ok ? MB_ICONINFORMATION : MB_ICONWARNING));
  return ok ? 0 : 1;
}

}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv && argc >= 3 && std::wstring(argv[1]) == L"--finish") {
    std::wstring dir = argv[2];
    LocalFree(argv);
    return finish(dir);
  }
  if (argv) LocalFree(argv);

  std::wstring dir = inst::dir_of(inst::self_path());
  if (!inst::looks_installed(dir)) {
    MessageBoxW(nullptr, L"Run uninstall.exe from the Wolium folder.", inst::kAppName, MB_OK | MB_ICONWARNING);
    return 1;
  }
  std::wstring q = L"Remove Wolium and all its data (including history) from\n" + dir + L"?";
  if (MessageBoxW(nullptr, q.c_str(), inst::kAppName, MB_YESNO | MB_ICONQUESTION) != IDYES) return 0;

  wchar_t tmp[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, tmp);
  std::wstring copy = std::wstring(tmp, n) + L"wolium_uninstall_" + std::to_wstring(GetCurrentProcessId()) + L".exe";
  if (!CopyFileW(inst::self_path().c_str(), copy.c_str(), FALSE)) {
    MessageBoxW(nullptr, L"Could not prepare the uninstall.", inst::kAppName, MB_OK | MB_ICONWARNING);
    return 1;
  }
  std::wstring cmd = L"\"" + copy + L"\" --finish \"" + dir + L"\"";
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (CreateProcessW(copy.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, tmp, &si, &pi)) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
  return 0;
}
