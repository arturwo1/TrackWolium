#include "tw/localapi.hpp"
#include <algorithm>
#include <cctype>
#include <ctime>
#include <map>
#include <sstream>

namespace tw {

namespace {

std::string esc(const std::string& s) {
  std::string out;
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c < 0x20) out += ' ';
    else out += static_cast<char>(c);
  }
  return out;
}

std::string lower(std::string s) {
  for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

}

std::string current_json(const Report& report) {
  std::ostringstream o;
  o << "{\"uptime_ms\":" << report.uptime.count() << ",\"apps\":[";
  bool first = true;
  for (const auto& r : report.rows) {
    if (!first) o << ',';
    first = false;
    o << "{\"app\":\"" << esc(r.app) << "\",\"running\":" << (r.running ? "true" : "false") << ",\"state\":\"" << state_name(r.state)
      << "\",\"focused_ms\":" << r.spent[0].count() << ",\"open_ms\":" << r.spent[1].count() << ",\"minimized_ms\":" << r.spent[2].count()
      << ",\"background_ms\":" << r.spent[3].count() << '}';
  }
  o << "]}";
  return o.str();
}

ApiRequest parse_api_request_ex(const std::string& request, int port) {
  ApiRequest out;
  std::size_t hdr_end = request.find("\r\n\r\n");
  std::string head = hdr_end == std::string::npos ? request : request.substr(0, hdr_end);
  std::size_t eol = head.find("\r\n");
  if (eol == std::string::npos) return out;
  std::istringstream line(head.substr(0, eol));
  std::string method, target, version;
  line >> method >> target >> version;
  if ((method != "GET" && method != "POST") || target.empty() || target[0] != '/' || version.rfind("HTTP/1.", 0) != 0) return out;
  std::string host;
  std::istringstream rest(head.substr(eol + 2));
  std::string h;
  while (std::getline(rest, h)) {
    if (!h.empty() && h.back() == '\r') h.pop_back();
    std::size_t colon = h.find(':');
    if (colon == std::string::npos) continue;
    if (lower(h.substr(0, colon)) == "host") {
      host = lower(h.substr(colon + 1));
      std::size_t a = host.find_first_not_of(" \t");
      host = a == std::string::npos ? std::string() : host.substr(a);
    }
  }
  const std::string p = ":" + std::to_string(port);
  if (host != "127.0.0.1" + p && host != "localhost" + p) return out;
  out.method = method;
  out.path = target;
  if (hdr_end != std::string::npos) out.body = request.substr(hdr_end + 4);
  out.ok = true;
  return out;
}

bool parse_api_request(const std::string& request, int port, std::string& path) {
  ApiRequest req = parse_api_request_ex(request, port);
  if (!req.ok || req.method != "GET") return false;
  path = req.path;
  return true;
}

std::string http_response(int status, const std::string& body, const std::string& type) {
  const char* text = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request");
  std::ostringstream o;
  o << "HTTP/1.1 " << status << ' ' << text << "\r\nContent-Type: " << type << "\r\nContent-Length: " << body.size()
    << "\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
    << body;
  return o.str();
}

std::string day_string(long long epoch) {
  std::time_t t = static_cast<std::time_t>(epoch);
  std::tm tm{};
#ifdef _WIN32
  localtime_s(&tm, &t);
#else
  localtime_r(&t, &tm);
#endif
  char buf[16];
  std::strftime(buf, sizeof(buf), "%Y-%m-%d", &tm);
  return buf;
}

int local_slot(long long epoch) {
  std::time_t t = static_cast<std::time_t>(epoch);
  std::tm tm{};
#ifdef _WIN32
  localtime_s(&tm, &t);
#else
  localtime_r(&t, &tm);
#endif
  int s = (tm.tm_hour * 3600 + tm.tm_min * 60 + tm.tm_sec) / 300;
  return std::max(0, std::min(287, s));
}

