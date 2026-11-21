#pragma once
#include <string>
#include <vector>
#include "tw/store.hpp"
#include "tw/types.hpp"

namespace tw {

constexpr int kLocalApiPort = 9095;

struct UsageRow {
  std::string day;
  std::string app;
  std::string name;
  int state;
  long long ms;
};

struct SessionRow {
  std::string app;
  std::string name;
  int state;
  long long start;
  long long stop;
};

struct BrowserRow {
  std::string browser;
  std::string domain;
  long long ms;
  std::string title;
  std::string url;
};

class ApiData {
public:
  virtual ~ApiData() = default;
  virtual std::vector<UsageRow> usage(const std::string& from_day, const std::string& to_day) = 0;
  virtual std::vector<SessionRow> sessions(long long from, long long to, int limit) = 0;
  virtual bool add_browser_usage(const std::string& day, const std::string& browser, const std::string& domain, long long ms) {
    (void)day;
    (void)browser;
    (void)domain;
    (void)ms;
    return false;
  }
  virtual bool add_browser_usage(const std::string& day, int slot, const std::string& browser, const std::string& domain, const std::string& title, const std::string& url, long long ms) {
    (void)slot;
    (void)title;
    (void)url;
    return add_browser_usage(day, browser, domain, ms);
  }
  virtual std::vector<BrowserRow> browser_usage(const std::string& from_day, const std::string& to_day) {
    (void)from_day;
    (void)to_day;
    return {};
  }
};

struct ApiRequest {
  std::string method;
  std::string path;
  std::string body;
  bool ok = false;
};

struct ApiReply {
  int status;
  std::string type;
  std::string body;
};

std::string current_json(const Report& report);
bool parse_api_request(const std::string& request, int port, std::string& path);
ApiRequest parse_api_request_ex(const std::string& request, int port);
std::string http_response(int status, const std::string& body, const std::string& type = "application/json; charset=utf-8");
std::string day_string(long long epoch);
ApiReply route_api(const std::string& target, const std::string& current, ApiData* data, long long now);
ApiReply route_api(const std::string& method, const std::string& target, const std::string& req_body, const std::string& current, ApiData* data, long long now);
std::string widget_html();

}
