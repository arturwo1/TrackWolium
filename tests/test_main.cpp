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
#if defined(__linux__)
#include "dbus_bridge.hpp"
#endif
#if defined(__linux__)
#include "wayland_windows.hpp"
#endif

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

  struct Fake : tw::ApiData {
    std::vector<tw::UsageRow> usage(const std::string& a, const std::string& b) override {
      from = a;
      to = b;
      return {{b, "x.exe", "X", 0, 60000}, {b, "y.exe", "", 0, 120000}, {a, "x.exe", "X", 3, 5000}};
    }
    std::vector<tw::SessionRow> sessions(long long, long long, int) override { return {{"x.exe", "X", 0, 10, 20}}; }
    std::string from, to;
  } fake;
  long long now = 1700000000;
  auto top = tw::route_api("/v1/apps/top?days=2&limit=1", "", &fake, now);
  CHECK(top.status == 200);
  CHECK(top.body.find("\"app\":\"y.exe\"") != std::string::npos);
  CHECK(top.body.find("x.exe") == std::string::npos);
  CHECK(fake.to == tw::day_string(now));
  auto sum = tw::route_api("/v1/summary?days=7", "", &fake, now);
  CHECK(sum.body.find("\"apps_count\":2") != std::string::npos);
  CHECK(sum.body.find("\"background_ms\":5000") != std::string::npos);
  CHECK(tw::route_api("/v1/summary?days=abc", "", &fake, now).body.find("\"days\":7") != std::string::npos);
  CHECK(tw::route_api("/v1/sessions?hours=2", "", &fake, now).body.find("\"stop\":20") != std::string::npos);
  CHECK(tw::route_api("/v1/nope", "", &fake, now).status == 404);
  auto w = tw::route_api("/widget", "", nullptr, now);
  CHECK(w.type.find("text/html") == 0 && w.body.find("<html>") != std::string::npos);
  CHECK(tw::route_api("/v1/apps/top", "", nullptr, now).body.find("\"apps\":[]") != std::string::npos);
}

#if defined(__linux__)
void test_wayland_parsers() {
  const std::string clients =
      "[{\"address\":\"0xa\",\"mapped\":true,\"hidden\":false,\"pid\":10,\"class\":\"firefox\",\"initialClass\":\"firefox\"},"
      "{\"address\":\"0xb\",\"mapped\":true,\"hidden\":true,\"pid\":11,\"class\":\"kitty\"},"
      "{\"address\":\"0xc\",\"mapped\":false,\"pid\":12,\"class\":\"ghost\"}]";
  auto h = tw::parse_hyprland(clients, "{\"address\":\"0xa\"}");
  CHECK(h.size() == 2);
  CHECK(h[0].active && h[0].wm_class == "firefox" && h[0].pid == 10);
  CHECK(!h[1].active && h[1].hidden);
  const std::string tree =
      "{\"type\":\"root\",\"nodes\":[{\"type\":\"workspace\",\"name\":\"1\",\"nodes\":["
      "{\"type\":\"con\",\"pid\":20,\"app_id\":\"foot\",\"focused\":true,\"nodes\":[]},"
      "{\"type\":\"con\",\"pid\":21,\"app_id\":null,\"window_properties\":{\"class\":\"Steam\"},\"focused\":false,\"nodes\":[]}]},"
      "{\"type\":\"workspace\",\"name\":\"__i3_scratch\",\"floating_nodes\":[{\"type\":\"floating_con\",\"pid\":22,\"app_id\":\"mpv\",\"nodes\":[]}]}]}";
  auto sw = tw::parse_sway(tree);
  CHECK(sw.size() == 3);
  CHECK(sw[0].active && sw[0].wm_class == "foot");
  CHECK(sw[1].wm_class == "Steam" && !sw[1].hidden);
  CHECK(sw[2].hidden && sw[2].wm_class == "mpv");
  CHECK(tw::parse_hyprland("garbage", "").empty());
  auto br = tw::parse_bridge_report("{\"windows\":[{\"pid\":5,\"class\":\"org.gnome.Nautilus\",\"active\":true,\"minimized\":false},{\"pid\":6,\"class\":\"Steam\",\"minimized\":true}]}");
  CHECK(br.size() == 2);
  CHECK(br[0].active && br[0].wm_class == "org.gnome.Nautilus" && br[0].pid == 5);
  CHECK(br[1].hidden && !br[1].active);
  CHECK(tw::parse_bridge_report("nope").empty());
}
#endif

