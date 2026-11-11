#pragma once
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

class DiscordProxy {
public:
  explicit DiscordProxy(tw::PresenceQueue& queue) : queue_(queue) {}
  ~DiscordProxy() { stop(); }

  bool running() const { return running_; }

  void start() {
    if (running_) return;
    running_ = true;
    thread_ = std::thread([this] { accept_loop(); });
  }

  void stop() {
    if (!running_) return;
    running_ = false;
    HANDLE h = CreateFileW(L"\\\\.\\pipe\\discord-ipc-0", GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    if (thread_.joinable()) thread_.join();
  }

private:
  struct Link {
    HANDLE client = INVALID_HANDLE_VALUE;
    HANDLE server = INVALID_HANDLE_VALUE;
  };

  static HANDLE open_next() {
    for (int i = 1; i < 10; ++i) {
      std::wstring name = L"\\\\.\\pipe\\discord-ipc-" + std::to_wstring(i);
      HANDLE h = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
      if (h != INVALID_HANDLE_VALUE) return h;
    }
    return INVALID_HANDLE_VALUE;
  }

  void accept_loop() {
    while (running_) {
      HANDLE pipe = CreateNamedPipeW(L"\\\\.\\pipe\\discord-ipc-0", PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 8, 65536, 65536,
                                     0, nullptr);
      if (pipe == INVALID_HANDLE_VALUE) {
        Sleep(5000);
        continue;
      }
      BOOL ok = ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED;
      if (!ok || !running_) {
        CloseHandle(pipe);
        continue;
      }
      HANDLE upstream = open_next();
      if (upstream == INVALID_HANDLE_VALUE) {
        CloseHandle(pipe);
        continue;
      }
      std::thread([this, pipe, upstream] { session(pipe, upstream); }).detach();
    }
  }

  void session(HANDLE client, HANDLE server) {
    std::thread down([client, server] {
      char buf[8192];
      DWORD n = 0;
      while (ReadFile(server, buf, sizeof(buf), &n, nullptr) && n > 0) {
        DWORD w = 0;
        if (!WriteFile(client, buf, n, &w, nullptr)) break;
      }
      CancelIoEx(client, nullptr);
      DisconnectNamedPipe(client);
    });
    tw::RpcFrameParser parser;
    std::string client_id;
    char buf[8192];
    DWORD n = 0;
    while (ReadFile(client, buf, sizeof(buf), &n, nullptr) && n > 0) {
      DWORD w = 0;
      if (!WriteFile(server, buf, n, &w, nullptr)) break;
      for (const auto& f : parser.feed(buf, n)) {
        std::string id;
        if (tw::extract_client_id(f, id)) client_id = id;
        tw::Presence p;
        if (tw::extract_presence(f, p)) {
          p.client_id = client_id;
          queue_.push(std::move(p));
        }
      }
    }
    CloseHandle(server);
    down.join();
    CloseHandle(client);
  }

  tw::PresenceQueue& queue_;
  std::atomic<bool> running_{false};
  std::thread thread_;
};

}
