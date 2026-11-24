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

Duration parse_afk_threshold(const std::string& text) {
  long long seconds = 300;
  std::size_t a = text.find_first_not_of(" \t\r\n");
  if (a != std::string::npos) {
    std::size_t b = text.find_last_not_of(" \t\r\n");
    std::string t = text.substr(a, b - a + 1);
    bool digits = !t.empty() && t.size() <= 6;
    for (char c : t) {
      if (c < '0' || c > '9') digits = false;
    }
    if (digits) seconds = std::stoll(t);
  }
  if (seconds == 0) return Duration(0);
  seconds = std::max<long long>(30, std::min<long long>(3600, seconds));
  return Duration(seconds * 1000);
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

void Engine::set_afk_threshold(Duration threshold) {
  afk_threshold_ = threshold;
}

void Engine::set_limits(std::vector<Limit> limits) {
  limits_ = std::move(limits);
}

void Engine::set_limit_notifier(std::function<void(const Limit&, long long)> notify) {
  limit_notify_ = std::move(notify);
}

void Engine::check_limits(TimePoint now) {
  if (limits_.empty() || !limit_notify_) return;
  if (limit_checked_ && now - last_limit_check_ < Duration(5000)) return;
  limit_checked_ = true;
  last_limit_check_ = now;
  std::string day = day_fn_();
  if (day != limits_day_) {
    limits_day_ = day;
    limits_fired_.clear();
  }
  Report r = tracker_.report();
  for (const auto& lim : limits_) {
    std::string key = std::to_string(lim.seconds) + "|" + lim.label;
    if (limits_fired_.count(key)) continue;
    long long spent = 0;
    for (const auto& row : r.rows) {
      if (lim.apps.count(row.app)) spent += row.spent[0].count();
    }
    if (spent >= lim.seconds * 1000) {
      limits_fired_.insert(key);
      limit_notify_(lim, spent);
    }
  }
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
  if (!pending_sys_events_.empty() && store_->add_sys_events(pending_sys_events_)) pending_sys_events_.clear();
  if (!pending_afk_.empty()) {
    std::vector<SlotEntry> rows;
    rows.reserve(pending_afk_.size());
    for (const auto& kv : pending_afk_) rows.push_back({kv.first.first, kv.first.second, 0, kv.second});
    if (store_->add_afk(day_, rows)) pending_afk_.clear();
  }
  if (!pending_app_stats_.empty()) {
    std::vector<AppStatEntry> rows;
    rows.reserve(pending_app_stats_.size());
    for (const auto& kv : pending_app_stats_) rows.push_back({kv.first.first, kv.first.second, kv.second});
    if (store_->add_app_stats(day_, rows)) pending_app_stats_.clear();
  }
  if (!pending_slot_stats_.empty()) {
    std::vector<SlotStatEntry> rows;
    rows.reserve(pending_slot_stats_.size());
    for (const auto& kv : pending_slot_stats_) rows.push_back({std::get<0>(kv.first), std::get<1>(kv.first), std::get<2>(kv.first), kv.second});
    if (store_->add_slot_stats(day_, rows)) pending_slot_stats_.clear();
  }
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
  SysStat cached_sys;
  bool have_sys = false;
  if (metrics_.any_sys() && probe_->supports_metrics() && (!sys_started_ || now - last_sys_ >= sys_every_)) {
    sys_started_ = true;
    last_sys_ = now;
    cached_sys = probe_->sys_stat();
    have_sys = true;
    long long ts = wall_fn_();
    if (cached_sys.valid) {
      if (metrics_.sys_ram && cached_sys.ram_total_kb > 0) pending_sys_.push_back({ts, "ram", cached_sys.ram_total_kb, cached_sys.ram_avail_kb});
      if (metrics_.sys_disk) {
        for (const auto& d : cached_sys.disks) pending_sys_.push_back({ts, "disk:" + d.mount, d.total_kb, d.free_kb});
      }
    }
  }
  sample_battery(now, have_sys ? &cached_sys : nullptr);
}

void Engine::sample_battery(TimePoint now, const SysStat* cached_sys) {
  if (metrics_.no_time || !probe_->supports_metrics()) return;
  if (!cached_sys && bat_started_ && now - last_bat_ < Duration(60000)) return;
  bat_started_ = true;
  last_bat_ = now;
  BatteryStat st;
  if (cached_sys) {
    st.pct = cached_sys->battery_pct;
    st.charging = cached_sys->battery_charging;
    st.valid = cached_sys->valid && st.pct >= 0 && st.pct <= 100;
  } else {
    st = probe_->battery_stat();
  }
  if (!st.valid || st.pct < 0 || st.pct > 100) return;

  long long ts = wall_fn_();
  bool changed = last_bat_pct_ < 0 || st.pct != last_bat_pct_ || st.charging != last_bat_charging_;
  if (changed || ts - last_bat_sys_ts_ >= 300) {
    pending_sys_.push_back({ts, "battery", st.pct, st.charging});
    last_bat_sys_ts_ = ts;
  }

  if (last_bat_pct_ >= 0 && last_bat_charging_ == 0 && st.charging == 0 &&
      st.pct < last_bat_pct_ && last_bat_wall_ > 0 && ts - last_bat_wall_ <= 600) {
    long long drop_tenths = static_cast<long long>(last_bat_pct_ - st.pct) * 10LL;
    auto distribute_apps = [&](long long drop) {
      long long total_w = 0;
      for (const auto& kv : bat_app_ms_) total_w += kv.second;
      if (total_w <= 0 || drop <= 0) return;
      struct Share { std::string app; long long whole; long long rem; };
      std::vector<Share> shares;
      long long allocated = 0;
      for (const auto& kv : bat_app_ms_) {
        long long num = drop * kv.second;
        long long w = num / total_w;
        shares.push_back({kv.first, w, num % total_w});
        allocated += w;
      }
      std::sort(shares.begin(), shares.end(), [](const Share& a, const Share& b) {
        return a.rem != b.rem ? a.rem > b.rem : a.app < b.app;
      });
      for (std::size_t i = 0; i < shares.size() && allocated < drop; ++i) {
        ++shares[i].whole;
        ++allocated;
      }
      for (const auto& s : shares) {
        if (s.whole > 0) pending_app_stats_[{s.app, "battery"}] += s.whole;
      }
    };
    auto distribute_slots = [&](long long drop) {
      long long total_w = 0;
      for (const auto& kv : bat_slot_ms_) total_w += kv.second;
      if (total_w <= 0 || drop <= 0) return;
      struct Share { int slot; std::string app; long long whole; long long rem; };
      std::vector<Share> shares;
      long long allocated = 0;
      for (const auto& kv : bat_slot_ms_) {
        long long num = drop * kv.second;
        long long w = num / total_w;
        shares.push_back({kv.first.first, kv.first.second, w, num % total_w});
        allocated += w;
      }
      std::sort(shares.begin(), shares.end(), [](const Share& a, const Share& b) {
        if (a.rem != b.rem) return a.rem > b.rem;
        if (a.slot != b.slot) return a.slot < b.slot;
        return a.app < b.app;
      });
      for (std::size_t i = 0; i < shares.size() && allocated < drop; ++i) {
        ++shares[i].whole;
        ++allocated;
      }
      for (const auto& s : shares) {
        if (s.whole > 0) pending_slot_stats_[{s.slot, s.app, "battery"}] += s.whole;
      }
    };
    distribute_apps(drop_tenths);
    distribute_slots(drop_tenths);
    bat_app_ms_.clear();
    bat_slot_ms_.clear();
  } else if (st.charging != 0 || last_bat_pct_ < 0 || st.pct > last_bat_pct_ ||
             (last_bat_wall_ > 0 && ts - last_bat_wall_ > 600)) {
    bat_app_ms_.clear();
    bat_slot_ms_.clear();
  }

  last_bat_pct_ = st.pct;
  last_bat_charging_ = st.charging;
  last_bat_wall_ = ts;
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
      if (metrics_.no_time) break;
      pending_[{iv.app, static_cast<int>(iv.state)}] += iv.ms;
      if (iv.state != State::Background) note_session(iv);
      if (iv.state != State::Background) pending_slots_[{slot_fn_(), iv.app, static_cast<int>(iv.state)}] += iv.ms.count();
      if (iv.state == State::Focused || iv.state == State::Open) {
        long long w = iv.ms.count() * (iv.state == State::Focused ? 3LL : 1LL);
        bat_app_ms_[iv.app] += w;
        bat_slot_ms_[{slot_fn_(), iv.app}] += w;
      }
    }
    if (afk_threshold_.count() > 0 && !metrics_.no_time && !intervals.empty()) {
      long long idle = probe_->idle_ms();
      if (idle >= afk_threshold_.count()) {
        for (const auto& iv : intervals) {
          if (iv.state == State::Focused) pending_afk_[{slot_fn_(), iv.app}] += iv.ms.count();
        }
      }
    }
    if (metrics_.any()) sample_metrics(now, samples);
    else sample_battery(now, nullptr);
    auto sevs = probe_->take_sys_events();
    if (!sevs.empty()) {
      pending_sys_events_.insert(pending_sys_events_.end(), sevs.begin(), sevs.end());
    }
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

  check_limits(now);

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

void Engine::record_sys_event(const SysEvent& ev) {
  if (ev.kind.empty() || ev.ts <= 0) return;
  pending_sys_events_.push_back(ev);
}

Report Engine::report() const {
  return tracker_.report();
}

}