struct MetricsProbe : tw::PushProbe {
  std::vector<tw::ProcSnap> snaps;
  tw::SysStat sys;
  int proc_calls = 0;
  int sys_calls = 0;
  long long idle = -1;
  long long idle_ms() override { return idle; }
  bool supports_metrics() const override { return true; }
  std::vector<tw::ProcSnap> proc_snapshot() override {
    ++proc_calls;
    return snaps;
  }
  tw::SysStat sys_stat() override {
    ++sys_calls;
    return sys;
  }
};

struct ResStore : FakeStore {
  std::map<std::pair<int, std::string>, tw::ResEntry> res;
  std::vector<tw::SysEntry> sysrows;
  int res_calls = 0;
  std::map<std::pair<int, std::string>, long long> afk;
  bool add_afk(const std::string&, const std::vector<tw::SlotEntry>& v) override {
    for (const auto& e : v) afk[{e.slot, e.app}] += e.ms;
    return true;
  }
  bool add_resources(const std::string&, const std::vector<tw::ResEntry>& v) override {
    ++res_calls;
    for (const auto& e : v) {
      auto& r = res[{e.slot, e.app}];
      r.cpu_ms += e.cpu_ms;
      r.ram_sum_kb += e.ram_sum_kb;
      r.ram_n += e.ram_n;
      r.peak_kb = std::max(r.peak_kb, e.peak_kb);
      r.io_read += e.io_read;
      r.io_write += e.io_write;
    }
    return true;
  }
  bool add_system(const std::vector<tw::SysEntry>& v) override {
    for (const auto& e : v) sysrows.push_back(e);
    return true;
  }
};

tw::ProcSnap snap(long long pid, long long stamp, const char* app, long long cpu, long long rss, long long peak, long long ior, long long iow) {
  tw::ProcSnap p;
  p.pid = pid;
  p.stamp = stamp;
  p.app = app;
  p.cpu_ms = cpu;
  p.rss_kb = rss;
  p.peak_kb = peak;
  p.io_read = ior;
  p.io_write = iow;
  return p;
}

void test_metrics_config_parse() {
  auto c = tw::parse_metrics("cpu ram\nsysdisk bogus");
  CHECK(c.cpu && c.ram && c.sys_disk && !c.peak && !c.io_read && !c.io_write && !c.sys_ram);
  CHECK(c.any_proc() && c.any_sys() && c.any());
  CHECK(tw::parse_metrics(tw::format_metrics(c)) == c);
  CHECK(!tw::parse_metrics("").any());
}

void test_proc_tracker() {
  tw::ProcTracker t;
  auto first = t.update({snap(1, 10, "a", 1000, 500, 600, 100, 200), snap(2, 11, "a", 50, 100, 100, 0, 0)});
  CHECK(first["a"].cpu_ms == 0 && first["a"].io_read == 0 && first["a"].io_write == 0);
  CHECK(first["a"].rss_kb == 600);
  auto second = t.update({snap(1, 10, "a", 1300, 520, 600, 150, 260), snap(2, 11, "a", 80, 100, 100, 0, 0), snap(3, 99, "a", 40, 70, 90, 5, 6)});
  CHECK(second["a"].cpu_ms == 300 + 30 + 40);
  CHECK(second["a"].io_read == 50 + 0 + 5);
  CHECK(second["a"].io_write == 60 + 0 + 6);
  CHECK(second["a"].rss_kb == 520 + 100 + 70);
  CHECK(second["a"].peak_kb == 520 + 100 + 90);
  auto third = t.update({snap(1, 10, "a", 1400, 530, 900, 150, 260), snap(3, 100, "a", 10, 60, 60, 0, 0)});
  CHECK(third["a"].cpu_ms == 100 + 10);
  CHECK(third["a"].peak_kb == 900 + 60);
  t.reset();
  auto again = t.update({snap(1, 10, "a", 9999, 1, 1, 9, 9)});
  CHECK(again["a"].cpu_ms == 0);
}

