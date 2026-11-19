#include "tw/platform.hpp"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace tw {
namespace {

std::string to_std(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }

std::string icons_dir() {
  const char* home = std::getenv("HOME");
  if (!home || !*home) return {};
  return std::string(home) + "/Library/Application Support/DTSys/Wolium/icons";
}

std::string safe_name(const std::string& name) {
  std::string out = name;
  for (auto& c : out) {
    if (c == '/' || c == ':' || c == '\\') c = '_';
  }
  return out;
}

bool write_icon(NSRunningApplication* app, const std::string& path) {
  NSImage* image = app.icon;
  if (!image) return false;
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                  pixelsWide:64
                                                                  pixelsHigh:64
                                                               bitsPerSample:8
                                                             samplesPerPixel:4
                                                                    hasAlpha:YES
                                                                    isPlanar:NO
                                                              colorSpaceName:NSCalibratedRGBColorSpace
                                                                 bytesPerRow:0
                                                                bitsPerPixel:0];
  if (!rep) return false;
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
  [image drawInRect:NSMakeRect(0, 0, 64, 64) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
  [NSGraphicsContext restoreGraphicsState];
  NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  if (!png) return false;
  return [png writeToFile:[NSString stringWithUTF8String:path.c_str()] atomically:YES];
}

struct WindowCount {
  int onscreen = 0;
  int total = 0;
};

void count_windows(CGWindowListOption options, std::map<pid_t, WindowCount>& out, bool onscreen, pid_t* front) {
  NSArray* list = (__bridge_transfer NSArray*)CGWindowListCopyWindowInfo(options | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  for (NSDictionary* d in list) {
    int layer = [d[(id)kCGWindowLayer] intValue];
    if (layer != 0) continue;
    CGRect rect = CGRectZero;
    NSDictionary* bounds = d[(id)kCGWindowBounds];
    if (bounds) CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &rect);
    if (rect.size.width < 80 || rect.size.height < 40) continue;
    if ([d[(id)kCGWindowAlpha] doubleValue] <= 0.0) continue;
    pid_t pid = [d[(id)kCGWindowOwnerPID] intValue];
    WindowCount& c = out[pid];
    ++c.total;
    if (onscreen) {
      ++c.onscreen;
      if (front && *front < 0) *front = pid;
    }
  }
}

class MacProbe : public IProbe {
public:
  explicit MacProbe(bool include_system) : include_system_(include_system) {}

  bool reports_windows() const override { return true; }

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
    @autoreleasepool {
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
      std::map<pid_t, WindowCount> visible;
      std::map<pid_t, WindowCount> all;
      pid_t front = -1;
      count_windows(kCGWindowListOptionOnScreenOnly, visible, true, &front);
      count_windows(kCGWindowListOptionAll, all, false, nullptr);
      NSRunningApplication* active = [[NSWorkspace sharedWorkspace] frontmostApplication];
      if (front < 0 && active) front = active.processIdentifier;
      const std::string icons = icons_dir();
      for (NSRunningApplication* app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        NSApplicationActivationPolicy policy = app.activationPolicy;
        if (policy == NSApplicationActivationPolicyProhibited && !include_system_) continue;
        pid_t pid = app.processIdentifier;
        std::string name = app.executableURL ? to_std(app.executableURL.lastPathComponent) : std::string();
        if (name.empty()) name = to_std(app.localizedName);
        if (name.empty()) continue;
        State s;
        if (pid == front) s = State::Focused;
        else if (policy != NSApplicationActivationPolicyRegular) s = State::Background;
        else if (app.hidden) s = State::Minimized;
        else if (visible[pid].onscreen > 0) s = State::Open;
        else if (all[pid].total > 0) s = State::Minimized;
        else s = State::Background;
        auto found = best.find(name);
        if (found == best.end()) best.emplace(name, s);
        else if (static_cast<int>(s) < static_cast<int>(found->second)) found->second = s;
        if (!labels_.count(name)) {
          std::string label = to_std(app.localizedName);
          if (!label.empty()) labels_[name] = label;
        }
        if (!paths_.count(name) && !icons.empty()) {
          std::error_code ec;
          fs::create_directories(icons, ec);
          std::string file = icons + "/" + safe_name(name) + ".png";
          if (fs::exists(file, ec) || write_icon(app, file)) paths_[name] = file;
        }
      }
    }
    std::vector<AppSample> out;
    out.reserve(best.size());
    for (auto& kv : best) out.push_back({kv.first, kv.second});
    return out;
  }

