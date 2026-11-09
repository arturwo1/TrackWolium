#include "tw/engine.hpp"
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
    : probe_(std::move(probe)), max_gap_(max_gap), tracker_(max_gap), day_fn_(local_day_now), slot_fn_(local_slot_now) {}

void Engine::set_slot_source(std::function<int()> slot) {
  slot_fn_ = std::move(slot);
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
        if (!n.empty()) new_names_.emplace_back(sm.app, n);
      }
    }
  }
  auto intervals = tracker_.tick(samples, now);

  if (store_) {
    for (const auto& iv : intervals) {
      pending_[{iv.app, static_cast<int>(iv.state)}] += iv.ms;
      if (iv.state != State::Background) pending_slots_[{slot_fn_(), iv.app, static_cast<int>(iv.state)}] += iv.ms.count();
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