void test_engine_metrics_buffer() {
  auto probe = std::make_shared<MetricsProbe>();
  auto store = std::make_shared<ResStore>();
  int slot = 5;
  long long wall = 1000;
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_slot_source([&] { return slot; });
  e.set_wall_source([&] { return wall; });
  e.set_store(store, Duration(1000000));
  e.set_metrics_intervals(Duration(10000), Duration(100000));
  probe->push({{"a", State::Focused}});
  probe->snaps = {snap(1, 1, "a", 0, 1000, 1000, 0, 0)};
  probe->sys.valid = true;
  probe->sys.ram_total_kb = 8000;
  probe->sys.ram_avail_kb = 3000;
  probe->sys.disks = {{"C:", 1000, 400}};
  e.step(at(0));
  CHECK(probe->proc_calls == 0 && probe->sys_calls == 0);
  tw::MetricsConfig cfg;
  e.set_metrics(cfg);
  e.step(at(1000));
  CHECK(probe->proc_calls == 0);
  cfg.cpu = true;
  cfg.ram = true;
  cfg.peak = true;
  cfg.io_read = true;
  e.set_metrics(cfg);
  e.step(at(2000));
  CHECK(probe->proc_calls == 1);
  e.step(at(5000));
  CHECK(probe->proc_calls == 1);
  probe->snaps = {snap(1, 1, "a", 400, 1200, 1500, 2048, 4096)};
  e.step(at(12000));
  CHECK(probe->proc_calls == 2);
  CHECK(store->res_calls == 0);
  slot = 6;
  probe->snaps = {snap(1, 1, "a", 700, 1400, 1500, 4096, 8192)};
  e.step(at(22000));
  CHECK(probe->sys_calls == 0);
  e.finish();
  CHECK(store->res_calls == 1);
  const auto& r5 = store->res[{5, "a"}];
  CHECK(r5.cpu_ms == 400 && r5.ram_n == 2 && r5.ram_sum_kb == 1000 + 1200 && r5.peak_kb == 1500 && r5.io_read == 2048 && r5.io_write == 0);
  const auto& r6 = store->res[{6, "a"}];
  CHECK(r6.cpu_ms == 300 && r6.ram_n == 1 && r6.io_read == 2048);
  CHECK(store->sysrows.empty());
  cfg.sys_ram = true;
  cfg.sys_disk = true;
  e.set_metrics(cfg);
  e.step(at(30000));
  e.step(at(40000));
  CHECK(probe->sys_calls == 1);
  e.step(at(140000));
  CHECK(probe->sys_calls == 2);
  e.finish();
  CHECK(store->sysrows.size() == 4);
  CHECK(store->sysrows[0].kind == "ram" && store->sysrows[0].a == 8000 && store->sysrows[0].b == 3000);
  CHECK(store->sysrows[1].kind == "disk:C:" && store->sysrows[1].a == 1000 && store->sysrows[1].b == 400);
}

void test_engine_metrics_only_enabled_fields() {
  auto probe = std::make_shared<MetricsProbe>();
  auto store = std::make_shared<ResStore>();
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_slot_source([] { return 1; });
  e.set_store(store, Duration(1000000));
  e.set_metrics_intervals(Duration(1000), Duration(1000));
  tw::MetricsConfig cfg;
  cfg.io_write = true;
  e.set_metrics(cfg);
  probe->push({{"a", State::Focused}});
  probe->snaps = {snap(1, 1, "a", 0, 1000, 1000, 0, 0)};
  e.step(at(0));
  probe->snaps = {snap(1, 1, "a", 900, 2000, 2000, 7, 3000)};
  e.step(at(2000));
  e.finish();
  const auto& r = store->res[{1, "a"}];
  CHECK(r.cpu_ms == 0 && r.ram_n == 0 && r.peak_kb == 0 && r.io_read == 0 && r.io_write == 3000);
}

void test_engine_metrics_skips_background_apps() {
  auto probe = std::make_shared<MetricsProbe>();
  auto store = std::make_shared<ResStore>();
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_slot_source([] { return 1; });
  e.set_store(store, Duration(1000000));
  e.set_metrics_intervals(Duration(1000), Duration(1000));
  tw::MetricsConfig cfg;
  cfg.cpu = true;
  cfg.ram = true;
  e.set_metrics(cfg);
  probe->push({{"fg", State::Focused}, {"bg", State::Background}});
  probe->snaps = {snap(1, 1, "fg", 0, 100, 100, 0, 0), snap(2, 1, "bg", 0, 200, 200, 0, 0)};
  e.step(at(0));
  probe->snaps = {snap(1, 1, "fg", 50, 100, 100, 0, 0), snap(2, 1, "bg", 70, 200, 200, 0, 0)};
  e.step(at(2000));
  e.finish();
  CHECK(store->res.count({1, "fg"}) == 1);
  CHECK(store->res.count({1, "bg"}) == 0);
}