  bool supports_metrics() const override { return true; }

  std::vector<ProcSnap> proc_snapshot() override {
    std::vector<ProcSnap> out;
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    const double to_ms = tb.denom ? (static_cast<double>(tb.numer) / static_cast<double>(tb.denom)) / 1e6 : 1e-6;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, nullptr, 0);
    if (bytes <= 0) return out;
    std::vector<pid_t> pids(static_cast<size_t>(bytes) / sizeof(pid_t) + 16);
    bytes = proc_listpids(PROC_ALL_PIDS, 0, pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
    if (bytes <= 0) return out;
    const size_t count = static_cast<size_t>(bytes) / sizeof(pid_t);
    const uid_t me = getuid();
    for (size_t i = 0; i < count; ++i) {
      pid_t pid = pids[i];
      if (pid <= 0) continue;
      struct proc_bsdshortinfo bsd{};
      if (!include_system_) {
        if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, sizeof(bsd)) != static_cast<int>(sizeof(bsd))) continue;
        if (bsd.pbsi_uid != me) continue;
      }
      char path[PROC_PIDPATHINFO_MAXSIZE];
      if (proc_pidpath(pid, path, sizeof(path)) <= 0) continue;
      std::string full(path);
      size_t slash = full.find_last_of('/');
      std::string name = slash == std::string::npos ? full : full.substr(slash + 1);
      if (name.empty()) continue;
      rusage_info_current ru{};
      if (proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, reinterpret_cast<rusage_info_t*>(&ru)) != 0) continue;
      ProcSnap p;
      p.pid = pid;
      p.stamp = static_cast<long long>(ru.ri_proc_start_abstime);
      p.app = std::move(name);
      p.cpu_ms = static_cast<long long>(static_cast<double>(ru.ri_user_time + ru.ri_system_time) * to_ms);
      p.rss_kb = static_cast<long long>(ru.ri_resident_size / 1024);
      p.peak_kb = static_cast<long long>(ru.ri_lifetime_max_phys_footprint / 1024);
      if (p.peak_kb < p.rss_kb) p.peak_kb = p.rss_kb;
      p.io_read = static_cast<long long>(ru.ri_diskio_bytesread);
      p.io_write = static_cast<long long>(ru.ri_diskio_byteswritten);
      out.push_back(std::move(p));
    }
    return out;
  }

  SysStat sys_stat() override {
    SysStat st;
    uint64_t total = 0;
    size_t len = sizeof(total);
    if (sysctlbyname("hw.memsize", &total, &len, nullptr, 0) != 0 || total == 0) return st;
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    vm_statistics64_data_t vm{};
    mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&vm), &n) != KERN_SUCCESS) return st;
    uint64_t avail = (static_cast<uint64_t>(vm.free_count) + vm.inactive_count + vm.purgeable_count) * page;
    st.ram_total_kb = static_cast<long long>(total / 1024);
    st.ram_avail_kb = static_cast<long long>(avail / 1024);
    st.valid = true;
    struct statfs* fs_list = nullptr;
    int fc = getmntinfo(&fs_list, MNT_NOWAIT);
    for (int i = 0; i < fc && st.disks.size() < 8; ++i) {
      const struct statfs& f = fs_list[i];
      if (f.f_flags & MNT_DONTBROWSE) continue;
      if (std::string(f.f_mntfromname).compare(0, 5, "/dev/") != 0) continue;
      std::string mp = f.f_mntonname;
      if (mp.compare(0, 11, "/System/Vol") == 0 && mp != "/System/Volumes/Data") continue;
      if (mp == "/System/Volumes/Data") mp = "/";
      DiskStat d;
      d.mount = mp;
      d.total_kb = static_cast<long long>(f.f_blocks) * static_cast<long long>(f.f_bsize) / 1024;
      d.free_kb = static_cast<long long>(f.f_bavail) * static_cast<long long>(f.f_bsize) / 1024;
      bool dup = false;
      for (const auto& e : st.disks) dup = dup || (e.total_kb == d.total_kb && e.free_kb == d.free_kb);
      if (!dup && d.total_kb > 0) st.disks.push_back(std::move(d));
    }
    return st;
  }

private:
  bool include_system_;
  std::map<std::string, std::string> labels_;
  std::map<std::string, std::string> paths_;
};

}

std::unique_ptr<IProbe> make_native_probe(const ProbeOptions& options) {
  return std::make_unique<MacProbe>(options.include_system);
}

}
