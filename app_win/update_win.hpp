#pragma once
#include <cstdio>
#include <string>
#include <vector>
#include <winhttp.h>
#include "common_win.hpp"

namespace app {

inline bool http_get(const std::wstring& url, std::string& out) {
  URL_COMPONENTSW uc{};
  uc.dwStructSize = sizeof(uc);
  wchar_t host[256] = {};
  wchar_t path[2048] = {};
  uc.lpszHostName = host;
  uc.dwHostNameLength = 256;
  uc.lpszUrlPath = path;
  uc.dwUrlPathLength = 2048;
  if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return false;
  HINTERNET session = WinHttpOpen(L"Wolium", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (!session) return false;
  WinHttpSetTimeouts(session, 8000, 8000, 10000, 15000);
  bool ok = false;
  HINTERNET con = WinHttpConnect(session, host, uc.nPort, 0);
  if (con) {
    DWORD flags = uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET req = WinHttpOpenRequest(con, L"GET", path, nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (req) {
      const wchar_t* headers = L"Accept: application/vnd.github+json\r\n";
      if (WinHttpSendRequest(req, headers, static_cast<DWORD>(-1), WINHTTP_NO_REQUEST_DATA, 0, 0, 0) && WinHttpReceiveResponse(req, nullptr)) {
        DWORD code = 0;
        DWORD size = sizeof(code);
        WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &code, &size, WINHTTP_NO_HEADER_INDEX);
        if (code == 200) {
          ok = true;
          char buf[8192];
          DWORD got = 0;
          while (WinHttpReadData(req, buf, sizeof(buf), &got) && got > 0) out.append(buf, got);
        }
      }
      WinHttpCloseHandle(req);
    }
    WinHttpCloseHandle(con);
  }
  WinHttpCloseHandle(session);
  return ok;
}

inline bool json_value(const std::string& s, const std::string& key, size_t& pos, std::string& value) {
  std::string needle = "\"" + key + "\"";
  size_t p = s.find(needle, pos);
  if (p == std::string::npos) return false;
  p = s.find(':', p + needle.size());
  if (p == std::string::npos) return false;
  ++p;
  while (p < s.size() && (s[p] == ' ' || s[p] == '\n' || s[p] == '\r' || s[p] == '\t')) ++p;
  if (p >= s.size() || s[p] != '"') {
    pos = p;
    return json_value(s, key, pos, value);
  }
  size_t e = s.find('"', p + 1);
  if (e == std::string::npos) return false;
  value = s.substr(p + 1, e - p - 1);
  pos = e + 1;
  return true;
}

inline std::string trim(const std::string& s) {
  size_t a = s.find_first_not_of(" \r\n\t");
  if (a == std::string::npos) return "";
  size_t b = s.find_last_not_of(" \r\n\t");
  return s.substr(a, b - a + 1);
}

inline int compare_versions(const std::string& a, const std::string& b) {
  auto parts = [](const std::string& v) {
    std::vector<int> out;
    int cur = 0;
    bool any = false;
    for (char c : v) {
      if (c >= '0' && c <= '9') {
        cur = cur * 10 + (c - '0');
        any = true;
      } else if (c == '.') {
        out.push_back(any ? cur : 0);
        cur = 0;
        any = false;
      }
    }
    out.push_back(any ? cur : 0);
    return out;
  };
  std::vector<int> x = parts(a);
  std::vector<int> y = parts(b);
  size_t n = x.size() > y.size() ? x.size() : y.size();
  for (size_t i = 0; i < n; ++i) {
    int p = i < x.size() ? x[i] : 0;
    int q = i < y.size() ? y[i] : 0;
    if (p != q) return p < q ? -1 : 1;
  }
  return 0;
}

inline std::string latest_version() {
  std::string api;
  if (!http_get(L"https://api.github.com/repos/arturwo1/trackwolium/releases/latest", api)) return "";
  size_t pos = 0;
  std::string name;
  std::string version_url;
  bool has_setup = false;
  while (json_value(api, "name", pos, name)) {
    if (name == "WoliumSetup.exe") has_setup = true;
    if (name == "version.txt") {
      size_t at = pos;
      json_value(api, "browser_download_url", at, version_url);
    }
  }
  if (!has_setup || version_url.empty()) return "";
  std::string body;
  if (!http_get(std::wstring(version_url.begin(), version_url.end()), body)) return "";
  return trim(body);
}

inline std::string installed_version() {
  std::string out;
  FILE* f = nullptr;
  if (_wfopen_s(&f, sibling(L"version.txt").c_str(), L"rb") != 0 || !f) return "";
  char buf[128];
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  out.assign(buf, n);
  return trim(out);
}

}