void test_engine_afk_counts_idle_focus() {
  auto probe = std::make_shared<MetricsProbe>();
  auto store = std::make_shared<ResStore>();
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_slot_source([] { return 1; });
  e.set_store(store, Duration(1000000));
  e.set_afk_threshold(Duration(60000));
  probe->push({{"a", State::Focused}, {"b", State::Open}});
  probe->idle = 1000;
  e.step(at(0));
  e.step(at(1000));
  probe->idle = 70000;
  e.step(at(2000));
  e.step(at(3000));
  e.finish();
  CHECK(store->afk[{1, "a"}] == 2000);
  CHECK(store->afk.count({1, "b"}) == 0);
  tw::Engine off(probe, Duration(60000));
  auto store2 = std::make_shared<ResStore>();
  off.set_day_source([] { return std::string("2026-01-01"); });
  off.set_slot_source([] { return 1; });
  off.set_store(store2, Duration(1000000));
  off.step(at(0));
  off.step(at(1000));
  off.finish();
  CHECK(store2->afk.empty());
}

void test_limits_parse_and_fire_once() {
  auto l = tw::parse_limits("3600\tGames\ta\x1f" "b\n30\tbad\ta\nxx\tbad\ta\n60\tOne\tc\n");
  CHECK(l.size() == 2);
  CHECK(l[0].label == "Games" && l[0].apps.size() == 2 && l[0].seconds == 3600);
  auto probe = std::make_shared<MetricsProbe>();
  tw::Engine e(probe, Duration(120000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_limits(tw::parse_limits("60\tOne\ta\n"));
  std::vector<std::string> fired;
  e.set_limit_notifier([&](const tw::Limit& lim, long long) { fired.push_back(lim.label); });
  probe->push({{"a", State::Focused}});
  for (int i = 0; i <= 70; ++i) e.step(at(i * 1000));
  CHECK(fired.size() == 1 && fired[0] == "One");
  for (int i = 71; i < 90; ++i) e.step(at(i * 1000));
  CHECK(fired.size() == 1);
}

void test_afk_threshold_parse() {
  CHECK(tw::parse_afk_threshold("").count() == 300000);
  CHECK(tw::parse_afk_threshold("120\n").count() == 120000);
  CHECK(tw::parse_afk_threshold("0").count() == 0);
  CHECK(tw::parse_afk_threshold("5").count() == 30000);
  CHECK(tw::parse_afk_threshold("999999").count() == 3600000);
  CHECK(tw::parse_afk_threshold("abc").count() == 300000);
}

void test_proc_tracker_ignores_old_unseen_processes() {
  tw::ProcTracker t;
  t.update({snap(1, 10, "a", 100, 1, 1, 0, 0)});
  auto old = snap(2, 11, "a", 5000, 1, 1, 900, 900);
  old.age_ms = 3600000;
  auto fresh = snap(3, 12, "a", 400, 1, 1, 50, 60);
  fresh.age_ms = 2000;
  auto r = t.update({snap(1, 10, "a", 150, 1, 1, 0, 0), old, fresh});
  CHECK(r["a"].cpu_ms == 50 + 400);
  CHECK(r["a"].io_read == 50 && r["a"].io_write == 60);
  auto r2 = t.update({snap(1, 10, "a", 160, 1, 1, 0, 0), old, fresh});
  CHECK(r2["a"].cpu_ms == 10);
}

void test_engine_time_can_be_disabled() {
  auto probe = std::make_shared<MetricsProbe>();
  auto store = std::make_shared<ResStore>();
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_slot_source([] { return 1; });
  e.set_store(store, Duration(1000000));
  e.set_metrics_intervals(Duration(1000), Duration(1000));
  auto cfg = tw::parse_metrics("cpu notime");
  CHECK(cfg.no_time && cfg.cpu);
  CHECK(tw::parse_metrics(tw::format_metrics(cfg)) == cfg);
  e.set_metrics(cfg);
  probe->push({{"a", State::Focused}});
  probe->snaps = {snap(1, 1, "a", 0, 100, 100, 0, 0)};
  e.step(at(0));
  probe->snaps = {snap(1, 1, "a", 500, 100, 100, 0, 0)};
  e.step(at(2000));
  e.finish();
  CHECK(store->adds == 0 && store->slots.empty() && store->sessions.empty());
  CHECK(store->res[{1, "a"}].cpu_ms == 500);
}

void test_engine_metrics_no_rows_when_disabled() {
  auto probe = std::make_shared<MetricsProbe>();
  auto store = std::make_shared<ResStore>();
  tw::Engine e(probe, Duration(60000));
  e.set_day_source([] { return std::string("2026-01-01"); });
  e.set_store(store, Duration(1000000));
  probe->push({{"a", State::Focused}});
  probe->snaps = {snap(1, 1, "a", 0, 1000, 1000, 0, 0)};
  e.step(at(0));
  e.step(at(5000));
  e.finish();
  CHECK(store->res_calls == 0 && store->res.empty() && probe->proc_calls == 0);
}

void test_sqlite_resources() {
  std::string err;
  auto store = tw::SqliteStore::open(":memory:", &err);
  CHECK(store != nullptr);
  if (!store) return;
  tw::ResEntry a;
  a.slot = 3;
  a.app = "x.exe";
  a.cpu_ms = 100;
  a.ram_sum_kb = 2000;
  a.ram_n = 2;
  a.peak_kb = 1500;
  a.io_read = 10;
  a.io_write = 20;
  CHECK(store->add_resources("2026-01-01", {a}));
  a.cpu_ms = 50;
  a.peak_kb = 900;
  CHECK(store->add_resources("2026-01-01", {a}));
  CHECK(store->add_system({{1000, "ram", 8000, 3000}, {1000, "disk:C:", 100, 40}}));
  CHECK(store->add_system({{1000, "ram", 8000, 2500}}));
}

void test_native_metrics_smoke() {
  auto probe = tw::make_native_probe({});
  if (!probe->supports_metrics()) return;
  auto a = probe->proc_snapshot();
  CHECK(!a.empty());
  auto st = probe->sys_stat();
  CHECK(st.valid && st.ram_total_kb > 0 && st.ram_avail_kb >= 0);
  bool self = false;
  for (const auto& p : a) {
    if (p.rss_kb > 0 && p.peak_kb >= p.rss_kb) self = true;
  }
  CHECK(self);
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

void test_browser_api() {
  auto req = tw::parse_api_request_ex(
      "POST /v1/browser HTTP/1.1\r\nHost: 127.0.0.1:9095\r\nContent-Length: 49\r\n\r\n{\"browser\":\"chrome\",\"domain\":\"github.com\",\"ms\":5}",
      9095);
  CHECK(req.ok && req.method == "POST" && req.path == "/v1/browser" && req.body.find("github.com") != std::string::npos);
  CHECK(!tw::parse_api_request_ex("POST /v1/browser HTTP/1.1\r\nHost: evil.com:9095\r\n\r\n{}", 9095).ok);

  std::string err;
  auto store = tw::SqliteStore::open(":memory:", &err);
  CHECK(store != nullptr);
  if (!store) return;
  long long now = 1700000000;
  auto bad = tw::route_api("POST", "/v1/browser", "{\"browser\":\"chrome\",\"domain\":\"\",\"ms\":5000}", "", store.get(), now);
  CHECK(bad.status == 400);
  auto r1 = tw::route_api("POST", "/v1/browser", "{\"browser\":\"Chrome\",\"domain\":\"GitHub.com\",\"title\":\"GitHub: Build\",\"url\":\"https://github.com/explore\",\"ms\":12000}", "", store.get(), now);
  CHECK(r1.status == 200);
  auto r2 = tw::route_api("POST", "/v1/browser", "{\"browser\":\"chrome\",\"domain\":\"github.com\",\"ms\":8000}", "", store.get(), now);
  CHECK(r2.status == 200);
  auto top = tw::route_api("GET", "/v1/browser/top?days=1&limit=5", "", "", store.get(), now);
  CHECK(top.status == 200);
  CHECK(top.body.find("\"browser\":\"chrome\"") != std::string::npos);
  CHECK(top.body.find("\"domain\":\"github.com\"") != std::string::npos);
  CHECK(top.body.find("\"title\":\"GitHub: Build\"") != std::string::npos);
  CHECK(top.body.find("\"url\":\"https://github.com/explore\"") != std::string::npos);
  CHECK(top.body.find("\"ms\":20000") != std::string::npos);
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
#if defined(__linux__)
  test_wayland_parsers();
#endif
  test_local_api();
  test_presence_store();
  test_metrics_config_parse();
  test_proc_tracker();
  test_engine_metrics_buffer();
  test_engine_metrics_only_enabled_fields();
  test_engine_metrics_no_rows_when_disabled();
  test_engine_metrics_skips_background_apps();
  test_engine_time_can_be_disabled();
  test_engine_afk_counts_idle_focus();
  test_afk_threshold_parse();
  test_limits_parse_and_fire_once();
  test_proc_tracker_ignores_old_unseen_processes();
  test_sqlite_resources();
  test_native_metrics_smoke();
  test_browser_api();
#ifdef _WIN32
  test_ipc_roundtrip();
#endif
  if (failures == 0) std::printf("all tests passed\n");
  return failures == 0 ? 0 : 1;
}
