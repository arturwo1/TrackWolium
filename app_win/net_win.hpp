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

class DiscordProxy {
public:
  explicit DiscordProxy(tw::PresenceQueue& queue) : queue_(queue) {}
  ~DiscordProxy() { stop(); }

  bool running() const { return running_; }
  int state() const { return state_; }

  void start() {
    if (running_) return;
    stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    state_ = 1;
    running_ = true;
    thread_ = std::thread([this] { accept_loop(); });
  }

  void stop() {
    if (!running_) return;
    running_ = false;
    SetEvent(stop_event_);
    if (thread_.joinable()) thread_.join();
    for (int i = 0; i < 40 && sessions_ > 0; ++i) Sleep(50);
    CloseHandle(stop_event_);
    stop_event_ = nullptr;
    state_ = 0;
  }

private:
  static HANDLE make_pipe() {
    return CreateNamedPipeW(L"\\\\.\\pipe\\discord-ipc-0", PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, nullptr);
  }

  static HANDLE open_upstream() {
    for (int attempt = 0; attempt < 4; ++attempt) {
      for (int i = 1; i < 10; ++i) {
        std::wstring name = L"\\\\.\\pipe\\discord-ipc-" + std::to_wstring(i);
        HANDLE h = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
        if (h != INVALID_HANDLE_VALUE) return h;
      }
      Sleep(300);
    }
    return INVALID_HANDLE_VALUE;
  }

  static bool write_all(HANDLE h, const char* data, DWORD size, HANDLE ev) {
    while (size > 0) {
      OVERLAPPED o{};
      o.hEvent = ev;
      ResetEvent(ev);
      DWORD written = 0;
      if (!WriteFile(h, data, size, &written, &o)) {
        if (GetLastError() != ERROR_IO_PENDING) return false;
        if (!GetOverlappedResult(h, &o, &written, TRUE)) return false;
      }
      if (written == 0) return false;
      data += written;
      size -= written;
    }
    return true;
  }

  void accept_loop() {
    HANDLE current = INVALID_HANDLE_VALUE;
    HANDLE connect_ev = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    while (running_) {
      if (current == INVALID_HANDLE_VALUE) {
        current = make_pipe();
        if (current == INVALID_HANDLE_VALUE) {
          state_ = 2;
          if (WaitForSingleObject(stop_event_, 5000) == WAIT_OBJECT_0) break;
          continue;
        }
        if (state_ == 2) state_ = 1;
      }
      OVERLAPPED o{};
      o.hEvent = connect_ev;
      ResetEvent(connect_ev);
      bool connected = false;
      if (ConnectNamedPipe(current, &o)) connected = true;
      else {
        DWORD err = GetLastError();
        if (err == ERROR_PIPE_CONNECTED) connected = true;
        else if (err == ERROR_IO_PENDING) {
          HANDLE waits[2] = {connect_ev, stop_event_};
          DWORD r = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
          if (r != WAIT_OBJECT_0) {
            CancelIoEx(current, &o);
            break;
          }
          DWORD ignored = 0;
          connected = GetOverlappedResult(current, &o, &ignored, FALSE) != 0;
        }
      }
      if (!connected) {
        CloseHandle(current);
        current = INVALID_HANDLE_VALUE;
        continue;
      }
      HANDLE client = current;
      current = make_pipe();
      ++sessions_;
      std::thread([this, client] {
        session(client);
        --sessions_;
      }).detach();
    }
    if (current != INVALID_HANDLE_VALUE) CloseHandle(current);
    CloseHandle(connect_ev);
  }

  void session(HANDLE client) {
    HANDLE server = open_upstream();
    if (server == INVALID_HANDLE_VALUE) {
      DisconnectNamedPipe(client);
      CloseHandle(client);
      return;
    }
    state_ = 3;
    HANDLE ev[3] = {CreateEventW(nullptr, TRUE, FALSE, nullptr), CreateEventW(nullptr, TRUE, FALSE, nullptr), CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    HANDLE ends[2] = {client, server};
    OVERLAPPED ov[2]{};
    char buf[2][8192];
    ov[0].hEvent = ev[0];
    ov[1].hEvent = ev[1];
    tw::RpcFrameParser parser;
    std::string client_id;
    std::string last;
    auto begin_read = [&](int i) {
      ResetEvent(ev[i]);
      DWORD n = 0;
      if (ReadFile(ends[i], buf[i], sizeof(buf[i]), &n, &ov[i])) return true;
      return GetLastError() == ERROR_IO_PENDING;
    };
    bool ok = begin_read(0) && begin_read(1);
    while (ok && running_) {
      DWORD r = WaitForMultipleObjects(2, ev, FALSE, 500);
      if (r == WAIT_TIMEOUT) continue;
      if (r < WAIT_OBJECT_0 || r > WAIT_OBJECT_0 + 1) break;
      int i = static_cast<int>(r - WAIT_OBJECT_0);
      DWORD n = 0;
      if (!GetOverlappedResult(ends[i], &ov[i], &n, FALSE) || n == 0) break;
      if (!write_all(ends[1 - i], buf[i], n, ev[2])) break;
      if (i == 0) {
        for (const auto& f : parser.feed(buf[0], n)) {
          std::string id;
          if (tw::extract_client_id(f, id)) client_id = id;
          tw::Presence p;
          if (tw::extract_presence(f, p)) {
            p.client_id = client_id;
            std::string key = p.client_id + "|" + p.name + "|" + p.details + "|" + p.state;
            if (key != last) {
              last = key;
              queue_.push(std::move(p));
            }
          }
        }
      }
      ok = begin_read(i);
    }
    CancelIoEx(client, nullptr);
    CancelIoEx(server, nullptr);
    CloseHandle(server);
    DisconnectNamedPipe(client);
    CloseHandle(client);
    for (HANDLE e : ev) CloseHandle(e);
  }

  tw::PresenceQueue& queue_;
  std::atomic<int> state_{0};
  std::atomic<int> sessions_{0};
  std::atomic<bool> running_{false};
  HANDLE stop_event_ = nullptr;
  std::thread thread_;
};

}
