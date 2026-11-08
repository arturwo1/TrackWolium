#include "tw/platform.hpp"
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>

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

class LinuxProbe : public IProbe {
public:
  explicit LinuxProbe(bool include_system) : include_system_(include_system) {}

  bool reports_windows() const override { return false; }

  std::vector<AppSample> sample() override {
    std::vector<AppSample> out;
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
      out.push_back({std::move(name), State::Background});
    }
    return out;
  }

private:
  bool include_system_;
};

}

std::unique_ptr<IProbe> make_native_probe(const ProbeOptions& options) {
  return std::make_unique<LinuxProbe>(options.include_system);
}

}
