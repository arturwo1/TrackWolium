#include "tw/rpc.hpp"
#include <cctype>
#include <cstdlib>

namespace tw {

namespace {

std::uint32_t le32(const unsigned char* p) {
  return static_cast<std::uint32_t>(p[0]) | (static_cast<std::uint32_t>(p[1]) << 8) | (static_cast<std::uint32_t>(p[2]) << 16) |
         (static_cast<std::uint32_t>(p[3]) << 24);
}

std::size_t find_key(const std::string& json, const std::string& key, std::size_t from) {
  const std::string needle = "\"" + key + "\"";
  std::size_t pos = from;
  while ((pos = json.find(needle, pos)) != std::string::npos) {
    std::size_t i = pos + needle.size();
    while (i < json.size() && std::isspace(static_cast<unsigned char>(json[i]))) ++i;
    if (i < json.size() && json[i] == ':') {
      ++i;
      while (i < json.size() && std::isspace(static_cast<unsigned char>(json[i]))) ++i;
      return i;
    }
    pos += needle.size();
  }
  return std::string::npos;
}

void append_utf8(std::string& out, unsigned cp) {
  if (cp < 0x80) out += static_cast<char>(cp);
  else if (cp < 0x800) {
    out += static_cast<char>(0xC0 | (cp >> 6));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  } else {
    out += static_cast<char>(0xE0 | (cp >> 12));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  }
}

}

std::vector<RpcFrame> RpcFrameParser::feed(const char* data, std::size_t size) {
  buf_.append(data, size);
  std::vector<RpcFrame> out;
  std::size_t pos = 0;
  while (buf_.size() - pos >= 8) {
    const auto* p = reinterpret_cast<const unsigned char*>(buf_.data() + pos);
    std::uint32_t op = le32(p);
    std::uint32_t len = le32(p + 4);
    if (len > (1u << 20)) {
      buf_.clear();
      return out;
    }
    if (buf_.size() - pos - 8 < len) break;
    out.push_back({op, buf_.substr(pos + 8, len)});
    pos += 8 + len;
  }
  buf_.erase(0, pos);
  return out;
}

std::string json_string(const std::string& json, const std::string& key, std::size_t from) {
  std::size_t i = find_key(json, key, from);
  if (i == std::string::npos || i >= json.size() || json[i] != '"') return {};
  std::string out;
  for (++i; i < json.size() && json[i] != '"'; ++i) {
    if (json[i] != '\\') {
      out += json[i];
      continue;
    }
    if (++i >= json.size()) break;
    switch (json[i]) {
      case 'n': out += '\n'; break;
      case 't': out += '\t'; break;
      case 'r': break;
      case 'u':
        if (i + 4 < json.size()) {
          append_utf8(out, static_cast<unsigned>(std::strtoul(json.substr(i + 1, 4).c_str(), nullptr, 16)));
          i += 4;
        }
        break;
      default: out += json[i];
    }
  }
  return out;
}

std::int64_t json_number(const std::string& json, const std::string& key, std::size_t from) {
  std::size_t i = find_key(json, key, from);
  if (i == std::string::npos) return 0;
  return std::strtoll(json.c_str() + i, nullptr, 10);
}

bool extract_client_id(const RpcFrame& frame, std::string& out) {
  if (frame.op != 0) return false;
  out = json_string(frame.payload, "client_id");
  return !out.empty();
}

bool extract_presence(const RpcFrame& frame, Presence& out) {
  if (frame.op != 1) return false;
  if (json_string(frame.payload, "cmd") != "SET_ACTIVITY") return false;
  std::size_t act = find_key(frame.payload, "activity", 0);
  if (act == std::string::npos) return false;
  out.name = json_string(frame.payload, "name", act);
  out.details = json_string(frame.payload, "details", act);
  out.state = json_string(frame.payload, "state", act);
  out.started = json_number(frame.payload, "start", act);
  return true;
}

void PresenceQueue::push(Presence p) {
  std::lock_guard<std::mutex> lock(mtx_);
  if (items_.size() < 1000) items_.push_back(std::move(p));
}

std::vector<Presence> PresenceQueue::drain() {
  std::lock_guard<std::mutex> lock(mtx_);
  std::vector<Presence> out;
  out.swap(items_);
  return out;
}

}
