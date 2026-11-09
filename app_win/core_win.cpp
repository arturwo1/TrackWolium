#include <algorithm>
#include <fstream>
#include <memory>
#include <string>
#include "common_win.hpp"
#include <shellapi.h>
#include "tw/engine.hpp"
#include "tw/ipc.hpp"
#include "tw/platform.hpp"
#include "tw/serialize.hpp"
#include "tw/sqlite_store.hpp"

namespace {

class PipeSink : public tw::ISink {
public:
  explicit PipeSink(tw::ReportServer& server) : server_(server) {}
  void render(const tw::Report& report) override { server_.publish(tw::serialize(report)); }

private:
  tw::ReportServer& server_;
};

struct Options {
  bool no_db = false;
  int interval_ms = 1000;
  std::string db;
};

Options parse_options() {
  Options o;
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return o;
  for (int i = 1; i < argc; ++i) {
    std::wstring k = argv[i];
    if (k == L"--no-db") o.no_db = true;
    else if (k == L"--db" && i + 1 < argc) o.db = tw::to_utf8(argv[++i]);
    else if (k == L"--interval" && i + 1 < argc) {
      int v = _wtoi(argv[++i]);
      if (v >= 100) o.interval_ms = v;
    }
  }
  LocalFree(argv);
  return o;
}

void write_text(const std::wstring& path, const std::string& text) {
  std::ofstream out(std::filesystem::path(path), std::ios::trunc);
  out << text;
}

}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  HANDLE mutex = CreateMutexW(nullptr, TRUE, app::kCoreMutex);
  if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) return 0;
  if (!app::consent_given()) return 0;

  Options opt = parse_options();
  HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, app::kCoreStopEvent);
  if (!stop) return 1;

  write_text(app::userdata(L"core.pid"), std::to_string(GetCurrentProcessId()));

  tw::ReportServer server;
  server.start(tw::default_pipe_name());

  tw::ProbeOptions po;
  std::shared_ptr<tw::IProbe> probe = tw::make_native_probe(po);
  tw::Engine engine(probe, tw::Duration(std::max(5000, opt.interval_ms * 3)));
  if (!opt.no_db) {
    std::string path = opt.db.empty() ? tw::to_utf8(app::userdata(L"usage.db")) : opt.db;
    std::string err;
    auto store = tw::SqliteStore::open(path, &err);
    if (store) engine.set_store(std::shared_ptr<tw::IStore>(std::move(store)), tw::Duration(3000));
  }
  engine.add_sink(std::make_shared<PipeSink>(server));

  const std::wstring heartbeat = app::userdata(L"heartbeat");
  ULONGLONG last_beat = 0;
  for (;;) {
    ULONGLONG now = GetTickCount64();
    if (now - last_beat >= 2000) {
      write_text(heartbeat, std::to_string(now));
      last_beat = now;
    }
    if (!app::consent_given()) break;
    if (!app::paused()) engine.step(tw::Clock::now());
    if (WaitForSingleObject(stop, static_cast<DWORD>(opt.interval_ms)) == WAIT_OBJECT_0) break;
  }

  engine.finish();
  server.stop();
  CloseHandle(stop);
  CloseHandle(mutex);
  return 0;
}
