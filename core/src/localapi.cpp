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
    if (json[p] == '\\' && p + 1 < json.size()) ++p;
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
    std::string browser, domain;
    long long ms = 0;
    if (!json_string(req_body, "browser", browser) || !json_string(req_body, "domain", domain) || !json_int(req_body, "ms", ms)) {
      return {400, kJson, "{\"error\":\"bad payload\"}"};
    }
    browser = clean_token(browser, 64);
    domain = clean_token(domain, 192);
    if (browser.empty() || domain.empty() || ms <= 0 || ms > 3600000) {
      return {400, kJson, "{\"error\":\"bad payload\"}"};
    }
    if (data) data->add_browser_usage(day_string(now), browser, domain, ms);
    return {200, kJson, "{\"ok\":true}"};
  }
  if (path == "/widget") return {200, "text/html; charset=utf-8", widget_html()};
  if (path == "/v1/current") return {200, kJson, current.empty() ? "{\"apps\":[]}" : current};
  if (path == "/v1/browser/top") {
    int days = static_cast<int>(query_int(query, "days", 1, 1, 90));
    int limit = static_cast<int>(query_int(query, "limit", 10, 1, 100));
    std::string to = day_string(now);
    std::string from = day_string(now - static_cast<long long>(days - 1) * 86400);
    std::vector<BrowserRow> rows = data ? data->browser_usage(from, to) : std::vector<BrowserRow>();
    std::map<std::pair<std::string, std::string>, long long> agg;
    for (const auto& r : rows) {
      if (r.ms > 0) agg[{r.browser, r.domain}] += r.ms;
    }
    std::vector<BrowserRow> sorted;
    sorted.reserve(agg.size());
    for (const auto& kv : agg) sorted.push_back({kv.first.first, kv.first.second, kv.second});
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
      o << "{\"browser\":\"" << esc(r.browser) << "\",\"domain\":\"" << esc(r.domain) << "\",\"ms\":" << r.ms << '}';
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
