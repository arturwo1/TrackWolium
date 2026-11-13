#pragma once
#include <string>
#include <vector>

namespace tw {

struct X11Window {
  long pid = 0;
  bool active = false;
  bool hidden = false;
  std::string wm_class;
  std::string wm_instance;
};

class X11Windows {
public:
  X11Windows();
  ~X11Windows();
  X11Windows(const X11Windows&) = delete;
  X11Windows& operator=(const X11Windows&) = delete;

  bool available() const { return ok_; }
  std::vector<X11Window> list();

private:
  void* impl_ = nullptr;
  bool ok_ = false;
};

}
