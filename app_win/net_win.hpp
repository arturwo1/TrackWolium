#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <windows.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include "tw/localapi.hpp"
#include "tw/rpc.hpp"

namespace app {

class LocalApi {
public:
  ~LocalApi() { stop(); }

  void set_body(std::string body) {
    std::lock_guard<std::mutex> lock(mtx_);
    body_ = std::move(body);
  }

  bool running() const { return running_; }

  void start() {
    if (running_) return;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return;
    sock_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock_ == INVALID_SOCKET) return;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(tw::kLocalApiPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(sock_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || listen(sock_, 8) != 0) {
      closesocket(sock_);
      sock_ = INVALID_SOCKET;
      return;
    }
    running_ = true;
    thread_ = std::thread([this] { loop(); });
  }

  void stop() {
    if (!running_) return;
    running_ = false;
    closesocket(sock_);
    sock_ = INVALID_SOCKET;
    if (thread_.joinable()) thread_.join();
  }

private:
  void loop() {
    while (running_) {
      SOCKET s = accept(sock_, nullptr, nullptr);
      if (s == INVALID_SOCKET) break;
      DWORD timeout = 1500;
      setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
      std::string req;
      char buf[2048];
      while (req.size() < 8192 && req.find("\r\n\r\n") == std::string::npos) {
        int n = recv(s, buf, sizeof(buf), 0);
        if (n <= 0) break;
        req.append(buf, static_cast<std::size_t>(n));
      }
      std::string path;
      std::string out;
      if (!tw::parse_api_request(req, tw::kLocalApiPort, path)) out = tw::http_response(400, "{\"error\":\"bad request\"}");
      else if (path != "/v1/current") out = tw::http_response(404, "{\"error\":\"not found\"}");
      else {
        std::lock_guard<std::mutex> lock(mtx_);
        out = tw::http_response(200, body_.empty() ? "{\"apps\":[]}" : body_);
      }
      send(s, out.data(), static_cast<int>(out.size()), 0);
      closesocket(s);
    }
  }

  std::atomic<bool> running_{false};
  SOCKET sock_ = INVALID_SOCKET;
  std::thread thread_;
  std::mutex mtx_;
  std::string body_;
};

}
