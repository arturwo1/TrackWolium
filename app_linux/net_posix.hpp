#pragma once
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <atomic>
#include <cstdlib>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "tw/localapi.hpp"
#include "tw/rpc.hpp"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

namespace app {

inline void no_sigpipe(int fd) {
#ifdef SO_NOSIGPIPE
  int on = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#else
  (void)fd;
#endif
}

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
    sock_ = socket(AF_INET, SOCK_STREAM, 0);
    if (sock_ < 0) return;
    int on = 1;
    setsockopt(sock_, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(tw::kLocalApiPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(sock_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || listen(sock_, 8) != 0) {
      close(sock_);
      sock_ = -1;
      return;
    }
    running_ = true;
    thread_ = std::thread([this] { loop(); });
  }

  void stop() {
    if (!running_) return;
    running_ = false;
    if (thread_.joinable()) thread_.join();
    close(sock_);
    sock_ = -1;
  }

private:
  void loop() {
    while (running_) {
      pollfd p{sock_, POLLIN, 0};
      if (poll(&p, 1, 500) <= 0) continue;
      int s = accept(sock_, nullptr, nullptr);
      if (s < 0) continue;
      no_sigpipe(s);
      std::string req;
      char buf[2048];
      while (req.size() < 8192 && req.find("\r\n\r\n") == std::string::npos) {
        pollfd r{s, POLLIN, 0};
        if (poll(&r, 1, 1500) <= 0) break;
        ssize_t n = recv(s, buf, sizeof(buf), 0);
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
      send(s, out.data(), out.size(), MSG_NOSIGNAL);
      close(s);
    }
  }

  std::atomic<bool> running_{false};
  int sock_ = -1;
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
    state_ = 1;
    running_ = true;
    thread_ = std::thread([this] { accept_loop(); });
  }

  void stop() {
    if (!running_) return;
    running_ = false;
    if (thread_.joinable()) thread_.join();
    for (int i = 0; i < 40 && sessions_ > 0; ++i) usleep(50000);
    state_ = 0;
  }

private:
  static std::string env(const char* name) {
    const char* v = std::getenv(name);
    return v ? v : "";
  }

  static std::string trim_slash(std::string s) {
    while (s.size() > 1 && s.back() == '/') s.pop_back();
    return s;
  }

  static std::vector<std::string> dirs() {
    std::vector<std::string> out;
    std::string xdg = trim_slash(env("XDG_RUNTIME_DIR"));
    std::string tmp = trim_slash(env("TMPDIR"));
    if (!xdg.empty()) {
      out.push_back(xdg);
      out.push_back(xdg + "/app/com.discordapp.Discord");
      out.push_back(xdg + "/app/com.discordapp.DiscordCanary");
      out.push_back(xdg + "/snap.discord");
    }
    if (!tmp.empty()) out.push_back(tmp);
    out.push_back("/tmp");
    return out;
  }

  static std::string primary_dir() { return dirs().front(); }

  static int connect_path(const std::string& path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    sockaddr_un a{};
    a.sun_family = AF_UNIX;
    if (path.size() >= sizeof(a.sun_path)) {
      close(fd);
      return -1;
    }
    std::copy(path.begin(), path.end(), a.sun_path);
    if (connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
      close(fd);
      return -1;
    }
    no_sigpipe(fd);
    return fd;
  }

  int open_upstream() {
    const std::string own = primary_dir() + "/discord-ipc-0";
    for (int attempt = 0; attempt < 4 && running_; ++attempt) {
      for (const auto& d : dirs()) {
        for (int i = 0; i < 10; ++i) {
          std::string path = d + "/discord-ipc-" + std::to_string(i);
          if (path == own) continue;
          int fd = connect_path(path);
          if (fd >= 0) return fd;
        }
      }
      usleep(300000);
    }
    return -1;
  }

  static bool write_all(int fd, const char* data, std::size_t size) {
    while (size > 0) {
      ssize_t n = send(fd, data, size, MSG_NOSIGNAL);
      if (n <= 0) return false;
      data += n;
      size -= static_cast<std::size_t>(n);
    }
    return true;
  }

  int listen_own(const std::string& path) {
    struct stat st{};
    if (lstat(path.c_str(), &st) == 0) {
      int probe = connect_path(path);
      if (probe >= 0) {
        close(probe);
        return -2;
      }
      unlink(path.c_str());
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    sockaddr_un a{};
    a.sun_family = AF_UNIX;
    if (path.size() >= sizeof(a.sun_path)) {
      close(fd);
      return -1;
    }
    std::copy(path.begin(), path.end(), a.sun_path);
    if (bind(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0 || listen(fd, 8) != 0) {
      close(fd);
      return -1;
    }
    no_sigpipe(fd);
    return fd;
  }

  void accept_loop() {
    const std::string path = primary_dir() + "/discord-ipc-0";
    int srv = -1;
    while (running_) {
      if (srv < 0) {
        srv = listen_own(path);
        if (srv < 0) {
          state_ = 2;
          for (int i = 0; i < 50 && running_; ++i) usleep(100000);
          continue;
        }
        state_ = 1;
      }
      pollfd p{srv, POLLIN, 0};
      if (poll(&p, 1, 500) <= 0) continue;
      int client = accept(srv, nullptr, nullptr);
      if (client < 0) continue;
      no_sigpipe(client);
      ++sessions_;
      std::thread([this, client] {
        session(client);
        --sessions_;
      }).detach();
    }
    if (srv >= 0) {
      close(srv);
      unlink(path.c_str());
    }
  }

  void session(int client) {
    int server = open_upstream();
    if (server < 0) {
      close(client);
      return;
    }
    state_ = 3;
    tw::RpcFrameParser parser;
    std::string client_id;
    std::string last;
    char buf[8192];
    int fds[2] = {client, server};
    while (running_) {
      pollfd p[2] = {{fds[0], POLLIN, 0}, {fds[1], POLLIN, 0}};
      int r = poll(p, 2, 500);
      if (r < 0) break;
      if (r == 0) continue;
      bool done = false;
      for (int i = 0; i < 2 && !done; ++i) {
        if (!(p[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
        ssize_t n = recv(fds[i], buf, sizeof(buf), 0);
        if (n <= 0) {
          done = true;
          break;
        }
        if (!write_all(fds[1 - i], buf, static_cast<std::size_t>(n))) {
          done = true;
          break;
        }
        if (i == 0) {
          for (const auto& f : parser.feed(buf, static_cast<std::size_t>(n))) {
            std::string id;
            if (tw::extract_client_id(f, id)) client_id = id;
            tw::Presence pr;
            if (tw::extract_presence(f, pr)) {
              pr.client_id = client_id;
              std::string key = pr.client_id + "|" + pr.raw;
              if (key != last) {
                last = key;
                queue_.push(std::move(pr));
              }
            }
          }
        }
      }
      if (done) break;
    }
    close(server);
    close(client);
  }

  tw::PresenceQueue& queue_;
  std::atomic<int> state_{0};
  std::atomic<int> sessions_{0};
  std::atomic<bool> running_{false};
  std::thread thread_;
};

}
