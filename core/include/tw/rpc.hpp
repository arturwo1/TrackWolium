#pragma once
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace tw {

struct RpcFrame {
  std::uint32_t op = 0;
  std::string payload;
};

struct Presence {
  std::string client_id;
  std::string name;
  std::string details;
  std::string state;
  std::int64_t started = 0;
};

class RpcFrameParser {
public:
  std::vector<RpcFrame> feed(const char* data, std::size_t size);

private:
  std::string buf_;
};

std::string json_string(const std::string& json, const std::string& key, std::size_t from = 0);
std::int64_t json_number(const std::string& json, const std::string& key, std::size_t from = 0);
bool extract_client_id(const RpcFrame& frame, std::string& out);
bool extract_presence(const RpcFrame& frame, Presence& out);

class PresenceQueue {
public:
  void push(Presence p);
  std::vector<Presence> drain();

private:
  std::mutex mtx_;
  std::vector<Presence> items_;
};

}
