#pragma once
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>
#include "tw/probe.hpp"
#include "tw/sink.hpp"
#include "tw/store.hpp"
#include "tw/tracker.hpp"

namespace tw {

std::string local_day_now();

class Engine {
public:
  explicit Engine(std::shared_ptr<IProbe> probe, Duration max_gap = Duration(5000));

  void add_sink(std::shared_ptr<ISink> sink);
  void set_day_source(std::function<std::string()> day);
  void set_store(std::shared_ptr<IStore> store, Duration flush_every = Duration(10000));
  void step(TimePoint now);
  void run(Duration interval, const std::function<bool()>& stop);
  void finish();
  Report report() const;

private:
  void flush_pending();

  std::shared_ptr<IProbe> probe_;
  std::vector<std::shared_ptr<ISink>> sinks_;
  Duration max_gap_;
  Tracker tracker_;
  std::shared_ptr<IStore> store_;
  std::function<std::string()> day_fn_;
  std::string day_;
  std::map<std::pair<std::string, int>, Duration> pending_;
  Duration flush_every_{10000};
  TimePoint last_flush_{};
  bool flush_started_ = false;
};

}
