#pragma once
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <tuple>
#include <string>
#include <utility>
#include <vector>
#include "tw/limits.hpp"
#include "tw/probe.hpp"
#include "tw/sink.hpp"
#include "tw/store.hpp"
#include "tw/tracker.hpp"

namespace tw {

std::string local_day_now();
Duration parse_afk_threshold(const std::string& text);
int local_slot_now();

class Engine {
public:
  explicit Engine(std::shared_ptr<IProbe> probe, Duration max_gap = Duration(5000));

  void add_sink(std::shared_ptr<ISink> sink);
  void set_day_source(std::function<std::string()> day);
  void set_slot_source(std::function<int()> slot);
  void set_wall_source(std::function<long long()> wall);
  void set_metrics(const MetricsConfig& cfg);
  void set_metrics_intervals(Duration proc, Duration sys);
  void set_afk_threshold(Duration threshold);
  void set_limits(std::vector<Limit> limits);
  void set_limit_notifier(std::function<void(const Limit&, long long)> notify);
  void set_store(std::shared_ptr<IStore> store, Duration flush_every = Duration(180000));
  void step(TimePoint now);
  void run(Duration interval, const std::function<bool()>& stop);
  void finish();
  void flush();
  Report report() const;

private:
  void flush_pending();
  void note_session(const Interval& iv);
  void check_limits(TimePoint now);
  void sample_metrics(TimePoint now, const std::vector<AppSample>& samples);

  std::shared_ptr<IProbe> probe_;
  std::vector<std::shared_ptr<ISink>> sinks_;
  Duration max_gap_;
  Tracker tracker_;
  std::shared_ptr<IStore> store_;
  std::function<std::string()> day_fn_;
  std::string day_;
  std::map<std::pair<std::string, int>, Duration> pending_;
  Duration flush_every_{180000};
  std::string last_focus_;
  std::function<int()> slot_fn_;
  std::map<std::tuple<int, std::string, int>, long long> pending_slots_;
  std::map<std::pair<int, std::string>, long long> pending_afk_;
  Duration afk_threshold_{0};
  std::vector<Limit> limits_;
  std::function<void(const Limit&, long long)> limit_notify_;
  std::set<std::string> limits_fired_;
  std::string limits_day_;
  TimePoint last_limit_check_{};
  bool limit_checked_ = false;
  std::function<long long()> wall_fn_;
  struct OpenSession {
    int state = 0;
    long long start = 0;
    long long stop = 0;
  };
  std::map<std::string, OpenSession> open_;
  std::map<std::pair<std::string, long long>, SessionRec> pending_sessions_;
  std::set<std::string> known_;
  std::vector<AppMeta> new_names_;
  struct ResAgg {
    long long cpu_ms = 0;
    long long ram_sum_kb = 0;
    long long ram_n = 0;
    long long peak_kb = 0;
    long long io_read = 0;
    long long io_write = 0;
  };
  MetricsConfig metrics_;
  ProcTracker proc_tracker_;
  std::map<std::pair<int, std::string>, ResAgg> pending_res_;
  std::vector<SysEntry> pending_sys_;
  Duration proc_every_{10000};
  Duration sys_every_{600000};
  TimePoint last_proc_{};
  TimePoint last_sys_{};
  bool proc_started_ = false;
  bool sys_started_ = false;
  TimePoint last_flush_{};
  bool flush_started_ = false;
};

}
