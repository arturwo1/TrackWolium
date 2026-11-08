#include <objbase.h>
#include <shellapi.h>
#include <algorithm>
#include <functional>
#include <fstream>
#include <set>
#include <string>
#include <vector>
#include "inst_common.hpp"

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
    MessageBoxW(nullptr, tr(Key::UnNotWolium), L"Wolium", MB_OK | MB_ICONWARNING);
    return 1;
  }
  Sleep(500);
  inst::kill_in_dir(dir);
  inst::set_autostart(dir, false);
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
    if (!remove_tree_retry(dir + L"\\userdata")) ok = false;
  }
  RemoveDirectoryW(dir.c_str());

  const wchar_t* text = !ok ? tr(Key::UnPartial) : (keep_data ? tr(Key::UnDoneKeep) : tr(Key::UnDoneAll));
  MessageBoxW(nullptr, text, L"Wolium", MB_OK | (ok ? MB_ICONINFORMATION : MB_ICONWARNING));
  return ok ? 0 : 1;
}

}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
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

  std::wstring dir = inst::dir_of(inst::self_path());
  inst::apply_language(dir);
  if (!inst::looks_installed(dir)) {
    MessageBoxW(nullptr, tr(Key::UnRunFromFolder), L"Wolium", MB_OK | MB_ICONWARNING);
    return 1;
  }
  std::wstring q = std::wstring(tr(Key::UnPrompt)) + L"\n" + dir + L"\n\n" + tr(Key::UnChoices);
  int answer = MessageBoxW(nullptr, q.c_str(), L"Wolium", MB_YESNOCANCEL | MB_ICONQUESTION);
  if (answer == IDCANCEL) return 0;
  bool keep = answer == IDNO;

  wchar_t tmp[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, tmp);
  std::wstring copy = std::wstring(tmp, n) + L"wolium_uninstall_" + std::to_wstring(GetCurrentProcessId()) + L".exe";
  if (!CopyFileW(inst::self_path().c_str(), copy.c_str(), FALSE)) {
    MessageBoxW(nullptr, tr(Key::UnPrepare), L"Wolium", MB_OK | MB_ICONWARNING);
    return 1;
  }
  std::wstring cmd = L"\"" + copy + L"\" --finish \"" + dir + L"\" " + (keep ? L"keep" : L"all");
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (CreateProcessW(copy.c_str(), &cmd[0], nullptr, nullptr, FALSE, 0, nullptr, tmp, &si, &pi)) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
  return 0;
}
