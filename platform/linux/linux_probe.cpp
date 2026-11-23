#include <dlfcn.h>
#include "tw/platform.hpp"
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include <algorithm>
#include <cctype>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include "wayland_windows.hpp"
#include "x11_windows.hpp"

namespace fs = std::filesystem;

namespace tw {
namespace {

std::string process_name(const fs::path& dir) {
  std::ifstream cmd(dir / "cmdline", std::ios::binary);
  char c;
  if (!cmd.get(c)) return {};

  std::error_code ec;
  fs::path exe = fs::read_symlink(dir / "exe", ec);
  std::string name;
  if (!ec) {
    name = exe.filename().string();
  } else {
    std::ifstream comm(dir / "comm");
    std::getline(comm, name);
  }
  const std::string deleted = " (deleted)";
  if (name.size() > deleted.size() && name.compare(name.size() - deleted.size(), deleted.size(), deleted) == 0) {
    name.resize(name.size() - deleted.size());
  }
  return name;
}

std::string lower(std::string s) {
  for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

bool read_file(const fs::path& p, std::string& out) {
  std::ifstream f(p, std::ios::binary);
  if (!f) return false;
  std::ostringstream ss;
  ss << f.rdbuf();
  out = ss.str();
  return true;
}

long long field_kb(const std::string& text, const char* key) {
  size_t p = text.find(key);
  if (p == std::string::npos) return -1;
  return std::atoll(text.c_str() + p + std::char_traits<char>::length(key));
}

bool read_proc_stat(const fs::path& dir, long long& stamp, long long& cpu_ticks, long long& rss_pages) {
  std::string text;
  if (!read_file(dir / "stat", text)) return false;
  size_t close = text.rfind(')');
  if (close == std::string::npos) return false;
  std::istringstream in(text.substr(close + 2));
  std::string tok;
  long long utime = 0, stime = 0;
  for (int i = 3; i <= 24 && (in >> tok); ++i) {
    if (i == 14) utime = std::atoll(tok.c_str());
    else if (i == 15) stime = std::atoll(tok.c_str());
    else if (i == 22) stamp = std::atoll(tok.c_str());
    else if (i == 24) rss_pages = std::atoll(tok.c_str());
  }
  cpu_ticks = utime + stime;
  return true;
}

bool real_fs(const std::string& type) {
  static const char* kinds[] = {"ext2", "ext3", "ext4", "xfs", "btrfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3", "fuseblk", "zfs", "jfs", "reiserfs", "apfs", "hfsplus"};
  for (const char* k : kinds) {
    if (type == k) return true;
  }
  return false;
}

std::string unescape_mount(const std::string& s) {
  std::string out;
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '\\' && i + 3 < s.size() && std::isdigit(static_cast<unsigned char>(s[i + 1]))) {
      out += static_cast<char>(std::strtol(s.substr(i + 1, 3).c_str(), nullptr, 8));
      i += 3;
    } else {
      out += s[i];
    }
  }
  return out;
}


namespace {

struct XssInfo {
  unsigned long window;
  int state;
  int kind;
  unsigned long til_or_since;
  unsigned long idle;
  unsigned long event_mask;
};

long long xss_idle_ms() {
  static bool tried = false;
  static void* dpy = nullptr;
  static void* xss_lib = nullptr;
  static XssInfo* (*alloc)() = nullptr;
  static int (*query)(void*, unsigned long, XssInfo*) = nullptr;
  static void* (*open_display)(const char*) = nullptr;
  static unsigned long (*root_of)(void*) = nullptr;
  static XssInfo* info = nullptr;
  if (!tried) {
    tried = true;
    void* x11 = dlopen("libX11.so.6", RTLD_NOW);
    xss_lib = dlopen("libXss.so.1", RTLD_NOW);
    if (x11 && xss_lib) {
      open_display = reinterpret_cast<decltype(open_display)>(dlsym(x11, "XOpenDisplay"));
      root_of = reinterpret_cast<decltype(root_of)>(dlsym(x11, "XDefaultRootWindow"));
      alloc = reinterpret_cast<decltype(alloc)>(dlsym(xss_lib, "XScreenSaverAllocInfo"));
      query = reinterpret_cast<decltype(query)>(dlsym(xss_lib, "XScreenSaverQueryInfo"));
      if (open_display && root_of && alloc && query) {
        dpy = open_display(nullptr);
        if (dpy) info = alloc();
      }
    }
  }
  if (!dpy || !info) return -1;
  if (!query(dpy, root_of(dpy), info)) return -1;
  return static_cast<long long>(info->idle);
}

}

class LinuxProbe : public IProbe {
public:
  explicit LinuxProbe(bool include_system)
      : include_system_(include_system),
        last_wall_(static_cast<long long>(std::time(nullptr))),
        last_steady_(std::chrono::steady_clock::now()) {}

