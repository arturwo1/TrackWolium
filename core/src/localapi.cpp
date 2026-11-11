#include "tw/localapi.hpp"
#include <cctype>
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

bool parse_api_request(const std::string& request, int port, std::string& path) {
  std::size_t eol = request.find("\r\n");
  if (eol == std::string::npos) return false;
  std::istringstream line(request.substr(0, eol));
  std::string method, target, version;
  line >> method >> target >> version;
  if (method != "GET" || target.empty() || target[0] != '/' || version.rfind("HTTP/1.", 0) != 0) return false;
  std::string host;
  std::istringstream rest(request.substr(eol + 2));
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
  if (host != "127.0.0.1" + p && host != "localhost" + p) return false;
  path = target;
  return true;
}

std::string http_response(int status, const std::string& body) {
  const char* text = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request");
  std::ostringstream o;
  o << "HTTP/1.1 " << status << ' ' << text << "\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: " << body.size()
    << "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    << body;
  return o.str();
}

}
