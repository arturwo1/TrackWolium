#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#include <spawn.h>
#include <atomic>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <ctime>
#include "tw/engine.hpp"
#include "tw/platform.hpp"
#include "tw/serialize.hpp"
#include "tw/sink.hpp"
#include "tw/sqlite_store.hpp"

extern char** environ;

namespace fs = std::filesystem;

namespace {

std::atomic<bool> g_stop{false};
std::atomic<bool> g_flush{false};

void on_stop(int) { g_stop = true; }
void on_flush(int) { g_flush = true; }

std::string env(const char* name) {
  const char* v = std::getenv(name);
  return v ? v : "";
}

std::string home_tag() {
  std::string home = env("HOME");
  size_t slash = home.find_last_of('/');
  std::string tag = slash == std::string::npos ? home : home.substr(slash + 1);
  return tag.empty() ? "user" : tag;
}

std::string data_dir() {
#ifdef __APPLE__
  std::string mac_home = env("HOME");
  if (mac_home.empty()) return {};
  return mac_home + "/Library/Application Support/DTSys/Wolium";
#endif
  std::string base = env("XDG_DATA_HOME");
  if (base.empty()) {
    std::string home = env("HOME");
    if (home.empty()) return {};
    base = home + "/.local/share";
  }
  return base + "/DTSys/Wolium";
}

std::string runtime_dir() {
#ifdef __APPLE__
  return "/tmp/wolium-" + home_tag();
#endif
  std::string base = env("XDG_RUNTIME_DIR");
  if (!base.empty()) return base + "/wolium";
  std::string user = env("USER");
  if (user.empty()) user = env("LOGNAME");
  if (user.empty()) user = "user";
  return "/tmp/wolium-" + user;
}

bool exists(const std::string& path) {
  std::error_code ec;
  return fs::exists(path, ec);
}

void write_atomic(const std::string& path, const std::string& text) {
  std::string tmp = path + ".tmp";
  {
    std::ofstream out(tmp, std::ios::trunc | std::ios::binary);
    out << text;
  }
  std::error_code ec;
  fs::rename(tmp, path, ec);
}

std::string exe_dir() {
#ifdef __APPLE__
  char buf[4096];
  uint32_t size = sizeof(buf);
  if (_NSGetExecutablePath(buf, &size) != 0) return {};
  return fs::path(buf).parent_path().string();
#else
  std::error_code ec;
  fs::path p = fs::read_symlink("/proc/self/exe", ec);
  return ec ? std::string() : p.parent_path().string();
#endif
}

void run_update_check(const std::string& dir) {
  std::string script = dir + "/update-check.sh";
  if (dir.empty() || !exists(script)) return;
  char* args[] = {const_cast<char*>("sh"), const_cast<char*>(script.c_str()), nullptr};
  pid_t pid = 0;
  if (posix_spawn(&pid, "/bin/sh", nullptr, nullptr, args, environ) == 0) {
    std::thread([pid] {
      int status = 0;
      waitpid(pid, &status, 0);
    }).detach();
  }
}

class LiveSink : public tw::ISink {
public:
  LiveSink(std::string path, std::string alive) : path_(std::move(path)), alive_(std::move(alive)) {}

  void render(const tw::Report& report) override {
#ifdef __APPLE__
    struct stat st{};
    if (stat(alive_.c_str(), &st) != 0 || std::time(nullptr) - st.st_mtime > 8) return;
#endif
    write_atomic(path_, tw::serialize(report));
  }

private:
  std::string path_;
  std::string alive_;
};

struct Options {
  bool no_db = false;
  int interval_ms = 2000;
  std::string db;
  std::string data;
  std::string runtime;
};

Options parse(int argc, char** argv) {
  Options o;
  for (int i = 1; i < argc; ++i) {
    std::string k = argv[i];
    if (k == "--no-db") o.no_db = true;
    else if (k == "--db" && i + 1 < argc) o.db = argv[++i];
    else if (k == "--data-dir" && i + 1 < argc) o.data = argv[++i];
    else if (k == "--runtime-dir" && i + 1 < argc) o.runtime = argv[++i];
    else if (k == "--interval" && i + 1 < argc) {
      int v = std::atoi(argv[++i]);
      if (v >= 100) o.interval_ms = v;
    }
  }
  return o;
}

}

int main(int argc, char** argv) {
  Options opt = parse(argc, argv);
  std::string data = opt.data.empty() ? data_dir() : opt.data;
  std::string runtime = opt.runtime.empty() ? runtime_dir() : opt.runtime;
  if (data.empty()) return 1;
  std::error_code ec;
  fs::create_directories(data, ec);
  fs::create_directories(runtime, ec);
  chmod(runtime.c_str(), 0700);

  int lock = open((runtime + "/core.lock").c_str(), O_CREAT | O_RDWR, 0600);
  if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) return 0;
  if (!exists(data + "/consent")) return 0;

  std::signal(SIGTERM, on_stop);
  std::signal(SIGINT, on_stop);
  std::signal(SIGUSR1, on_flush);

  tw::ProbeOptions po;
  std::shared_ptr<tw::IProbe> probe = tw::make_native_probe(po);
  tw::Engine engine(probe, tw::Duration(std::max(5000, opt.interval_ms * 3)));
  if (!opt.no_db) {
    std::string path = opt.db.empty() ? data + "/usage.db" : opt.db;
    std::string err;
    auto store = tw::SqliteStore::open(path, &err);
    if (store) engine.set_store(std::shared_ptr<tw::IStore>(std::move(store)), tw::Duration(180000));
  }
  engine.add_sink(std::make_shared<LiveSink>(runtime + "/live", runtime + "/ui.alive"));

  const std::string flush_file = runtime + "/flush";
  const std::string bin_dir = exe_dir();
  auto next_check = std::chrono::steady_clock::now() + std::chrono::seconds(90);
  int ticks = 0;
  bool allowed = true;
  bool paused = false;
  while (!g_stop) {
    if (ticks % 2 == 0) {
      allowed = exists(data + "/consent");
      paused = exists(data + "/paused");
    }
    ++ticks;
    if (!allowed) break;
    if (std::chrono::steady_clock::now() >= next_check) {
      next_check = std::chrono::steady_clock::now() + std::chrono::hours(6);
      if (!exists(data + "/noupdates")) run_update_check(bin_dir);
    }
    if (!paused) engine.step(tw::Clock::now());
    for (int waited = 0; waited < opt.interval_ms && !g_stop; waited += 100) {
      if (g_flush || exists(flush_file)) {
        g_flush = false;
        fs::remove(flush_file, ec);
        engine.flush();
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }

  engine.finish();
  fs::remove(runtime + "/live", ec);
  return 0;
}
