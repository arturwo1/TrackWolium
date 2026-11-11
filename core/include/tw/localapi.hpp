#pragma once
#include <string>
#include "tw/types.hpp"

namespace tw {

constexpr int kLocalApiPort = 9095;

std::string current_json(const Report& report);
bool parse_api_request(const std::string& request, int port, std::string& path);
std::string http_response(int status, const std::string& body);

}
