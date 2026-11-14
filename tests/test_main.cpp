#include <cstdio>
#include <cstring>
#include <sstream>
#include <string>
#include "tw/capi.h"
#include "tw/console_sink.hpp"
#include "tw/engine.hpp"
#include "tw/filter.hpp"
#include <cstdio>
#include <map>
#include <memory>
#include <thread>
#include "tw/i18n.hpp"
#include "tw/ipc.hpp"
#include "tw/platform.hpp"
#include "tw/localapi.hpp"
#include "tw/rpc.hpp"
#include "tw/serialize.hpp"
#include "tw/sqlite_store.hpp"

namespace {

int failures = 0;

#define CHECK(...)                                                        \
  do {                                                                     \
    if (!(__VA_ARGS__)) {                                                         \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #__VA_ARGS__);          \
      ++failures;                                                          \
    }                                                                      \
  } while (0)

using tw::AppSample;
using tw::Duration;
using tw::State;

tw::TimePoint at(long long ms) {
  return tw::TimePoint(std::chrono::duration_cast<tw::Clock::duration>(Duration(ms)));
}

const tw::AppRow* find(const tw::Report& r, const std::string& app) {
  for (const auto& row : r.rows) {
    if (row.app == app) return &row;
  }
  return nullptr;
}

struct RecordingSink : tw::ISink {
  int calls = 0;
  void render(const tw::Report&) override { ++calls; }
};

void test_accumulates_per_state() {
  tw::Tracker t;
  t.tick({{"a.exe", State::Focused}}, at(0));
  t.tick({{"a.exe", State::Open}}, at(1000));
  t.tick({{"a.exe", State::Open}}, at(3000));
  auto r = t.report();
  auto* a = find(r, "a.exe");
  CHECK(a != nullptr);
  CHECK(a->spent[0] == Duration(1000));
  CHECK(a->spent[1] == Duration(2000));
  CHECK(a->total() == Duration(3000));
  CHECK(r.uptime == Duration(3000));
}

void test_gap_is_ignored() {
  tw::Tracker t(Duration(2000));
  t.tick({{"a.exe", State::Focused}}, at(0));
  t.tick({{"a.exe", State::Focused}}, at(60000));
  t.tick({{"a.exe", State::Focused}}, at(61000));
  auto rep_a = t.report();
  auto* a = find(rep_a, "a.exe");
  CHECK(a != nullptr);
  CHECK(a->total() == Duration(1000));
}

void test_duplicate_samples_pick_best_state() {
  tw::Tracker t;
  t.tick({{"a.exe", State::Background}, {"a.exe", State::Minimized}, {"a.exe", State::Focused}}, at(0));
  t.tick({{"a.exe", State::Background}}, at(1000));
  auto rep_a = t.report();
  auto* a = find(rep_a, "a.exe");
  CHECK(a != nullptr);
  CHECK(a->spent[static_cast<int>(State::Focused)] == Duration(1000));
}

void test_disappearing_app_stops_accumulating() {
  tw::Tracker t;
  t.tick({{"a.exe", State::Open}, {"b.exe", State::Open}}, at(0));
  t.tick({{"a.exe", State::Open}}, at(1000));
  t.tick({{"a.exe", State::Open}}, at(2000));
  auto r = t.report();
  auto* a = find(r, "a.exe");
  auto* b = find(r, "b.exe");
  CHECK(a != nullptr && b != nullptr);
  CHECK(a->running && !b->running);
  CHECK(a->total() == Duration(2000));
  CHECK(b->total() == Duration(1000));
  CHECK(r.rows.front().app == "a.exe");
}

void test_engine_with_push_probe() {
  auto probe = std::make_shared<tw::PushProbe>();
  tw::Engine e(probe);
  auto sink = std::make_shared<RecordingSink>();
  e.add_sink(sink);
  probe->push({{"x", State::Focused}});
  e.step(at(0));
  probe->push({{"x", State::Minimized}});
  e.step(at(500));
  CHECK(sink->calls == 2);
  auto rep_x = e.report();
  auto* x = find(rep_x, "x");
  CHECK(x != nullptr);
  CHECK(x->spent[static_cast<int>(State::Focused)] == Duration(500));
}

void test_format_duration() {
  CHECK(tw::format_duration(Duration(0)) == "-");
  CHECK(tw::format_duration(Duration(400)) == "<1s");
  CHECK(tw::format_duration(Duration(12000)) == "12s");
  CHECK(tw::format_duration(Duration(65000)) == "1m05s");
  CHECK(tw::format_duration(Duration(3723000)) == "1h02m03s");
}

void test_console_sink_plain() {
  tw::Tracker t;
  t.tick({{"chrome.exe", State::Focused}, {"Русское имя.exe", State::Background}}, at(0));
  t.tick({{"chrome.exe", State::Focused}, {"Русское имя.exe", State::Background}}, at(2000));
  std::ostringstream out;
  tw::ConsoleOptions o;
  o.color = false;
  o.live = false;
  tw::ConsoleSink sink(out, o);
  sink.render(t.report());
  std::string s = out.str();
  CHECK(s.find("chrome.exe") != std::string::npos);
  CHECK(s.find("Русское имя.exe") != std::string::npos);
  CHECK(s.find("2s") != std::string::npos);
  CHECK(s.find('\x1b') == std::string::npos);
}

void test_console_sink_truncates() {
  tw::Tracker t;
  t.tick({{"a-very-long-application-name-that-does-not-fit.exe", State::Open}}, at(0));
  std::ostringstream out;
  tw::ConsoleOptions o;
  o.color = false;
  o.live = false;
  tw::ConsoleSink sink(out, o);
  sink.render(t.report());
  CHECK(out.str().find("~") != std::string::npos);
}

void test_capi_roundtrip() {
  tw_engine* e = tw_create(5000);
  tw_add_sample(e, "quote\"app", 0);
  tw_step(e, 0);
  tw_add_sample(e, "quote\"app", 0);
  tw_step(e, 1500);
  int need = tw_report_json(e, nullptr, 0);
  CHECK(need > 0);
  std::string buf(static_cast<size_t>(need) + 1, '\0');
  int got = tw_report_json(e, &buf[0], static_cast<int>(buf.size()));
  CHECK(got == need);
  buf.resize(static_cast<size_t>(got));
  CHECK(buf.find("\"app\":\"quote\\\"app\"") != std::string::npos);
  CHECK(buf.find("\"focused_ms\":1500") != std::string::npos);
  char small[8];
  tw_report_json(e, small, sizeof small);
  CHECK(std::strlen(small) == 7);
  tw_destroy(e);
}

void test_sort_prefers_visible_time() {
  tw::Tracker t;
  t.tick({{"bg.exe", State::Background}, {"win.exe", State::Open}}, at(0));
  t.tick({{"bg.exe", State::Background}, {"win.exe", State::Open}}, at(1000));
  t.tick({{"bg.exe", State::Background}, {"win.exe", State::Background}}, at(2000));
  t.tick({{"bg.exe", State::Background}, {"win.exe", State::Background}}, at(10000));
  auto r = t.report();
  CHECK(r.rows.size() == 2);
  CHECK(r.rows.front().app == "win.exe");
}

void test_filter_hides_background_only_and_ignored() {
  tw::Tracker t;
  std::vector<AppSample> s = {{"real.exe", State::Open}, {"helper.exe", State::Background},
                              {"ApplicationFrameHost.exe", State::Open}, {"mine.exe", State::Focused}};
  t.tick(s, at(0));
  t.tick(s, at(1000));
  tw::FilterOptions fo;
  fo.ignore = tw::default_ignore();
  auto f = tw::apply_filter(t.report(), fo);
  CHECK(f.rows.size() == 2);
  CHECK(f.hidden == 2);
  CHECK(find(f, "helper.exe") == nullptr);
  CHECK(find(f, "ApplicationFrameHost.exe") == nullptr);
  fo.hide_background_only = false;
  auto g = tw::apply_filter(t.report(), fo);
  CHECK(g.rows.size() == 3);
  CHECK(g.hidden == 1);
}

void test_parse_ignore_list() {
  auto s = tw::parse_ignore_list(" A.exe, b.EXE ,,c.exe");
  CHECK(s.size() == 3);
  CHECK(s.count("a.exe") == 1);
  CHECK(s.count("b.exe") == 1);
  CHECK(tw::parse_ignore_list("").empty());
}

void test_native_probe_smoke() {
  auto p = tw::make_native_probe({});
  auto samples = p->sample();
  CHECK(!samples.empty());
  for (const auto& s : samples) CHECK(!s.app.empty());
}

}

