#pragma once
#include <windows.h>
#include <tlhelp32.h>
#include <shlobj.h>
#include <filesystem>
#include <string>
#include "tw/i18n.hpp"

namespace inst {

constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"Wolium";
constexpr wchar_t kAppName[] = L"Wolium";

inline std::wstring lower(std::wstring s) {
  for (auto& c : s) c = static_cast<wchar_t>(towlower(c));
  return s;
}

inline std::wstring self_path() {
  wchar_t buf[MAX_PATH * 2];
  DWORD n = GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(sizeof(buf) / sizeof(buf[0])));
  return std::wstring(buf, n);
}

inline std::wstring dir_of(const std::wstring& p) {
  std::size_t i = p.find_last_of(L"\\/");
  return i == std::wstring::npos ? std::wstring() : p.substr(0, i);
}

inline bool is_inside(const std::wstring& path, const std::wstring& dir) {
  std::wstring p = lower(path), d = lower(dir);
  if (!d.empty() && d.back() != L'\\') d += L'\\';
  return p.compare(0, d.size(), d) == 0;
}

inline void kill_in_dir(const std::wstring& dir) {
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return;
  PROCESSENTRY32W pe{};
  pe.dwSize = sizeof(pe);
  DWORD me = GetCurrentProcessId();
  if (Process32FirstW(snap, &pe)) {
    do {
      if (pe.th32ProcessID == me) continue;
      HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pe.th32ProcessID);
      if (!h) continue;
      wchar_t buf[MAX_PATH * 2];
      DWORD n = static_cast<DWORD>(sizeof(buf) / sizeof(buf[0]));
      if (QueryFullProcessImageNameW(h, 0, buf, &n) && is_inside(std::wstring(buf, n), dir)) {
        TerminateProcess(h, 0);
        WaitForSingleObject(h, 3000);
      }
      CloseHandle(h);
    } while (Process32NextW(snap, &pe));
  }
  CloseHandle(snap);
}

inline void set_autostart(const std::wstring& dir, bool on) {
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return;
  if (on) {
    std::wstring cmd = L"\"" + dir + L"\\trackwolium.exe\" --background";
    RegSetValueExW(key, kRunValue, 0, REG_SZ, reinterpret_cast<const BYTE*>(cmd.c_str()),
                   static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t)));
  } else {
    RegDeleteValueW(key, kRunValue);
  }
  RegCloseKey(key);
}

inline std::wstring known_folder(REFKNOWNFOLDERID id) {
  PWSTR p = nullptr;
  std::wstring out;
  if (SUCCEEDED(SHGetKnownFolderPath(id, 0, nullptr, &p)) && p) out = p;
  CoTaskMemFree(p);
  return out;
}

inline std::wstring desktop_link() { return known_folder(FOLDERID_Desktop) + L"\\Wolium.lnk"; }
inline std::wstring start_menu_link() { return known_folder(FOLDERID_Programs) + L"\\Wolium.lnk"; }

inline bool make_link(const std::wstring& link, const std::wstring& target, const std::wstring& dir) {
  IShellLinkW* sl = nullptr;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_IShellLinkW, reinterpret_cast<void**>(&sl)))) return false;
  sl->SetPath(target.c_str());
  sl->SetWorkingDirectory(dir.c_str());
  IPersistFile* pf = nullptr;
  bool ok = false;
  if (SUCCEEDED(sl->QueryInterface(IID_IPersistFile, reinterpret_cast<void**>(&pf)))) {
    ok = SUCCEEDED(pf->Save(link.c_str(), TRUE));
    pf->Release();
  }
  sl->Release();
  return ok;
}

inline std::wstring data_dir() { return known_folder(FOLDERID_LocalAppData) + L"\\DTSys\\Wolium"; }

inline std::wstring lang_file(const std::wstring&) { return data_dir() + L"\\lang"; }

inline std::wstring version_file(const std::wstring& dir) { return dir + L"\\version.txt"; }

inline std::wstring installed_version(const std::wstring& dir) {
  std::wstring out;
  HANDLE h = CreateFileW(version_file(dir).c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
  if (h == INVALID_HANDLE_VALUE) return out;
  char buf[64] = {};
  DWORD n = 0;
  ReadFile(h, buf, sizeof(buf) - 1, &n, nullptr);
  CloseHandle(h);
  for (DWORD i = 0; i < n && buf[i] > ' '; ++i) out += static_cast<wchar_t>(buf[i]);
  return out;
}

inline void write_version(const std::wstring& dir, const std::wstring& v) {
  HANDLE h = CreateFileW(version_file(dir).c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
  if (h == INVALID_HANDLE_VALUE) return;
  std::string a;
  for (wchar_t c : v) a += static_cast<char>(c);
  DWORD n = 0;
  WriteFile(h, a.data(), static_cast<DWORD>(a.size()), &n, nullptr);
  CloseHandle(h);
}

inline void apply_language(const std::wstring& dir) {
  tw::i18n::load(std::filesystem::path(lang_file(dir)), GetUserDefaultUILanguage());
}

constexpr wchar_t kUninstallKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\DTSys.Wolium";

inline void reg_set(HKEY key, const wchar_t* name, const std::wstring& v) {
  RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(v.c_str()), static_cast<DWORD>((v.size() + 1) * sizeof(wchar_t)));
}

inline void register_uninstall(const std::wstring& dir, const std::wstring& version) {
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kUninstallKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return;
  reg_set(key, L"DisplayName", L"Wolium");
  reg_set(key, L"DisplayIcon", dir + L"\\wolium.exe");
  reg_set(key, L"Publisher", L"DTSys");
  reg_set(key, L"DisplayVersion", version);
  reg_set(key, L"InstallLocation", dir);
  reg_set(key, L"UninstallString", L"\"" + dir + L"\\uninstall.exe\"");
  DWORD one = 1;
  RegSetValueExW(key, L"NoModify", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&one), sizeof(one));
  RegSetValueExW(key, L"NoRepair", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&one), sizeof(one));
  RegCloseKey(key);
}

inline void unregister_uninstall() { RegDeleteKeyW(HKEY_CURRENT_USER, kUninstallKey); }

inline int compare_versions(const std::wstring& a, const std::wstring& b) {
  auto next = [](const std::wstring& s, std::size_t& i) {
    long v = 0;
    while (i < s.size() && s[i] != L'.') {
      if (s[i] >= L'0' && s[i] <= L'9') v = v * 10 + (s[i] - L'0');
      ++i;
    }
    if (i < s.size()) ++i;
    return v;
  };
  std::size_t i = 0, j = 0;
  while (i < a.size() || j < b.size()) {
    long x = next(a, i), y = next(b, j);
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

inline bool looks_installed(const std::wstring& dir) {
  std::error_code ec;
  return std::filesystem::exists(dir + L"\\trackwolium.exe", ec) && std::filesystem::exists(dir + L"\\uninstall.exe", ec);
}

}
