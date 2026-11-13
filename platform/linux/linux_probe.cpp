#include "tw/platform.hpp"
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
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

class LinuxProbe : public IProbe {
public:
  explicit LinuxProbe(bool include_system) : include_system_(include_system) {}

  bool reports_windows() const override { return windows_.available(); }

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
    for (fs::directory_iterator it("/proc", ec), end; !ec && it != end; it.increment(ec)) {
      const std::string id = it->path().filename().string();
      if (id.empty() || !std::all_of(id.begin(), id.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; })) continue;
      struct stat st{};
      if (stat(it->path().c_str(), &st) != 0) continue;
      if (!include_system_ && st.st_uid != me) continue;
      std::string name = process_name(it->path());
      if (name.empty()) continue;
      best.emplace(std::move(name), State::Background);
    }
    for (const auto& w : windows_.list()) {
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

private:
  bool include_system_;
  X11Windows windows_;
  std::map<std::string, std::string> labels_;
  std::map<std::string, std::string> paths_;
};

}

std::unique_ptr<IProbe> make_native_probe(const ProbeOptions& options) {
  return std::make_unique<LinuxProbe>(options.include_system);
}

}