struct FakeStore : tw::IStore {
  std::map<std::string, std::map<std::pair<std::string, int>, long long>> data;
  int adds = 0;
  std::map<std::pair<int, std::string>, long long> slots;
  std::map<std::pair<std::string, long long>, tw::SessionRec> sessions;
  bool add_sessions(const std::vector<tw::SessionRec>& v) override {
    for (const auto& r : v) sessions[{r.app, r.start}] = r;
    return true;
  }
  bool add_timeline(const std::string&, const std::vector<tw::SlotEntry>& v) override {
    for (const auto& e : v) slots[{e.slot, e.app}] += e.ms;
    return true;
  }
  bool add(const std::string& day, const std::vector<tw::Interval>& v) override {
    ++adds;
    for (const auto& iv : v) data[day][{iv.app, static_cast<int>(iv.state)}] += iv.ms.count();
    return true;
  }
  std::vector<tw::Interval> load_day(const std::string& day) override {
    std::vector<tw::Interval> out;
    for (const auto& kv : data[day]) out.push_back({kv.first.first, static_cast<State>(kv.first.second), Duration(kv.second)});
    return out;
  }
  std::vector<std::string> days(int) override {
    std::vector<std::string> out;
    for (const auto& kv : data) out.push_back(kv.first);
    return out;
  }
};

