#pragma once
#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "x11_windows.hpp"

namespace tw {

constexpr const char* kBridgeName = "org.wolium.Bridge";
constexpr const char* kBridgePath = "/org/wolium/Bridge";
constexpr const char* kBridgeInterface = "org.wolium.Bridge";
constexpr int kBridgeFreshSeconds = 30;

std::vector<X11Window> parse_bridge_report(const std::string& json);

class DbusBridge {
public:
  DbusBridge();
  ~DbusBridge();
  DbusBridge(const DbusBridge&) = delete;
  DbusBridge& operator=(const DbusBridge&) = delete;

  bool fresh() const;
  std::vector<X11Window> windows() const;
  void accept(const std::string& json);

private:
  void run();

  std::thread thread_;
  std::atomic<bool> stop_{false};
  mutable std::mutex mtx_;
  std::vector<X11Window> windows_;
  std::chrono::steady_clock::time_point stamp_{};
  bool have_ = false;
};

DbusBridge& dbus_bridge();

}
