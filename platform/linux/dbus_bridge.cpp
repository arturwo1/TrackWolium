#include "dbus_bridge.hpp"
#include <dlfcn.h>
#include <cstdint>
#include <cstring>
#include <type_traits>
#include "mini_json.hpp"

namespace tw {
namespace {

struct DbusError {
  const char* name;
  const char* message;
  unsigned int bits;
  void* pad;
};

struct Api {
  void* lib = nullptr;
  void (*error_init)(DbusError*) = nullptr;
  void (*error_free)(DbusError*) = nullptr;
  void* (*bus_get_private)(int, DbusError*) = nullptr;
  int (*request_name)(void*, const char*, unsigned int, DbusError*) = nullptr;
  std::uint32_t (*read_write)(void*, int) = nullptr;
  void* (*pop)(void*) = nullptr;
  std::uint32_t (*is_call)(void*, const char*, const char*) = nullptr;
  std::uint32_t (*get_args)(void*, DbusError*, int, ...) = nullptr;
  void* (*method_return)(void*) = nullptr;
  std::uint32_t (*send)(void*, void*, std::uint32_t*) = nullptr;
  void (*flush)(void*) = nullptr;
  void (*unref_message)(void*) = nullptr;
  void (*close_connection)(void*) = nullptr;
  void (*unref_connection)(void*) = nullptr;
  std::uint32_t (*connected)(void*) = nullptr;
  void (*exit_on_disconnect)(void*, std::uint32_t) = nullptr;

  bool load() {
    lib = dlopen("libdbus-1.so.3", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return false;
    bool ok = true;
    auto sym = [&](auto& fn, const char* name) {
      fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(dlsym(lib, name));
      if (!fn) ok = false;
    };
    sym(error_init, "dbus_error_init");
    sym(error_free, "dbus_error_free");
    sym(bus_get_private, "dbus_bus_get_private");
    sym(request_name, "dbus_bus_request_name");
    sym(read_write, "dbus_connection_read_write");
    sym(pop, "dbus_connection_pop_message");
    sym(is_call, "dbus_message_is_method_call");
    sym(get_args, "dbus_message_get_args");
    sym(method_return, "dbus_message_new_method_return");
    sym(send, "dbus_connection_send");
    sym(flush, "dbus_connection_flush");
    sym(unref_message, "dbus_message_unref");
    sym(close_connection, "dbus_connection_close");
    sym(unref_connection, "dbus_connection_unref");
    sym(connected, "dbus_connection_get_is_connected");
    sym(exit_on_disconnect, "dbus_connection_set_exit_on_disconnect");
    return ok;
  }
};

constexpr int kTypeString = 's';
constexpr int kTypeInvalid = 0;
constexpr unsigned int kDoNotQueue = 4;
constexpr int kPrimaryOwner = 1;
constexpr std::size_t kMaxReport = 262144;

}

std::vector<X11Window> parse_bridge_report(const std::string& json) {
  std::vector<X11Window> out;
  Json root;
  if (json.size() > kMaxReport || !JsonParser(json).parse(root) || root.kind != Json::Object) return out;
  const Json* list = root.get("windows");
  if (!list || list->kind != Json::Array) return out;
  for (const auto& e : list->a) {
    if (e.kind != Json::Object) continue;
    X11Window w;
    w.pid = static_cast<long>(e.num("pid", 0));
    w.wm_class = e.str("class");
    w.wm_instance = e.str("instance");
    if (w.wm_instance.empty()) w.wm_instance = w.wm_class;
    w.active = e.flag("active");
    w.hidden = e.flag("minimized");
    if (w.pid > 0 || !w.wm_class.empty()) out.push_back(std::move(w));
  }
  return out;
}

DbusBridge::DbusBridge() { thread_ = std::thread([this] { run(); }); }

DbusBridge::~DbusBridge() {
  stop_ = true;
  if (thread_.joinable()) thread_.join();
}

bool DbusBridge::fresh() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return have_ && std::chrono::steady_clock::now() - stamp_ < std::chrono::seconds(kBridgeFreshSeconds);
}

std::vector<X11Window> DbusBridge::windows() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return windows_;
}

void DbusBridge::accept(const std::string& json) {
  std::vector<X11Window> parsed = parse_bridge_report(json);
  std::lock_guard<std::mutex> lock(mtx_);
  windows_ = std::move(parsed);
  stamp_ = std::chrono::steady_clock::now();
  have_ = true;
}

void DbusBridge::run() {
  Api api;
  if (!api.load()) return;
  while (!stop_) {
    DbusError err{};
    api.error_init(&err);
    void* conn = api.bus_get_private(0, &err);
    if (!conn) {
      api.error_free(&err);
      for (int i = 0; i < 30 && !stop_; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(500));
      continue;
    }
    api.error_free(&err);
    api.exit_on_disconnect(conn, 0);
    DbusError err2{};
    api.error_init(&err2);
    int owner = api.request_name(conn, kBridgeName, kDoNotQueue, &err2);
    api.error_free(&err2);
    if (owner != kPrimaryOwner) {
      api.close_connection(conn);
      api.unref_connection(conn);
      for (int i = 0; i < 60 && !stop_; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(500));
      continue;
    }
    while (!stop_ && api.connected(conn)) {
      api.read_write(conn, 1000);
      while (void* msg = api.pop(conn)) {
        if (api.is_call(msg, kBridgeInterface, "Report")) {
          DbusError ae{};
          api.error_init(&ae);
          const char* text = nullptr;
          if (api.get_args(msg, &ae, kTypeString, &text, kTypeInvalid) && text) accept(text);
          api.error_free(&ae);
          if (void* reply = api.method_return(msg)) {
            api.send(conn, reply, nullptr);
            api.unref_message(reply);
          }
          api.flush(conn);
        }
        api.unref_message(msg);
      }
    }
    api.close_connection(conn);
    api.unref_connection(conn);
  }
  dlclose(api.lib);
}

DbusBridge& dbus_bridge() {
  static DbusBridge bridge;
  return bridge;
}

}