void test_serialize_roundtrip() {
  tw::Report r;
  r.uptime = Duration(123456);
  r.hidden = 7;
  tw::AppRow row;
  row.app = "my app.exe";
  row.running = true;
  row.state = State::Open;
  row.spent = {Duration(1), Duration(2), Duration(3), Duration(4)};
  r.rows.push_back(row);
  tw::Report back;
  CHECK(tw::deserialize(tw::serialize(r), back));
  CHECK(back.uptime == r.uptime);
  CHECK(back.hidden == 7);
  CHECK(back.rows.size() == 1);
  CHECK(back.rows[0].app == "my app.exe");
  CHECK(back.rows[0].running);
  CHECK(back.rows[0].state == State::Open);
  CHECK(back.rows[0].spent[3] == Duration(4));
  tw::Report bad;
  CHECK(!tw::deserialize("garbage", bad));
}

void test_engine_store_flush_and_finish() {
  auto probe = std::make_shared<tw::PushProbe>();
  auto store = std::make_shared<FakeStore>();
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_store(store, Duration(10000));
  probe->push({{"a.exe", State::Focused}});
  e.step(at(0));
  e.step(at(4000));
  CHECK(store->adds == 0);
  e.step(at(10000));
  CHECK(store->adds == 1);
  CHECK(store->data["2026-01-01"][{"a.exe", 0}] == 10000);
  e.step(at(12000));
  e.finish();
  CHECK(store->data["2026-01-01"][{"a.exe", 0}] == 12000);
}

void test_engine_flush_on_focus_change() {
  auto probe = std::make_shared<tw::PushProbe>();
  auto store = std::make_shared<FakeStore>();
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_store(store, Duration(180000));
  probe->push({{"a.exe", State::Focused}, {"b.exe", State::Open}});
  e.step(at(0));
  e.step(at(2000));
  e.step(at(4000));
  CHECK(store->adds == 0);
  probe->push({{"a.exe", State::Open}, {"b.exe", State::Focused}});
  e.step(at(6000));
  CHECK(store->adds == 1);
  e.step(at(8000));
  CHECK(store->adds == 1);
}

void test_engine_timeline_slots() {
  auto probe = std::make_shared<tw::PushProbe>();
  auto store = std::make_shared<FakeStore>();
  int slot = 10;
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_slot_source([&] { return slot; });
  e.set_store(store, Duration(1000000));
  probe->push({{"a.exe", State::Focused}, {"bg.exe", State::Background}});
  e.step(at(0));
  e.step(at(3000));
  slot = 11;
  e.step(at(5000));
  e.finish();
  CHECK((store->slots[{10, "a.exe"}] == 3000));
  CHECK((store->slots[{11, "a.exe"}] == 2000));
  CHECK((store->slots.count({10, "bg.exe"}) == 0));
}

void test_engine_sessions() {
  auto probe = std::make_shared<tw::PushProbe>();
  auto store = std::make_shared<FakeStore>();
  long long wall = 1000;
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_wall_source([&] { return wall; });
  e.set_store(store, Duration(1000000));
  probe->push({{"a.exe", State::Focused}, {"bg.exe", State::Background}});
  e.step(at(0));
  wall = 1002;
  e.step(at(2000));
  wall = 1004;
  e.step(at(4000));
  wall = 1100;
  e.step(at(6000));
  e.finish();
  CHECK(store->sessions.size() == 2);
  auto first = store->sessions.begin()->second;
  CHECK(first.app == "a.exe" && first.start == 1000 && first.stop == 1004);
  auto second = store->sessions.rbegin()->second;
  CHECK(second.start == 1098 && second.stop == 1100);
  for (const auto& kv : store->sessions) CHECK(kv.second.app != "bg.exe");
}

