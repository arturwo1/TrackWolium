#include <algorithm>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include "tw/console_sink.hpp"
#include "tw/engine.hpp"
#include "tw/filter.hpp"
#include "tw/ipc.hpp"
#include "tw/paths.hpp"
#include "tw/platform.hpp"
#include "tw/serialize.hpp"
#include "tw/sqlite_store.hpp"
#include "tw/tracker.hpp"

namespace {

volatile std::sig_atomic_t g_stop = 0;

void on_signal(int) {
  g_stop = 1;
}

struct Args {
  int interval_ms = 1000;
  int top = 20;
  int seconds = 0;
  bool color = true;
  bool system = false;
  bool all = false;
  bool no_db = false;
  bool standalone = false;
  bool connect_only = false;
  int history = 0;
  std::string db;
  std::string ignore;
  bool help = false;
  bool bad = false;
};

Args parse(int argc, char** argv) {
  Args a;
  for (int i = 1; i < argc; ++i) {
    std::string k = argv[i];
    auto value = [&](int& out) {
      if (i + 1 >= argc) {
        a.bad = true;
        return;
      }
      out = std::atoi(argv[++i]);
    };
    if (k == "--ignore") {
      if (i + 1 >= argc) a.bad = true;
      else a.ignore = argv[++i];
    }
    else if (k == "--db") {
      if (i + 1 >= argc) a.bad = true;
      else a.db = argv[++i];
    }
    else if (k == "--history") value(a.history);
    else if (k == "--no-db") a.no_db = true;
    else if (k == "--standalone") a.standalone = true;
    else if (k == "--connect-only") a.connect_only = true;
    else if (k == "--interval") value(a.interval_ms);
    else if (k == "--top") value(a.top);
    else if (k == "--for") value(a.seconds);
    else if (k == "--no-color") a.color = false;
    else if (k == "--system") a.system = true;
    else if (k == "--all") a.all = true;
    else if (k == "--help" || k == "-h") a.help = true;
    else a.bad = true;
  }
  if (a.interval_ms < 100 || a.top < 1 || a.seconds < 0 || a.history < 0) a.bad = true;
  return a;
}

void usage(std::ostream& o) {
  o << "usage: trackwolium-console [--interval MS] [--top N] [--for SECONDS] [--no-color] [--system] [--all] [--ignore LIST]\n"
    << "                          [--db PATH] [--no-db] [--history N] [--standalone] [--connect-only]\n"
    << "  --interval MS   sampling period, default 1000, min 100\n"
    << "  --top N         rows to show, default 20\n"
    << "  --for SECONDS   run N seconds, print one plain report and exit\n"
    << "  --no-color      disable colors\n"
    << "  --system        include system processes\n"
    << "  --all           also show apps that never had a window\n"
    << "  --ignore LIST   comma separated exe names to hide, e.g. a.exe,b.exe\n"
    << "  --db PATH       sqlite file, default in the user data dir\n"
    << "  --no-db         do not read or write history\n"
    << "  --history N     print the last N saved days and exit\n"
    << "  --standalone    do not attach to the tray app, track on its own\n"
    << "  --connect-only  attach to the tray app only, fail if it is not running\n";
}

std::shared_ptr<tw::SqliteStore> open_store(const Args& a) {
  std::string path = a.db.empty() ? tw::default_db_path() : a.db;
  if (path.empty()) {
    std::cerr << "history disabled: no data directory\n";
    return nullptr;
  }
  std::string err;
  auto store = tw::SqliteStore::open(path, &err);
  if (!store) {
    std::cerr << "history disabled: " << err << "\n";
    return nullptr;
  }
  return std::shared_ptr<tw::SqliteStore>(std::move(store));
}

tw::FilterOptions make_filter(const Args& a, bool reports_windows) {
  tw::FilterOptions fo;
  fo.hide_background_only = !a.all && reports_windows;
  fo.ignore = tw::default_ignore();
  for (const auto& name : tw::parse_ignore_list(a.ignore)) fo.ignore.insert(name);
  return fo;
}

int run_history(const Args& a, bool tty) {
  auto store = open_store(a);
  if (!store) return 1;
  auto days = store->days(a.history);
  if (days.empty()) {
    std::cout << "no history yet\n";
    return 0;
  }
  for (const auto& day : days) {
    tw::Tracker t(tw::Duration(5000));
    t.seed(store->load_day(day));
    tw::ConsoleOptions co;
    co.color = a.color && tty;
    co.live = false;
    co.top = static_cast<std::size_t>(a.top);
    co.title = day;
    co.show_uptime = false;
    auto sink = std::make_shared<tw::ConsoleSink>(std::cout, co);
    tw::FilteredSink view(sink, make_filter(a, true));
    view.render(t.report());
  }
  return 0;
}

int run_remote(const Args& a, bool tty, tw::ReportClient& client) {
  bool live = tty && a.seconds == 0;
  tw::ConsoleOptions co;
  co.color = a.color && tty;
  co.live = live;
  co.top = static_cast<std::size_t>(a.top);
  auto sink = std::make_shared<tw::ConsoleSink>(std::cout, co);
  tw::FilteredSink view(sink, make_filter(a, true));

  const auto start = tw::Clock::now();
  tw::Report last;
  bool have = false;
  while (!g_stop) {
    if (a.seconds > 0 && tw::Clock::now() - start >= std::chrono::seconds(a.seconds)) break;
    std::string payload;
    auto r = client.read(payload, 200);
    if (r == tw::ReadResult::Closed) {
      std::cerr << "tray app closed the connection\n";
      break;
    }
    if (r == tw::ReadResult::Ok && tw::deserialize(payload, last)) {
      have = true;
      if (live) view.render(last);
    }
  }
  if (!live && have) view.render(last);
  return have || g_stop ? 0 : 1;
}

}

int main(int argc, char** argv) {
  Args a = parse(argc, argv);
  if (a.help || a.bad) {
    usage(a.bad ? std::cerr : std::cout);
    return a.bad ? 2 : 0;
  }

  bool tty = tw::console_setup();
  bool live = tty && a.seconds == 0;
  std::signal(SIGINT, on_signal);
  std::signal(SIGTERM, on_signal);

  if (a.history > 0) return run_history(a, tty);

  if (!a.standalone) {
    tw::ReportClient client;
    if (client.connect(tw::default_pipe_name(), a.connect_only ? 3000 : 250)) return run_remote(a, tty, client);
    if (a.connect_only) {
      std::cerr << "tray app is not running\n";
      return 1;
    }
  }

  tw::ConsoleOptions co;
  co.color = a.color && tty;
  co.live = live;
  co.top = static_cast<std::size_t>(a.top);
  auto sink = std::make_shared<tw::ConsoleSink>(std::cout, co);

  tw::ProbeOptions po;
  po.include_system = a.system;
  std::shared_ptr<tw::IProbe> probe = tw::make_native_probe(po);
  tw::Engine engine(probe, tw::Duration(std::max(5000, a.interval_ms * 3)));
  if (!a.no_db) {
    auto store = open_store(a);
    if (store) engine.set_store(store);
  }
  auto view = std::make_shared<tw::FilteredSink>(sink, make_filter(a, probe->reports_windows()));
  if (live) engine.add_sink(view);

  const auto start = tw::Clock::now();
  auto stop = [&]() {
    if (g_stop) return true;
    return a.seconds > 0 && tw::Clock::now() - start >= std::chrono::seconds(a.seconds);
  };
  engine.run(tw::Duration(a.interval_ms), stop);
  engine.finish();

  if (!live) view->render(engine.report());
  return 0;
}
