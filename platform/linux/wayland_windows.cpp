#include "wayland_windows.hpp"
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include "mini_json.hpp"

namespace tw {
namespace {

std::string env(const char* name) {
  const char* v = std::getenv(name);
  return v ? v : "";
}

int connect_socket(const std::string& path) {
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  if (path.empty() || path.size() >= sizeof(addr.sun_path)) {
    close(fd);
    return -1;
  }
  std::memcpy(addr.sun_path, path.c_str(), path.size() + 1);
  if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

bool send_all(int fd, const char* data, std::size_t size) {
  while (size > 0) {
    ssize_t n = send(fd, data, size, MSG_NOSIGNAL);
    if (n <= 0) return false;
    data += n;
    size -= static_cast<std::size_t>(n);
  }
  return true;
}

bool recv_exact(int fd, char* data, std::size_t size) {
  while (size > 0) {
    pollfd p{fd, POLLIN, 0};
    if (poll(&p, 1, 300) <= 0) return false;
    ssize_t n = recv(fd, data, size, 0);
    if (n <= 0) return false;
    data += n;
    size -= static_cast<std::size_t>(n);
  }
  return true;
}

std::string hypr_request(const std::string& command) {
  std::string path = env("XDG_RUNTIME_DIR") + "/hypr/" + env("HYPRLAND_INSTANCE_SIGNATURE") + "/.socket.sock";
  int fd = connect_socket(path);
  if (fd < 0) return {};
  std::string out;
  if (send_all(fd, command.data(), command.size())) {
    char buf[8192];
    while (out.size() < (8u << 20)) {
      pollfd p{fd, POLLIN, 0};
      if (poll(&p, 1, 300) <= 0) break;
      ssize_t n = recv(fd, buf, sizeof(buf), 0);
      if (n <= 0) break;
      out.append(buf, static_cast<std::size_t>(n));
    }
  }
  close(fd);
  return out;
}

std::string sway_request(std::uint32_t type) {
  std::string path = env("SWAYSOCK");
  if (path.empty()) path = env("I3SOCK");
  int fd = connect_socket(path);
  if (fd < 0) return {};
  std::string out;
  char head[14];
  std::memcpy(head, "i3-ipc", 6);
  std::uint32_t zero = 0;
  std::memcpy(head + 6, &zero, 4);
  std::memcpy(head + 10, &type, 4);
  if (send_all(fd, head, sizeof(head))) {
    char reply[14];
    if (recv_exact(fd, reply, sizeof(reply)) && std::memcmp(reply, "i3-ipc", 6) == 0) {
      std::uint32_t len = 0;
      std::memcpy(&len, reply + 6, 4);
      if (len > 0 && len < (16u << 20)) {
        out.resize(len);
        if (!recv_exact(fd, &out[0], len)) out.clear();
      }
    }
  }
  close(fd);
  return out;
}

void walk_sway(const Json& node, bool scratch, std::vector<X11Window>& out) {
  if (node.kind != Json::Object) return;
  std::string name = node.str("name");
  bool hidden = scratch || name == "__i3_scratch";
  double pid = node.num("pid", 0);
  std::string type = node.str("type");
  if (pid > 0 && (type == "con" || type == "floating_con")) {
    X11Window w;
    w.pid = static_cast<long>(pid);
    w.active = node.flag("focused");
    w.hidden = hidden;
    w.wm_class = node.str("app_id");
    if (w.wm_class.empty()) {
      const Json* props = node.get("window_properties");
      if (props) w.wm_class = props->str("class");
    }
    w.wm_instance = w.wm_class;
    out.push_back(std::move(w));
  }
  for (const char* key : {"nodes", "floating_nodes"}) {
    const Json* list = node.get(key);
    if (!list || list->kind != Json::Array) continue;
    for (const auto& child : list->a) walk_sway(child, hidden, out);
  }
}

}

Compositor detect_compositor() {
  if (env("WAYLAND_DISPLAY").empty()) return Compositor::None;
  if (!env("HYPRLAND_INSTANCE_SIGNATURE").empty()) return Compositor::Hyprland;
  if (!env("SWAYSOCK").empty()) return Compositor::Sway;
  return Compositor::None;
}

WaylandWindows::WaylandWindows() : compositor_(detect_compositor()) {}

std::vector<X11Window> parse_hyprland(const std::string& clients_json, const std::string& active_json) {
  std::vector<X11Window> out;
  Json clients;
  if (!JsonParser(clients_json).parse(clients) || clients.kind != Json::Array) return out;
  Json active;
  std::string active_addr;
  if (JsonParser(active_json).parse(active) && active.kind == Json::Object) active_addr = active.str("address");
  for (const auto& c : clients.a) {
    if (c.kind != Json::Object || !c.get("mapped") || !c.flag("mapped")) continue;
    X11Window w;
    w.pid = static_cast<long>(c.num("pid", 0));
    w.wm_class = c.str("class");
    w.wm_instance = c.str("initialClass");
    if (w.wm_instance.empty()) w.wm_instance = w.wm_class;
    w.hidden = c.flag("hidden");
    std::string addr = c.str("address");
    w.active = !addr.empty() && addr == active_addr;
    out.push_back(std::move(w));
  }
  return out;
}

std::vector<X11Window> parse_sway(const std::string& tree_json) {
  std::vector<X11Window> out;
  Json root;
  if (!JsonParser(tree_json).parse(root)) return out;
  walk_sway(root, false, out);
  return out;
}

std::vector<X11Window> WaylandWindows::list() {
  if (compositor_ == Compositor::Hyprland) return parse_hyprland(hypr_request("j/clients"), hypr_request("j/activewindow"));
  if (compositor_ == Compositor::Sway) return parse_sway(sway_request(4));
  return {};
}

}