void test_sqlite_sessions() {
  std::string err;
  auto store = tw::SqliteStore::open(":memory:", &err);
  CHECK(store != nullptr);
  if (!store) return;
  CHECK(store->add_sessions({{"a", 0, 100, 160}}));
  CHECK(store->add_sessions({{"a", 0, 100, 200}}));
  auto got = store->load_sessions(0, 1000);
  CHECK(got.size() == 1 && got[0].stop == 200);
}

void test_engine_seeds_from_store() {
  auto probe = std::make_shared<tw::PushProbe>();
  auto store = std::make_shared<FakeStore>();
  store->data["2026-01-01"][{"a.exe", 0}] = 5000;
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_store(store);
  auto rep_a = e.report();
  auto* a = find(rep_a, "a.exe");
  CHECK(a != nullptr);
  CHECK(a && a->spent[0] == Duration(5000));
}

void test_engine_day_rollover() {
  auto probe = std::make_shared<tw::PushProbe>();
  auto store = std::make_shared<FakeStore>();
  std::string day = "2026-01-01";
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([&] { return day; });
  e.set_store(store, Duration(1000000));
  probe->push({{"a.exe", State::Focused}});
  e.step(at(0));
  e.step(at(3000));
  day = "2026-01-02";
  e.step(at(4000));
  CHECK(store->data["2026-01-01"][{"a.exe", 0}] == 3000);
  auto rep_a = e.report();
  auto* a = find(rep_a, "a.exe");
  CHECK(a == nullptr || a->total() <= Duration(1000));
  e.finish();
  CHECK(store->data["2026-01-02"][{"a.exe", 0}] <= 1000);
}

void test_sqlite_store() {
  std::string path = "tw_test_store.db";
  for (const char* ext : {"", "-wal", "-shm"}) std::remove((path + ext).c_str());
  {
    std::string err;
    auto s = tw::SqliteStore::open(path, &err);
    CHECK(s != nullptr);
    if (!s) return;
    CHECK(s->add("2026-01-01", {{"a.exe", State::Focused, Duration(1000)}, {"b.exe", State::Open, Duration(500)}}));
    CHECK(s->add("2026-01-01", {{"a.exe", State::Focused, Duration(2000)}}));
    CHECK(s->add("2026-01-02", {{"c.exe", State::Minimized, Duration(7)}}));
    auto rows = s->load_day("2026-01-01");
    CHECK(rows.size() == 2);
    long long a = 0;
    for (const auto& iv : rows) {
      if (iv.app == "a.exe") a = iv.ms.count();
    }
    CHECK(a == 3000);
    auto days = s->days(10);
    CHECK(days.size() == 2);
    CHECK(!days.empty() && days[0] == "2026-01-02");
    CHECK(s->days(1).size() == 1);
    CHECK(s->load_day("1999-01-01").empty());
  }
  {
    auto s = tw::SqliteStore::open(path, nullptr);
    CHECK(s != nullptr);
    if (s) CHECK(s->load_day("2026-01-02").size() == 1);
  }
  for (const char* ext : {"", "-wal", "-shm"}) std::remove((path + ext).c_str());
  std::string err;
  CHECK(tw::SqliteStore::open("/nonexistent_dir_xyz/a/b.db", &err) == nullptr);
  CHECK(!err.empty());
}

#ifdef _WIN32
void test_ipc_roundtrip() {
  std::string name = tw::default_pipe_name() + ".test";
  tw::ReportServer server;
  CHECK(server.start(name));
  server.publish("hello");
  tw::ReportClient client;
  CHECK(client.connect(name, 3000));
  std::string got;
  CHECK(client.read(got, 3000) == tw::ReadResult::Ok);
  CHECK(got == "hello");
  server.publish("second");
  CHECK(client.read(got, 3000) == tw::ReadResult::Ok);
  CHECK(got == "second");
  CHECK(client.read(got, 100) == tw::ReadResult::Timeout);
  server.stop();
  CHECK(client.read(got, 3000) == tw::ReadResult::Closed);
}
#endif


