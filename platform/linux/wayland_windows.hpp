#pragma once
#include <vector>
#include "x11_windows.hpp"

namespace tw {

enum class Compositor { None, Hyprland, Sway, Gnome, Kde };

Compositor detect_compositor();

class WaylandWindows {
public:
  WaylandWindows();

  bool available() const;
  Compositor compositor() const { return compositor_; }
  std::vector<X11Window> list();

private:
  Compositor compositor_;
};

std::vector<X11Window> parse_hyprland(const std::string& clients_json, const std::string& active_json);
std::vector<X11Window> parse_sway(const std::string& tree_json);

}
