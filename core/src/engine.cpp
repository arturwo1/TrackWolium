#include <set>
#include "tw/engine.hpp"
#include <algorithm>
#include <ctime>
#include <thread>

namespace tw {

std::string local_day_now() {
  std::time_t t = std::time(nullptr);
  std::tm tm{};
#ifdef _WIN32
  localtime_s(&tm, &t);
#else
  localtime_r(&t, &tm);
#endif
  char buf[16];
  std::strftime(buf, sizeof buf, "%Y-%m-%d", &tm);
  return buf;
}

int local_slot_now() {
  std::time_t t = std::time(nullptr);
  std::tm tm{};
#ifdef _WIN32
  localtime_s(&tm, &t);
#else
  localtime_r(&t, &tm);
#endif
  return (tm.tm_hour * 60 + tm.tm_min) / 5;
}

Engine::Engine(std::shared_ptr<IProbe> probe, Duration max_gap)
    : probe_(std::move(probe)), max_gap_(max_gap), tracker_(max_gap), day_fn_(local_day_now), slot_fn_(local_slot_now), wall_fn_([] { return static_cast<long long>(std::time(nullptr)); }) {}

void Engine::set_slot_source(std::function<int()> slot) {
  slot_fn_ = std::move(slot);
}

void Engine::set_wall_source(std::function<long long()> wall) {
  wall_fn_ = std::move(wall);
}

void Engine::set_metrics(const MetricsConfig& cfg) {
  if (cfg == metrics_) return;
  bool had_proc = metrics_.any_proc();
  bool had_sys = metrics_.any_sys();
  metrics_ = cfg;
  if (!cfg.any_proc() || !had_proc) {
    proc_tracker_.reset();
    proc_started_ = false;
  }
  if (!cfg.any_sys() || !had_sys) sys_started_ = false;
}

void Engine::set_metrics_intervals(Duration proc, Duration sys) {
  proc_every_ = proc;
  sys_every_ = sys;
}

void Engine::add_sink(std::shared_ptr<ISink> sink) {
  sinks_.push_back(std::move(sink));
}

void Engine::set_day_source(std::function<std::string()> day) {
  day_fn_ = std::move(day);
}

void Engine::set_store(std::shared_ptr<IStore> store, Duration flush_every) {
  store_ = std::move(store);
  flush_every_ = flush_every;
  if (store_) {
    day_ = day_fn_();
    tracker_.seed(store_->load_day(day_));
  }
}

void Engine::flush_pending() {
  if (!store_) return;
  if (!pending_res_.empty()) {
    std::vector<ResEntry> rows;
    rows.reserve(pending_res_.size());
    for (const auto& kv : pending_res_) {
      const ResAgg& a = kv.second;
      if (a.cpu_ms == 0 && a.ram_n == 0 && a.peak_kb == 0 && a.io_read == 0 && a.io_write == 0) continue;
      rows.push_back({kv.first.first, kv.first.second, a.cpu_ms, a.ram_sum_kb, a.ram_n, a.peak_kb, a.io_read, a.io_write});
    }
    if (rows.empty() || store_->add_resources(day_, rows)) pending_res_.clear();
  }
  if (!pending_sys_.empty() && store_->add_system(pending_sys_)) pending_sys_.clear();
  if (!pending_sessions_.empty()) {
    std::vector<SessionRec> recs;
    recs.reserve(pending_sessions_.size());
    for (const auto& kv : pending_sessions_) recs.push_back(kv.second);
    if (store_->add_sessions(recs)) pending_sessions_.clear();
  }
  if (pending_.empty()) {
    if (!new_names_.empty() && store_->set_names(new_names_)) new_names_.clear();
    return;
  }
  std::vector<Interval> batch;
  batch.reserve(pending_.size());
  for (const auto& kv : pending_) {
    batch.push_back({kv.first.first, static_cast<State>(kv.first.second), kv.second});
  }
  if (!new_names_.empty() && store_->set_names(new_names_)) new_names_.clear();
  if (!pending_slots_.empty()) {
    std::vector<SlotEntry> slots;
    slots.reserve(pending_slots_.size());
    for (const auto& kv : pending_slots_) slots.push_back({std::get<0>(kv.first), std::get<1>(kv.first), std::get<2>(kv.first), kv.second});
    if (store_->add_timeline(day_, slots)) pending_slots_.clear();
  }
  if (store_->add(day_, batch)) pending_.clear();
}

void Engine::note_session(const Interval& iv) {
  long long wall = wall_fn_();
  long long secs = (iv.ms.count() + 999) / 1000;
  if (secs < 1) secs = 1;
  long long gap = std::max<long long>(15, (max_gap_.count() + 999) / 1000);
  auto it = open_.find(iv.app);
  int st = static_cast<int>(iv.state);
  if (it != open_.end() && it->second.state == st && wall - it->second.stop <= gap) {
    it->second.stop = std::max(wall, it->second.stop + 1);
  } else {
    OpenSession o;
    o.state = st;
    o.start = wall - secs;
    o.stop = wall;
    if (it != open_.end() && o.start < it->second.stop) o.start = it->second.stop;
    if (o.stop <= o.start) o.stop = o.start + 1;
    open_[iv.app] = o;
    it = open_.find(iv.app);
  }
  pending_sessions_[{iv.app, it->second.start}] = {iv.app, it->second.state, it->second.start, it->second.stop};
}

void Engine::sample_metrics(TimePoint now, const std::vector<AppSample>& samples) {
  if (metrics_.any_proc() && probe_->supports_metrics() && (!proc_started_ || now - last_proc_ >= proc_every_)) {
    proc_started_ = true;
    last_proc_ = now;
    auto res = proc_tracker_.update(probe_->proc_snapshot());
    int slot = slot_fn_();
    std::set<std::string> visible;
    for (const auto& sm : samples) {
      if (sm.state != State::Background) visible.insert(sm.app);
    }
    for (const auto& kv : res) {
      if (!visible.count(kv.first)) continue;
      const AppRes& r = kv.second;
      ResAgg& a = pending_res_[{slot, kv.first}];
      if (metrics_.cpu) a.cpu_ms += r.cpu_ms;
      if (metrics_.ram && r.rss_kb > 0) {
        a.ram_sum_kb += r.rss_kb;
        ++a.ram_n;
      }
      if (metrics_.peak) a.peak_kb = std::max(a.peak_kb, r.peak_kb);
      if (metrics_.io_read) a.io_read += r.io_read;
      if (metrics_.io_write) a.io_write += r.io_write;
    }
  }
  if (metrics_.any_sys() && probe_->supports_metrics() && (!sys_started_ || now - last_sys_ >= sys_every_)) {
    sys_started_ = true;
    last_sys_ = now;
    SysStat st = probe_->sys_stat();
    long long ts = wall_fn_();
    if (st.valid) {
      if (metrics_.sys_ram) pending_sys_.push_back({ts, "ram", st.ram_total_kb, st.ram_avail_kb});
      if (metrics_.sys_disk) {
        for (const auto& d : st.disks) pending_sys_.push_back({ts, "disk:" + d.mount, d.total_kb, d.free_kb});
      }
    }
  }
}

void Engine::step(TimePoint now) {
  if (store_) {
    std::string day = day_fn_();
    if (day != day_) {
      flush_pending();
      tracker_ = Tracker(max_gap_);
      day_ = day;
      tracker_.seed(store_->load_day(day_));
    }
  }

  auto samples = probe_->sample();
  std::string focus;
  for (const auto& sm : samples) {
    if (sm.state == State::Focused) {
      focus = sm.app;
      break;
    }
  }
  if (store_) {
    for (const auto& sm : samples) {
      if (known_.insert(sm.app).second) {
        std::string n = probe_->display_name(sm.app);
        std::string path = probe_->exe_path(sm.app);
        if (!n.empty() || !path.empty()) new_names_.push_back({sm.app, n, path});
      }
    }
  }
  auto intervals = tracker_.tick(samples, now);

  if (store_) {
    for (const auto& iv : intervals) {
      pending_[{iv.app, static_cast<int>(iv.state)}] += iv.ms;
      if (iv.state != State::Background) note_session(iv);
      if (iv.state != State::Background) pending_slots_[{slot_fn_(), iv.app, static_cast<int>(iv.state)}] += iv.ms.count();
    }
    if (metrics_.any()) sample_metrics(now, samples);
    bool focus_changed = flush_started_ && focus != last_focus_;
    last_focus_ = focus;
    if (!flush_started_) {
      last_flush_ = now;
      flush_started_ = true;
    } else if (focus_changed || now - last_flush_ >= flush_every_) {
      flush_pending();
      last_flush_ = now;
    }
  }

  if (sinks_.empty()) return;
  Report r = tracker_.report();
  for (auto& s : sinks_) s->render(r);
}

void Engine::run(Duration interval, const std::function<bool()>& stop) {
  auto next = Clock::now();
  while (!stop()) {
    step(Clock::now());
    next += interval;
    if (Clock::now() > next + interval) next = Clock::now();
    while (!stop() && Clock::now() < next) {
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
  }
}

void Engine::finish() {
  flush_pending();
}

void Engine::flush() {
  flush_pending();
  last_flush_ = Clock::now();
}

Report Engine::report() const {
  return tracker_.report();
}

}