void test_i18n_complete() {
  CHECK(tw::i18n::count() >= 2);
  for (int i = 0; i < tw::i18n::count(); ++i) {
    tw::i18n::set(i);
    for (int k = 0; k < tw::i18n::kKeyCount; ++k) {
      const wchar_t* text = tw::i18n::tr(static_cast<tw::i18n::Key>(k));
      CHECK(text != nullptr && text[0] != L'\0');
    }
  }
  CHECK(tw::i18n::find("ru") >= 0);
  CHECK(tw::i18n::find("xx") < 0);
  CHECK(tw::i18n::from_langid(0x19) == tw::i18n::find("ru"));
  CHECK(tw::i18n::from_langid(0x09) == tw::i18n::find("en"));
  tw::i18n::set(0);
}

std::string rpc_frame(std::uint32_t op, const std::string& json) {
  std::string f(8, '\0');
  for (int i = 0; i < 4; ++i) {
    f[i] = static_cast<char>((op >> (8 * i)) & 0xFF);
    f[4 + i] = static_cast<char>((json.size() >> (8 * i)) & 0xFF);
  }
  return f + json;
}

void test_rpc_parser() {
  std::string hs = rpc_frame(0, "{\"v\":1,\"client_id\":\"123\"}");
  std::string act = rpc_frame(1, "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":5,\"activity\":{\"details\":\"Song \\\"X\\\"\",\"state\":\"by Y\",\"timestamps\":{\"start\":1700000000}}}}");
  std::string all = hs + act;
  tw::RpcFrameParser parser;
  auto a = parser.feed(all.data(), 10);
  CHECK(a.empty());
  auto b = parser.feed(all.data() + 10, all.size() - 10);
  CHECK(b.size() == 2);
  std::string id;
  CHECK(tw::extract_client_id(b[0], id) && id == "123");
  tw::Presence p;
  CHECK(tw::extract_presence(b[1], p));
  CHECK(p.details == "Song \"X\"");
  CHECK(p.state == "by Y");
  CHECK(p.started == 1700000000);
  CHECK(p.raw.find("\"state\":\"by Y\"") != std::string::npos);
  CHECK(p.raw.front() == '{' && p.raw.back() == '}');
  tw::RpcFrame other{1, "{\"cmd\":\"SUBSCRIBE\"}"};
  CHECK(!tw::extract_presence(other, p));
}

void test_local_api() {
  std::string path;
  CHECK(tw::parse_api_request("GET /v1/current HTTP/1.1\r\nHost: 127.0.0.1:9095\r\n\r\n", 9095, path));
  CHECK(path == "/v1/current");
  CHECK(!tw::parse_api_request("GET /v1/current HTTP/1.1\r\nHost: evil.com:9095\r\n\r\n", 9095, path));
  CHECK(!tw::parse_api_request("POST /v1/current HTTP/1.1\r\nHost: 127.0.0.1:9095\r\n\r\n", 9095, path));
  tw::Report r;
  tw::AppRow row;
  row.app = "a\"b";
  r.rows.push_back(row);
  std::string j = tw::current_json(r);
  CHECK(j.find("\"app\":\"a\\\"b\"") != std::string::npos);
  CHECK(tw::http_response(200, j).find("Content-Length: " + std::to_string(j.size())) != std::string::npos);
}

void test_presence_store() {
  std::string err;
  auto store = tw::SqliteStore::open(":memory:", &err);
  CHECK(store != nullptr);
  if (!store) return;
  tw::Presence p{"1", "Game", "d", "s", 5, "{\"a\":1}"};
  CHECK(store->add_presence(100, {p}));
  auto got = store->load_presence(0, 200);
  CHECK(got.size() == 1 && got[0].name == "Game" && got[0].started == 5 && got[0].raw == "{\"a\":1}");
}

int main() {
  test_accumulates_per_state();
  test_gap_is_ignored();
  test_duplicate_samples_pick_best_state();
  test_disappearing_app_stops_accumulating();
  test_engine_with_push_probe();
  test_format_duration();
  test_console_sink_plain();
  test_console_sink_truncates();
  test_capi_roundtrip();
  test_sort_prefers_visible_time();
  test_filter_hides_background_only_and_ignored();
  test_parse_ignore_list();
  test_native_probe_smoke();
  test_i18n_complete();
  test_serialize_roundtrip();
  test_engine_store_flush_and_finish();
  test_engine_flush_on_focus_change();
  test_engine_timeline_slots();
  test_engine_sessions();
  test_sqlite_sessions();
  test_engine_seeds_from_store();
  test_engine_day_rollover();
  test_sqlite_store();
  test_rpc_parser();
  test_local_api();
  test_presence_store();
#ifdef _WIN32
  test_ipc_roundtrip();
#endif
  if (failures == 0) std::printf("all tests passed\n");
  return failures == 0 ? 0 : 1;
}
