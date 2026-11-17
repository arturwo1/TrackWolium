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

class ApiData {
public:
  virtual ~ApiData() = default;
  virtual std::vector<UsageRow> usage(const std::string& from_day, const std::string& to_day) = 0;
  virtual std::vector<SessionRow> sessions(long long from, long long to, int limit) = 0;
};

struct ApiReply {
  int status;
  std::string type;
  std::string body;
};

std::string current_json(const Report& report);
bool parse_api_request(const std::string& request, int port, std::string& path);
std::string http_response(int status, const std::string& body, const std::string& type = "application/json; charset=utf-8");
std::string day_string(long long epoch);
ApiReply route_api(const std::string& target, const std::string& current, ApiData* data, long long now);
std::string widget_html();

}
