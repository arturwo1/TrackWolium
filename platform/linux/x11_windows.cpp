#include "x11_windows.hpp"

#ifdef TW_HAVE_X11
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <dlfcn.h>
#include <cstring>
#include <set>

namespace tw {
namespace {

struct Api {
  void* lib = nullptr;
  Display* (*open)(const char*) = nullptr;
  int (*close)(Display*) = nullptr;
  Atom (*intern)(Display*, const char*, Bool) = nullptr;
  int (*get_property)(Display*, Window, Atom, long, long, Bool, Atom, Atom*, int*, unsigned long*, unsigned long*, unsigned char**) = nullptr;
  int (*free_mem)(void*) = nullptr;
  Window (*default_root)(Display*) = nullptr;
  XErrorHandler (*set_error_handler)(XErrorHandler) = nullptr;
};

int ignore_errors(Display*, XErrorEvent*) { return 0; }

struct Impl {
  Api api;
  Display* dpy = nullptr;
  Window root = 0;
  Atom client_list = 0;
  Atom active = 0;
  Atom wm_pid = 0;
  Atom wm_state = 0;
  Atom hidden = 0;
  Atom wm_class = 0;
  Atom win_type = 0;
  Atom type_dock = 0;
  Atom type_desktop = 0;
};

bool load(Api& a) {
  a.lib = dlopen("libX11.so.6", RTLD_NOW);
  if (!a.lib) return false;
  a.open = reinterpret_cast<decltype(a.open)>(dlsym(a.lib, "XOpenDisplay"));
  a.close = reinterpret_cast<decltype(a.close)>(dlsym(a.lib, "XCloseDisplay"));
  a.intern = reinterpret_cast<decltype(a.intern)>(dlsym(a.lib, "XInternAtom"));
  a.get_property = reinterpret_cast<decltype(a.get_property)>(dlsym(a.lib, "XGetWindowProperty"));
  a.free_mem = reinterpret_cast<decltype(a.free_mem)>(dlsym(a.lib, "XFree"));
  a.default_root = reinterpret_cast<decltype(a.default_root)>(dlsym(a.lib, "XDefaultRootWindow"));
  a.set_error_handler = reinterpret_cast<decltype(a.set_error_handler)>(dlsym(a.lib, "XSetErrorHandler"));
  return a.open && a.close && a.intern && a.get_property && a.free_mem && a.default_root && a.set_error_handler;
}

std::vector<unsigned long> longs(Impl& x, Window w, Atom prop, Atom type) {
  std::vector<unsigned long> out;
  Atom actual = 0;
  int format = 0;
  unsigned long count = 0;
  unsigned long after = 0;
  unsigned char* data = nullptr;
  if (x.api.get_property(x.dpy, w, prop, 0, 4096, False, type, &actual, &format, &count, &after, &data) == Success && data) {
    if (format == 32) {
      const auto* p = reinterpret_cast<const unsigned long*>(data);
      out.assign(p, p + count);
    }
    x.api.free_mem(data);
  }
  return out;
}

std::string class_of(Impl& x, Window w, std::string* instance) {
  std::string out;
  Atom actual = 0;
  int format = 0;
  unsigned long count = 0;
  unsigned long after = 0;
  unsigned char* data = nullptr;
  if (x.api.get_property(x.dpy, w, x.wm_class, 0, 256, False, XA_STRING, &actual, &format, &count, &after, &data) == Success && data) {
    if (format == 8 && count > 0) {
      const char* s = reinterpret_cast<const char*>(data);
      std::size_t first = strnlen(s, count);
      if (instance) instance->assign(s, first);
      if (first + 1 < count) out.assign(s + first + 1, strnlen(s + first + 1, count - first - 1));
      if (out.empty()) out.assign(s, first);
    }
    x.api.free_mem(data);
  }
  return out;
}

}

X11Windows::X11Windows() {
  auto* x = new Impl();
  impl_ = x;
  if (!load(x->api)) return;
  x->api.set_error_handler(ignore_errors);
  x->dpy = x->api.open(nullptr);
  if (!x->dpy) return;
  x->root = x->api.default_root(x->dpy);
  x->client_list = x->api.intern(x->dpy, "_NET_CLIENT_LIST", True);
  x->active = x->api.intern(x->dpy, "_NET_ACTIVE_WINDOW", True);
  x->wm_pid = x->api.intern(x->dpy, "_NET_WM_PID", True);
  x->wm_state = x->api.intern(x->dpy, "_NET_WM_STATE", True);
  x->hidden = x->api.intern(x->dpy, "_NET_WM_STATE_HIDDEN", True);
  x->wm_class = x->api.intern(x->dpy, "WM_CLASS", True);
  x->win_type = x->api.intern(x->dpy, "_NET_WM_WINDOW_TYPE", True);
  x->type_dock = x->api.intern(x->dpy, "_NET_WM_WINDOW_TYPE_DOCK", True);
  x->type_desktop = x->api.intern(x->dpy, "_NET_WM_WINDOW_TYPE_DESKTOP", True);
  ok_ = x->client_list != 0;
}

X11Windows::~X11Windows() {
  auto* x = static_cast<Impl*>(impl_);
  if (x && x->dpy) x->api.close(x->dpy);
  delete x;
}

std::vector<X11Window> X11Windows::list() {
  std::vector<X11Window> out;
  auto* x = static_cast<Impl*>(impl_);
  if (!ok_ || !x->dpy) return out;
  auto active = longs(*x, x->root, x->active, XA_WINDOW);
  const unsigned long focus = active.empty() ? 0 : active[0];
  for (unsigned long id : longs(*x, x->root, x->client_list, XA_WINDOW)) {
    auto types = longs(*x, id, x->win_type, XA_ATOM);
    bool skip = false;
    for (unsigned long t : types) {
      if (t == x->type_dock || t == x->type_desktop) skip = true;
    }
    if (skip) continue;
    X11Window w;
    auto pid = longs(*x, id, x->wm_pid, XA_CARDINAL);
    w.pid = pid.empty() ? 0 : static_cast<long>(pid[0]);
    for (unsigned long s : longs(*x, id, x->wm_state, XA_ATOM)) {
      if (s == x->hidden) w.hidden = true;
    }
    w.active = id == focus;
    w.wm_class = class_of(*x, id, &w.wm_instance);
    out.push_back(std::move(w));
  }
  return out;
}

}

#else

namespace tw {

X11Windows::X11Windows() {}
X11Windows::~X11Windows() {}
std::vector<X11Window> X11Windows::list() { return {}; }

}

#endif
