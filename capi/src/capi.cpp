#include "tw/capi.h"
#include <algorithm>
#include <cstdio>
#include <memory>
#include <sstream>
#include <string>
#include <vector>
#include "tw/engine.hpp"

struct tw_engine {
  std::shared_ptr<tw::PushProbe> probe;
  std::unique_ptr<tw::Engine> engine;
  std::vector<tw::AppSample> pending;
};

namespace {

void json_string(std::ostringstream& o, const std::string& s) {
  o << '"';
  for (unsigned char c : s) {
    switch (c) {
      case '"': o << "\\\""; break;
      case '\\': o << "\\\\"; break;
      case '\n': o << "\\n"; break;
      case '\r': o << "\\r"; break;
      case '\t': o << "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof buf, "\\u%04x", c);
          o << buf;
        } else {
          o << static_cast<char>(c);
        }
    }
  }
  o << '"';
}

}

extern "C" {

tw_engine* tw_create(int64_t max_gap_ms) {
  auto* e = new tw_engine();
  e->probe = std::make_shared<tw::PushProbe>();
  e->engine = std::make_unique<tw::Engine>(e->probe, tw::Duration(max_gap_ms > 0 ? max_gap_ms : 5000));
  return e;
}

void tw_destroy(tw_engine* e) {
  delete e;
}

void tw_add_sample(tw_engine* e, const char* app, int state) {
  if (!e || !app || state < 0 || state >= tw::kStateCount) return;
  e->pending.push_back({app, static_cast<tw::State>(state)});
}

void tw_step(tw_engine* e, int64_t now_ms) {
  if (!e) return;
  e->probe->push(std::move(e->pending));
  e->pending.clear();
  e->engine->step(tw::TimePoint(std::chrono::duration_cast<tw::Clock::duration>(tw::Duration(now_ms))));
}

int tw_report_json(tw_engine* e, char* buf, int cap) {
  if (!e) return 0;
  tw::Report r = e->engine->report();
  std::ostringstream o;
  o << "{\"uptime_ms\":" << r.uptime.count() << ",\"apps\":[";
  for (std::size_t i = 0; i < r.rows.size(); ++i) {
    const tw::AppRow& row = r.rows[i];
    if (i) o << ',';
    o << "{\"app\":";
    json_string(o, row.app);
    o << ",\"running\":" << (row.running ? "true" : "false")
      << ",\"state\":\"" << tw::state_name(row.state) << "\""
      << ",\"focused_ms\":" << row.spent[0].count()
      << ",\"open_ms\":" << row.spent[1].count()
      << ",\"minimized_ms\":" << row.spent[2].count()
      << ",\"background_ms\":" << row.spent[3].count()
      << ",\"total_ms\":" << row.total().count() << "}";
  }
  o << "]}";
  const std::string s = o.str();
  if (buf && cap > 0) {
    std::size_t n = std::min(s.size(), static_cast<std::size_t>(cap - 1));
    std::copy(s.begin(), s.begin() + static_cast<std::ptrdiff_t>(n), buf);
    buf[n] = '\0';
  }
  return static_cast<int>(s.size());
}

}