namespace {

const char* kJson = "application/json; charset=utf-8";

std::string query_value(const std::string& query, const std::string& key) {
  std::size_t pos = 0;
  while (pos <= query.size()) {
    std::size_t end = query.find('&', pos);
    if (end == std::string::npos) end = query.size();
    std::string part = query.substr(pos, end - pos);
    std::size_t eq = part.find('=');
    if (eq != std::string::npos && part.substr(0, eq) == key) return part.substr(eq + 1);
    pos = end + 1;
  }
  return std::string();
}

long long query_int(const std::string& query, const std::string& key, long long fallback, long long lo, long long hi) {
  std::string v = query_value(query, key);
  if (v.empty() || v.size() > 9) return fallback;
  for (char c : v) {
    if (c < '0' || c > '9') return fallback;
  }
  return std::max(lo, std::min(hi, std::stoll(v)));
}

struct Totals {
  long long ms[4] = {0, 0, 0, 0};
  std::string name;
  long long sum() const { return ms[0] + ms[1] + ms[2] + ms[3]; }
};

void put_totals(std::ostringstream& o, const long long* ms) {
  o << "\"focused_ms\":" << ms[0] << ",\"open_ms\":" << ms[1] << ",\"minimized_ms\":" << ms[2] << ",\"background_ms\":" << ms[3]
    << ",\"total_ms\":" << (ms[0] + ms[1] + ms[2] + ms[3]);
}

std::string top_body(const std::map<std::string, Totals>& apps, const std::string& metric, int limit) {
  std::vector<std::pair<std::string, Totals>> list(apps.begin(), apps.end());
  auto key = [&](const Totals& t) {
    if (metric == "open") return t.ms[1];
    if (metric == "minimized") return t.ms[2];
    if (metric == "background") return t.ms[3];
    if (metric == "all") return t.sum();
    return t.ms[0];
  };
  std::sort(list.begin(), list.end(), [&](const auto& a, const auto& b) {
    long long x = key(a.second), y = key(b.second);
    return x != y ? x > y : a.first < b.first;
  });
  std::ostringstream o;
  o << '[';
  int n = 0;
  for (const auto& e : list) {
    if (n >= limit || key(e.second) <= 0) break;
    if (n++) o << ',';
    o << "{\"app\":\"" << esc(e.first) << "\",\"name\":\"" << esc(e.second.name.empty() ? e.first : e.second.name) << "\",";
    put_totals(o, e.second.ms);
    o << '}';
  }
  o << ']';
  return o.str();
}

std::string metric_of(const std::string& q) {
  std::string m = query_value(q, "metric");
  return (m == "open" || m == "minimized" || m == "background" || m == "all") ? m : "focused";
}

int hex_val(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

bool parse_hex4(const std::string& s, std::size_t pos, unsigned int& out) {
  if (pos + 4 > s.size()) return false;
  unsigned int v = 0;
  for (int i = 0; i < 4; ++i) {
    int h = hex_val(s[pos + i]);
    if (h < 0) return false;
    v = (v << 4) | static_cast<unsigned int>(h);
  }
  out = v;
  return true;
}

void append_utf8(std::string& out, unsigned int cp) {
  if (cp < 0x80) {
    out.push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp <= 0x10FFFF) {
    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

bool json_string(const std::string& json, const std::string& key, std::string& out) {
  std::string pat = "\"" + key + "\"";
  std::size_t p = json.find(pat);
  if (p == std::string::npos) return false;
  p = json.find(':', p + pat.size());
  if (p == std::string::npos) return false;
  p = json.find_first_not_of(" \t\r\n", p + 1);
  if (p == std::string::npos || json[p] != '"') return false;
  ++p;
  std::string val;
  while (p < json.size() && json[p] != '"') {
    if (json[p] == '\\' && p + 1 < json.size()) {
      char next = json[++p];
      if (next == 'n' || next == 'r' || next == 't' || next == 'b' || next == 'f') {
        val.push_back(' ');
      } else if (next == 'u') {
        unsigned int hi = 0;
        if (parse_hex4(json, p + 1, hi)) {
          p += 4;
          if (hi >= 0xD800 && hi <= 0xDBFF && p + 6 < json.size() && json[p + 1] == '\\' && json[p + 2] == 'u') {
            unsigned int lo = 0;
            if (parse_hex4(json, p + 3, lo) && lo >= 0xDC00 && lo <= 0xDFFF) {
              p += 6;
              append_utf8(val, 0x10000 + (((hi - 0xD800) << 10) | (lo - 0xDC00)));
            }
          } else {
            append_utf8(val, hi);
          }
        }
      } else {
        val.push_back(next);
      }
      ++p;
      continue;
    }
    val.push_back(json[p++]);
  }
  if (p >= json.size() || json[p] != '"') return false;
  out = val;
  return true;
}

bool json_int(const std::string& json, const std::string& key, long long& out) {
  std::string pat = "\"" + key + "\"";
  std::size_t p = json.find(pat);
  if (p == std::string::npos) return false;
  p = json.find(':', p + pat.size());
  if (p == std::string::npos) return false;
  p = json.find_first_not_of(" \t\r\n", p + 1);
  if (p == std::string::npos) return false;
  std::size_t end = p;
  while (end < json.size() && std::isdigit(static_cast<unsigned char>(json[end]))) ++end;
  if (end == p || end - p > 12) return false;
  out = std::stoll(json.substr(p, end - p));
  return true;
}

std::string utf8_truncate(const std::string& s, std::size_t max_bytes) {
  if (s.size() <= max_bytes) return s;
  std::size_t cut = max_bytes;
  while (cut > 0 && (static_cast<unsigned char>(s[cut]) & 0xC0) == 0x80) --cut;
  return s.substr(0, cut);
}

std::string clean_token(std::string s, std::size_t max_len) {
  for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.erase(s.begin());
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.pop_back();
  if (s.size() > max_len) s.resize(max_len);
  for (char c : s) {
    unsigned char u = static_cast<unsigned char>(c);
    if (!(std::isalnum(u) || c == '.' || c == '-' || c == '_' || c == ':')) return {};
  }
  return s;
}

std::string clean_title(std::string s, std::size_t max_bytes) {
  for (char& c : s) {
    if (static_cast<unsigned char>(c) < 0x20) c = ' ';
  }
  std::string out;
  out.reserve(s.size());
  bool prev_space = true;
  for (unsigned char u : s) {
    if (u == ' ' || u == '\t') {
      if (!prev_space) out.push_back(' ');
      prev_space = true;
    } else {
      out.push_back(static_cast<char>(u));
      prev_space = false;
    }
  }
  if (!out.empty() && out.back() == ' ') out.pop_back();
  return utf8_truncate(out, max_bytes);
}

std::string clean_url(std::string s, std::size_t max_bytes) {
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.erase(s.begin());
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.pop_back();
  if (s.empty()) return {};
  std::string head = lower(s.substr(0, 8));
  if (head.rfind("http://", 0) != 0 && head.rfind("https://", 0) != 0) return {};
  for (unsigned char u : s) {
    if (u < 0x20 || u == ' ' || u == '<' || u == '>') return {};
  }
  return utf8_truncate(s, max_bytes);
}

std::string url_decode(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '+') {
      out.push_back(' ');
    } else if (s[i] == '%' && i + 2 < s.size()) {
      int hi = hex_val(s[i + 1]);
      int lo = hex_val(s[i + 2]);
      if (hi >= 0 && lo >= 0) {
        out.push_back(static_cast<char>((hi << 4) | lo));
        i += 2;
      } else {
        out.push_back(s[i]);
      }
    } else {
      out.push_back(s[i]);
    }
  }
  return out;
}

std::string html_escape(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (unsigned char c : s) {
    if (c == '&') out += "&amp;";
    else if (c == '<') out += "&lt;";
    else if (c == '>') out += "&gt;";
    else if (c == '"') out += "&quot;";
    else if (c == '\'') out += "&#39;";
    else if (c >= 0x20 || c == '\t' || c == '\n') out.push_back(static_cast<char>(c));
  }
  return out;
}

std::string js_string_escape(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (unsigned char c : s) {
    if (c == '\\') out += "\\\\";
    else if (c == '"') out += "\\\"";
    else if (c == '\'') out += "\\'";
    else if (c == '<') out += "\\u003c";
    else if (c == '>') out += "\\u003e";
    else if (c == '&') out += "\\u0026";
    else if (c < 0x20) out.push_back(' ');
    else out.push_back(static_cast<char>(c));
  }
  return out;
}

std::string ext_setup_html(const std::string& query) {
  std::string ext_url = utf8_truncate(url_decode(query_value(query, "url")), 256);
  std::string browser = utf8_truncate(url_decode(query_value(query, "browser")), 80);
  std::string dir = utf8_truncate(url_decode(query_value(query, "dir")), 512);
  std::string lang = lower(url_decode(query_value(query, "lang")));
  if (ext_url.empty()) ext_url = "chrome://extensions";
  bool ru = lang.rfind("ru", 0) == 0;
  std::string title = ru ? "Wolium — установка расширения браузера" : "Wolium — Browser extension setup";
  std::string heading = ru ? "Установка расширения Wolium" : "Wolium browser extension setup";
  std::string lead = ru
      ? "Браузеры из соображений безопасности не позволяют другим программам открывать служебные вкладки (chrome://, opera://, edge://) напрямую. Нужный адрес уже скопирован в буфер обмена."
      : "For security, browsers block external apps from opening internal pages (chrome://, opera://, edge://) directly. The exact address has already been copied to your clipboard.";
  std::string step1 = ru ? "1. Откройте страницу расширений в этой вкладке" : "1. Open the extensions page in this tab";
  std::string step1Hint = ru ? "Нажмите адресную строку (Ctrl+L), вставьте адрес (Ctrl+V) и нажмите Enter:" : "Focus the address bar (Ctrl+L), paste the address (Ctrl+V) and press Enter:";
  std::string step2 = ru ? "2. Включите режим разработчика и загрузите папку расширения" : "2. Enable Developer mode and load the extension folder";
  std::string step2Hint = ru ? "Включите «Режим разработчика», нажмите «Загрузить распакованное расширение» и выберите папку:" : "Enable \"Developer mode\", click \"Load unpacked\" and select this folder:";
  std::string step3 = ru ? "3. Закрепите иконку Wolium и обновляйте при апдейтах" : "3. Pin the Wolium icon & reload after updates";
  std::string step3Hint = ru ? "Закрепите значок Wolium на панели браузера (иконка пазла → булавка) — по клику на него на любом сайте видно статус подключения и кнопку паузы. После обновления Wolium нажимайте кнопку обновления (↻) у расширения." : "Pin Wolium to the browser toolbar (puzzle icon → pin) — clicking it on any website shows tracking status and a quick pause switch. After updating Wolium, click Reload (↻) on the extension.";
  std::string copyBtn = ru ? "Копировать" : "Copy";
  std::string copiedBtn = ru ? "Скопировано!" : "Copied!";

  std::ostringstream o;
  o << "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    << "<title>" << html_escape(title) << "</title>"
    << "<style>:root{--bg:#0b1017;--card:#131b26;--soft:#1c2736;--line:#263447;--fg:#f1f5f9;--dim:#94a3b8;--accent:#4aa3ff;--ok:#3ba55d}"
    << "*{box-sizing:border-box}body{margin:0;min-height:100vh;background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,\"Segoe UI\",Roboto,sans-serif;display:flex;align-items:center;justify-content:center;padding:24px}"
    << ".wrap{max-width:680px;width:100%;background:var(--card);border:1px solid var(--line);border-radius:16px;padding:28px;box-shadow:0 20px 50px rgba(0,0,0,.45)}"
    << ".badge{display:inline-block;padding:4px 10px;border-radius:999px;background:rgba(74,163,255,.14);color:var(--accent);font-size:12px;font-weight:700;margin-bottom:10px}"
    << "h1{margin:0 0 8px;font-size:24px;font-weight:800}p.lead{margin:0 0 22px;color:var(--dim);font-size:14px;line-height:1.5}"
    << ".step{background:var(--soft);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:14px}"
    << ".step h2{margin:0 0 6px;font-size:15px;font-weight:800}.step p{margin:0 0 10px;color:var(--dim);font-size:13px;line-height:1.45}"
    << ".row{display:flex;gap:8px;align-items:center}.code{flex:1;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:10px 12px;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:13px;color:var(--fg);overflow-x:auto;white-space:nowrap;user-select:all}"
    << "button{background:var(--accent);color:#06121f;border:none;border-radius:8px;padding:10px 16px;font-weight:800;font-size:13px;cursor:pointer;white-space:nowrap}button.ok{background:var(--ok);color:#fff}"
    << ".keys{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.kbd{background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:4px 8px;font-size:12px;font-weight:700;color:var(--dim)}</style></head>"
    << "<body><div class=\"wrap\"><div class=\"badge\">Wolium" << (browser.empty() ? "" : " · " + html_escape(browser)) << "</div>"
    << "<h1>" << html_escape(heading) << "</h1><p class=\"lead\">" << html_escape(lead) << "</p>"
    << "<div class=\"step\"><h2>" << html_escape(step1) << "</h2><p>" << html_escape(step1Hint) << "</p>"
    << "<div class=\"row\"><div class=\"code\" id=\"u\">" << html_escape(ext_url) << "</div>"
    << "<button onclick=\"cp(this,'" << js_string_escape(ext_url) << "')\">" << html_escape(copyBtn) << "</button></div>"
    << "<div class=\"keys\"><span class=\"kbd\">Ctrl / Cmd + L</span><span class=\"kbd\">Ctrl / Cmd + V</span><span class=\"kbd\">Enter</span></div></div>";
  if (!dir.empty()) {
    o << "<div class=\"step\"><h2>" << html_escape(step2) << "</h2><p>" << html_escape(step2Hint) << "</p>"
      << "<div class=\"row\"><div class=\"code\" id=\"d\">" << html_escape(dir) << "</div>"
      << "<button onclick=\"cp(this,'" << js_string_escape(dir) << "')\">" << html_escape(copyBtn) << "</button></div></div>";
  }
  o << "<div class=\"step\"><h2>" << html_escape(step3) << "</h2><p style=\"margin-bottom:0\">" << html_escape(step3Hint) << "</p></div>"
    << "</div><script>function cp(btn,val){navigator.clipboard.writeText(val).then(function(){var t=btn.textContent;btn.textContent='" << js_string_escape(copiedBtn)
    << "';btn.classList.add('ok');setTimeout(function(){btn.textContent=t;btn.classList.remove('ok');},1600);});}</script></body></html>";
  return o.str();
}

}

ApiReply route_api(const std::string& target, const std::string& current, ApiData* data, long long now) {
  return route_api("GET", target, "", current, data, now);
}

ApiReply route_api(const std::string& method, const std::string& target, const std::string& req_body, const std::string& current, ApiData* data, long long now) {
  std::size_t qm = target.find('?');
  std::string path = target.substr(0, qm);
  std::string query = qm == std::string::npos ? std::string() : target.substr(qm + 1);
  if (path.size() > 1 && path.back() == '/') path.pop_back();
  if (method == "POST") {
    if (path != "/v1/browser") return {404, kJson, "{\"error\":\"not found\"}"};
    std::string browser, domain, title, url;
    long long ms = 0;
    if (!json_string(req_body, "browser", browser) || !json_string(req_body, "domain", domain) || !json_int(req_body, "ms", ms)) {
      return {400, kJson, "{\"error\":\"bad payload\"}"};
    }
    json_string(req_body, "title", title);
    json_string(req_body, "url", url);
    browser = clean_token(browser, 64);
    domain = clean_token(domain, 192);
    title = clean_title(title, 180);
    url = clean_url(url, 512);
    {
      std::string lt = lower(title);
      std::string ld = lower(domain);
      std::string bare_d = ld.rfind("www.", 0) == 0 ? ld.substr(4) : ld;
      auto starts = [&](const std::string& p) { return lt.rfind(p, 0) == 0; };
      bool bad = lt.empty() || lt == ld || lt == "www." + ld || lt == bare_d ||
                 starts("http://") || starts("https://") || starts("file://") ||
                 starts("about:") || starts("chrome:") || starts("chrome-extension:") ||
                 starts("edge:") || starts("opera:") || starts("brave:") ||
                 starts("vivaldi:") || starts("moz-extension:") ||
                 starts(ld + "/") || starts("www." + ld + "/") || starts(bare_d + "/") ||
                 starts(ld + ":") || starts("www." + ld + ":");
      if (!bad && lt.find(' ') == std::string::npos) {
        std::size_t sl = lt.find('/');
        if (sl != std::string::npos && lt.find('.') < sl) bad = true;
      }
      if (bad) title.clear();
    }
    if (browser.empty() || domain.empty() || ms <= 0 || ms > 3600000) {
      return {400, kJson, "{\"error\":\"bad payload\"}"};
    }
    if (data) data->add_browser_usage(day_string(now), local_slot(now), browser, domain, title, url, ms);
    return {200, kJson, "{\"ok\":true}"};
  }
  if (path == "/widget") return {200, "text/html; charset=utf-8", widget_html()};
  if (path == "/ext-setup") return {200, "text/html; charset=utf-8", ext_setup_html(query)};
  if (path == "/v1/current") return {200, kJson, current.empty() ? "{\"apps\":[]}" : current};
  if (path == "/v1/browser/top") {
    int days = static_cast<int>(query_int(query, "days", 1, 1, 90));
    int limit = static_cast<int>(query_int(query, "limit", 10, 1, 100));
    std::string to = day_string(now);
    std::string from = day_string(now - static_cast<long long>(days - 1) * 86400);
    std::vector<BrowserRow> rows = data ? data->browser_usage(from, to) : std::vector<BrowserRow>();
    struct BrowserAgg {
      long long ms = 0;
      std::string title;
      std::string url;
    };
    std::map<std::pair<std::string, std::string>, BrowserAgg> agg;
    for (const auto& r : rows) {
      if (r.ms <= 0) continue;
      auto& a = agg[{r.browser, r.domain}];
      a.ms += r.ms;
      if (!r.title.empty()) a.title = r.title;
      if (!r.url.empty()) a.url = r.url;
    }
    std::vector<BrowserRow> sorted;
    sorted.reserve(agg.size());
    for (const auto& kv : agg) sorted.push_back({kv.first.first, kv.first.second, kv.second.ms, kv.second.title, kv.second.url});
    std::sort(sorted.begin(), sorted.end(), [](const BrowserRow& a, const BrowserRow& b) {
      if (a.ms != b.ms) return a.ms > b.ms;
      if (a.domain != b.domain) return a.domain < b.domain;
      return a.browser < b.browser;
    });
    std::ostringstream o;
    o << "{\"from\":\"" << from << "\",\"to\":\"" << to << "\",\"days\":" << days << ",\"domains\":[";
    int n = 0;
    for (const auto& r : sorted) {
      if (n >= limit) break;
      if (n++) o << ',';
      o << "{\"browser\":\"" << esc(r.browser) << "\",\"domain\":\"" << esc(r.domain) << "\",\"title\":\"" << esc(r.title) << "\",\"url\":\"" << esc(r.url) << "\",\"ms\":" << r.ms << '}';
    }
    o << "]}";
    return {200, kJson, o.str()};
  }
  bool summary = path == "/v1/summary" || path == "/v1/stats";
  bool top = path == "/v1/apps/top";
  if (summary || top) {
    int days = static_cast<int>(query_int(query, "days", summary ? 7 : 1, 1, 90));
    std::string to = day_string(now);
    std::string from = day_string(now - static_cast<long long>(days - 1) * 86400);
    std::vector<UsageRow> rows = data ? data->usage(from, to) : std::vector<UsageRow>();
    std::map<std::string, Totals> apps;
    std::map<std::string, Totals> by_day;
    Totals all;
    for (const auto& r : rows) {
      if (r.state < 0 || r.state > 3) continue;
      auto& a = apps[r.app];
      if (a.name.empty()) a.name = r.name;
      a.ms[r.state] += r.ms;
      by_day[r.day].ms[r.state] += r.ms;
      all.ms[r.state] += r.ms;
    }
    std::ostringstream o;
    if (top) {
      int limit = static_cast<int>(query_int(query, "limit", 5, 1, 50));
      std::string metric = metric_of(query);
      o << "{\"from\":\"" << from << "\",\"to\":\"" << to << "\",\"days\":" << days << ",\"metric\":\"" << metric << "\",\"apps\":" << top_body(apps, metric, limit) << '}';
      return {200, kJson, o.str()};
    }
    o << "{\"from\":\"" << from << "\",\"to\":\"" << to << "\",\"days\":" << days << ",\"apps_count\":" << apps.size() << ",";
    put_totals(o, all.ms);
    o << ",\"by_day\":[";
    bool first = true;
    for (const auto& d : by_day) {
      if (!first) o << ',';
      first = false;
      o << "{\"day\":\"" << d.first << "\",";
      put_totals(o, d.second.ms);
      o << '}';
    }
    o << "],\"top\":" << top_body(apps, metric_of(query), 5) << '}';
    return {200, kJson, o.str()};
  }
  if (path == "/v1/sessions") {
    long long hours = query_int(query, "hours", 24, 1, 24 * 90);
    int limit = static_cast<int>(query_int(query, "limit", 100, 1, 500));
    std::vector<SessionRow> rows = data ? data->sessions(now - hours * 3600, now, limit) : std::vector<SessionRow>();
    std::ostringstream o;
    o << "{\"hours\":" << hours << ",\"sessions\":[";
    bool first = true;
    for (const auto& r : rows) {
      if (!first) o << ',';
      first = false;
      o << "{\"app\":\"" << esc(r.app) << "\",\"name\":\"" << esc(r.name.empty() ? r.app : r.name) << "\",\"state\":\"" << state_name(static_cast<State>(r.state))
        << "\",\"start\":" << r.start << ",\"stop\":" << r.stop << '}';
    }
    o << "]}";
    return {200, kJson, o.str()};
  }
  return {404, kJson, "{\"error\":\"not found\"}"};
}

}