  std::vector<SysEvent> take_sys_events() override {
    std::vector<SysEvent> out;
    out.swap(pending_events_);
    return out;
  }

  bool reports_windows() const override { return wayland_.available() || windows_.available(); }

  std::string display_name(const std::string& app) override {
    auto it = labels_.find(app);
    return it == labels_.end() ? std::string() : it->second;
  }

  std::string exe_path(const std::string& app) override {
    auto it = paths_.find(app);
    return it == paths_.end() ? std::string() : it->second;
  }

  std::vector<AppSample> sample() override {
    std::map<std::string, State> best;
    std::error_code ec;
    const uid_t me = getuid();
    bool locker_running = false;
    for (fs::directory_iterator it("/proc", ec), end; !ec && it != end; it.increment(ec)) {
      const std::string id = it->path().filename().string();
      if (id.empty() || !std::all_of(id.begin(), id.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; })) continue;
      struct stat st{};
      if (stat(it->path().c_str(), &st) != 0) continue;
      std::string name = process_name(it->path());
      if (name.empty()) continue;
      if (st.st_uid == me && is_locker_process(name)) locker_running = true;
      if (!include_system_ && st.st_uid != me) continue;
      best.emplace(std::move(name), State::Background);
    }
    update_power_lock(locker_running);
    std::vector<X11Window> listed = wayland_.available() ? wayland_.list() : windows_.list();
    if (wayland_.available() && listed.empty()) listed = windows_.list();
    for (const auto& w : listed) {
      std::string name;
      if (w.pid > 0) name = process_name(fs::path("/proc") / std::to_string(w.pid));
      if (name.empty() && !w.wm_instance.empty()) {
        std::string want = lower(w.wm_instance);
        for (const auto& kv : best) {
          if (lower(kv.first) == want) {
            name = kv.first;
            break;
          }
        }
      }
      if (name.empty()) name = w.wm_class;
      if (name.empty()) continue;
      State s = w.active ? State::Focused : (w.hidden ? State::Minimized : State::Open);
      auto found = best.find(name);
      if (found == best.end()) best.emplace(name, s);
      else if (static_cast<int>(s) < static_cast<int>(found->second)) found->second = s;
      if (!w.wm_class.empty()) labels_[name] = w.wm_class;
      if (w.pid > 0 && !paths_.count(name)) {
        std::error_code pe;
        fs::path exe = fs::read_symlink(fs::path("/proc") / std::to_string(w.pid) / "exe", pe);
        if (!pe) paths_[name] = exe.string();
      }
    }
    std::vector<AppSample> out;
    out.reserve(best.size());
    for (auto& kv : best) out.push_back({kv.first, kv.second});
    return out;
  }

  bool supports_metrics() const override { return true; }

  long long idle_ms() override { return xss_idle_ms(); }

