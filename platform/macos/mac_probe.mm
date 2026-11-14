#include "tw/platform.hpp"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <sys/types.h>
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