  std::vector<ProcSnap> proc_snapshot() override {
    std::vector<ProcSnap> out;
    std::error_code ec;
    const uid_t me = getuid();
    const long long tick_ms = std::max<long long>(1, 1000 / std::max<long>(1, sysconf(_SC_CLK_TCK)));
    const long long page_kb = std::max<long>(1, sysconf(_SC_PAGESIZE) / 1024);
    for (fs::directory_iterator it("/proc", ec), end; !ec && it != end; it.increment(ec)) {
      const std::string id = it->path().filename().string();
      if (id.empty() || !std::all_of(id.begin(), id.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; })) continue;
      struct stat st{};
      if (stat(it->path().c_str(), &st) != 0) continue;
      if (!include_system_ && st.st_uid != me) continue;
      std::string name = process_name(it->path());
      if (name.empty()) continue;
      ProcSnap p;
      long long ticks = 0, pages = 0;
      if (!read_proc_stat(it->path(), p.stamp, ticks, pages)) continue;
      p.pid = std::atoll(id.c_str());
      p.app = std::move(name);
      p.cpu_ms = ticks * tick_ms;
      p.rss_kb = pages * page_kb;
      std::string text;
      if (read_file(it->path() / "status", text)) {
        long long hwm = field_kb(text, "VmHWM:");
        long long anon = field_kb(text, "RssAnon:");
        if (anon >= 0 && anon < p.rss_kb) p.rss_kb = anon;
        p.peak_kb = hwm > 0 ? std::max(hwm, p.rss_kb) : p.rss_kb;
      } else {
        p.peak_kb = p.rss_kb;
      }
      if (read_file(it->path() / "io", text)) {
        long long r = field_kb(text, "rchar:");
        long long w = field_kb(text, "wchar:");
        long long rb = field_kb(text, "read_bytes:");
        long long wb = field_kb(text, "write_bytes:");
        p.io_read = rb >= 0 ? rb : std::max<long long>(0, r);
        p.io_write = wb >= 0 ? wb : std::max<long long>(0, w);
      }
      out.push_back(std::move(p));
    }
    return out;
  }

  SysStat sys_stat() override {
    SysStat st;
    std::string text;
    if (read_file("/proc/meminfo", text)) {
      long long total = field_kb(text, "MemTotal:");
      long long avail = field_kb(text, "MemAvailable:");
      if (total > 0) {
        st.ram_total_kb = total;
        st.ram_avail_kb = avail >= 0 ? avail : 0;
        st.valid = true;
      }
    }
    std::ifstream mounts("/proc/mounts");
    std::string line;
    std::set<std::string> seen;
    while (std::getline(mounts, line) && st.disks.size() < 8) {
      std::istringstream in(line);
      std::string dev, mp, type;
      if (!(in >> dev >> mp >> type)) continue;
      if (!real_fs(type) || dev.compare(0, 5, "/dev/") != 0 || !seen.insert(dev).second) continue;
      mp = unescape_mount(mp);
      struct statvfs vfs{};
      if (statvfs(mp.c_str(), &vfs) != 0 || vfs.f_blocks == 0) continue;
      DiskStat d;
      d.mount = mp;
      d.total_kb = static_cast<long long>(vfs.f_blocks) * static_cast<long long>(vfs.f_frsize) / 1024;
      d.free_kb = static_cast<long long>(vfs.f_bavail) * static_cast<long long>(vfs.f_frsize) / 1024;
      st.disks.push_back(std::move(d));
    }
    return st;
  }

private:
  static bool is_locker_process(const std::string& name) {
    static const char* kLockers[] = {
        "kscreenlocker_greet", "swaylock", "hyprlock", "i3lock",
        "gtklock", "slock", "xsecurelock", "waylock", "gnome-screensaver-dialog"};
    std::string lo = lower(name);
    for (const char* lk : kLockers) {
      if (lo == lk) return true;
    }
    return false;
  }

  void update_power_lock(bool is_locked) {
    long long wall = static_cast<long long>(std::time(nullptr));
    auto steady = std::chrono::steady_clock::now();
    long long wall_d = wall - last_wall_;
    long long steady_d = std::chrono::duration_cast<std::chrono::seconds>(steady - last_steady_).count();
    long long sleep_s = wall_d - steady_d;
    if (sleep_s >= 20 && sleep_s < 86400LL * 90) {
      pending_events_.push_back({last_wall_, "sleep", sleep_s * 1000LL, ""});
    }
    last_wall_ = wall;
    last_steady_ = steady;

    if (is_locked && !locked_) {
      locked_ = true;
      lock_start_ = wall;
    } else if (!is_locked && locked_) {
      locked_ = false;
      long long dur_s = wall - lock_start_;
      if (dur_s >= 1 && dur_s < 86400LL * 90) {
        pending_events_.push_back({lock_start_, "lock", dur_s * 1000LL, ""});
      }
    }
  }

  bool include_system_;
  X11Windows windows_;
  WaylandWindows wayland_;
  std::map<std::string, std::string> labels_;
  std::map<std::string, std::string> paths_;
  long long last_wall_ = 0;
  std::chrono::steady_clock::time_point last_steady_;
  bool locked_ = false;
  long long lock_start_ = 0;
  std::vector<SysEvent> pending_events_;
};

}

std::unique_ptr<IProbe> make_native_probe(const ProbeOptions& options) {
  return std::make_unique<LinuxProbe>(options.include_system);
}

}
