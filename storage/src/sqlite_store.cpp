#include "tw/sqlite_store.hpp"
#include "sqlite3.h"

namespace tw {
namespace {

bool exec(sqlite3* db, const char* sql, std::string* error) {
  char* msg = nullptr;
  int rc = sqlite3_exec(db, sql, nullptr, nullptr, &msg);
  if (rc != SQLITE_OK) {
    if (error) *error = msg ? msg : "sqlite error";
    sqlite3_free(msg);
    return false;
  }
  return true;
}

std::string column_text(sqlite3_stmt* st, int col) {
  const unsigned char* p = sqlite3_column_text(st, col);
  return p ? reinterpret_cast<const char*>(p) : std::string();
}

}

SqliteStore::SqliteStore(sqlite3* db) : db_(db) {}

SqliteStore::~SqliteStore() {
  if (db_) sqlite3_close(db_);
}

std::unique_ptr<SqliteStore> SqliteStore::open(const std::string& utf8_path, std::string* error) {
  sqlite3* db = nullptr;
  int rc = sqlite3_open_v2(utf8_path.c_str(), &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nullptr);
  if (rc != SQLITE_OK) {
    if (error) *error = db ? sqlite3_errmsg(db) : "out of memory";
    if (db) sqlite3_close(db);
    return nullptr;
  }
  sqlite3_busy_timeout(db, 3000);

  const char* schema =
      "PRAGMA journal_mode=WAL;"
      "PRAGMA synchronous=NORMAL;"
      "CREATE TABLE IF NOT EXISTS usage("
      "day TEXT NOT NULL,"
      "app TEXT NOT NULL,"
      "state INTEGER NOT NULL,"
      "ms INTEGER NOT NULL,"
      "PRIMARY KEY(day, app, state)) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS timeline(day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, slot, app, state)) WITHOUT ROWID;"
      "CREATE TABLE IF NOT EXISTS sessions(app TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, state INTEGER NOT NULL, PRIMARY KEY(app, start)) WITHOUT ROWID;"
      "CREATE INDEX IF NOT EXISTS sessions_start ON sessions(start);"
      "CREATE TABLE IF NOT EXISTS presence(ts INTEGER NOT NULL, client_id TEXT NOT NULL, name TEXT NOT NULL, details TEXT NOT NULL, state TEXT NOT NULL, started INTEGER NOT NULL, raw TEXT NOT NULL DEFAULT '');"
      "CREATE TABLE IF NOT EXISTS apps(app TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '') WITHOUT ROWID;";
  if (!exec(db, schema, error)) {
    sqlite3_close(db);
    return nullptr;
  }
  sqlite3_exec(db, "ALTER TABLE presence ADD COLUMN raw TEXT NOT NULL DEFAULT ''", nullptr, nullptr, nullptr);
  sqlite3_exec(db, "ALTER TABLE apps ADD COLUMN path TEXT NOT NULL DEFAULT ''", nullptr, nullptr, nullptr);
  return std::unique_ptr<SqliteStore>(new SqliteStore(db));
}

bool SqliteStore::add(const std::string& day, const std::vector<Interval>& intervals) {
  if (intervals.empty()) return true;
  std::lock_guard<std::mutex> lock(mtx_);

  if (!exec(db_, "BEGIN IMMEDIATE", &last_error_)) return false;

  const char* sql =
      "INSERT INTO usage(day, app, state, ms) VALUES(?1, ?2, ?3, ?4) "
      "ON CONFLICT(day, app, state) DO UPDATE SET ms = ms + excluded.ms";
  sqlite3_stmt* st = nullptr;
  if (sqlite3_prepare_v2(db_, sql, -1, &st, nullptr) != SQLITE_OK) {
    last_error_ = sqlite3_errmsg(db_);
    exec(db_, "ROLLBACK", nullptr);
    return false;
  }

  bool ok = true;
  for (const auto& iv : intervals) {
    sqlite3_bind_text(st, 1, day.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, iv.app.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, static_cast<int>(iv.state));
    sqlite3_bind_int64(st, 4, static_cast<sqlite3_int64>(iv.ms.count()));
    if (sqlite3_step(st) != SQLITE_DONE) {
      last_error_ = sqlite3_errmsg(db_);
      ok = false;
      break;
    }
    sqlite3_reset(st);
  }
  sqlite3_finalize(st);

  if (!ok) {
    exec(db_, "ROLLBACK", nullptr);
    return false;
  }
  return exec(db_, "COMMIT", &last_error_);
}

bool SqliteStore::add_timeline(const std::string& day, const std::vector<SlotEntry>& entries) {
  if (entries.empty()) return true;
  std::lock_guard<std::mutex> lock(mtx_);
  if (!exec(db_, "BEGIN IMMEDIATE", &last_error_)) return false;
  sqlite3_stmt* st = nullptr;
  const char* sql =
      "INSERT INTO timeline(day, slot, app, state, ms) VALUES(?1, ?2, ?3, ?4, ?5) "
      "ON CONFLICT(day, slot, app, state) DO UPDATE SET ms = ms + excluded.ms";
  if (sqlite3_prepare_v2(db_, sql, -1, &st, nullptr) != SQLITE_OK) {
    last_error_ = sqlite3_errmsg(db_);
    exec(db_, "ROLLBACK", nullptr);
    return false;
  }
  bool ok = true;
  for (const auto& e : entries) {
    sqlite3_bind_text(st, 1, day.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, e.slot);
    sqlite3_bind_text(st, 3, e.app.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 4, e.state);
    sqlite3_bind_int64(st, 5, static_cast<sqlite3_int64>(e.ms));
    if (sqlite3_step(st) != SQLITE_DONE) {
      last_error_ = sqlite3_errmsg(db_);
      ok = false;
      break;
    }
    sqlite3_reset(st);
  }
  sqlite3_finalize(st);
  if (!ok) {
    exec(db_, "ROLLBACK", nullptr);
    return false;
  }
  return exec(db_, "COMMIT", &last_error_);
}

bool SqliteStore::set_names(const std::vector<AppMeta>& names) {
  if (names.empty()) return true;
  std::lock_guard<std::mutex> lock(mtx_);
  if (!exec(db_, "BEGIN IMMEDIATE", &last_error_)) return false;
  sqlite3_stmt* st = nullptr;
  const char* sql =
      "INSERT INTO apps(app, name, path) VALUES(?1, ?2, ?3) "
      "ON CONFLICT(app) DO UPDATE SET name = excluded.name, path = excluded.path";
  if (sqlite3_prepare_v2(db_, sql, -1, &st, nullptr) != SQLITE_OK) {
    last_error_ = sqlite3_errmsg(db_);
    exec(db_, "ROLLBACK", nullptr);
    return false;
  }
  for (const auto& m : names) {
    sqlite3_bind_text(st, 1, m.app.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, m.name.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, m.path.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(st);
    sqlite3_reset(st);
  }
  sqlite3_finalize(st);
  return exec(db_, "COMMIT", &last_error_);
}

bool SqliteStore::add_sessions(const std::vector<SessionRec>& sessions) {
  if (sessions.empty()) return true;
  std::lock_guard<std::mutex> lock(mtx_);
  if (!exec(db_, "BEGIN IMMEDIATE", &last_error_)) return false;
  sqlite3_stmt* st = nullptr;
  const char* sql =
      "INSERT INTO sessions(app, start, stop, state) VALUES(?1, ?2, ?3, ?4) "
      "ON CONFLICT(app, start) DO UPDATE SET stop = excluded.stop, state = excluded.state";
  if (sqlite3_prepare_v2(db_, sql, -1, &st, nullptr) != SQLITE_OK) {
    last_error_ = sqlite3_errmsg(db_);
    exec(db_, "ROLLBACK", nullptr);
    return false;
  }
  for (const auto& r : sessions) {
    sqlite3_bind_text(st, 1, r.app.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, r.start);
    sqlite3_bind_int64(st, 3, r.stop);
    sqlite3_bind_int(st, 4, r.state);
    sqlite3_step(st);
    sqlite3_reset(st);
  }
  sqlite3_finalize(st);
  return exec(db_, "COMMIT", &last_error_);
}

std::vector<SessionRec> SqliteStore::load_sessions(long long from, long long to) {
  std::vector<SessionRec> out;
  std::lock_guard<std::mutex> lock(mtx_);
  sqlite3_stmt* st = nullptr;
  if (sqlite3_prepare_v2(db_, "SELECT app, state, start, stop FROM sessions WHERE stop >= ?1 AND start <= ?2 ORDER BY start", -1, &st, nullptr) != SQLITE_OK) return out;
  sqlite3_bind_int64(st, 1, from);
  sqlite3_bind_int64(st, 2, to);
  while (sqlite3_step(st) == SQLITE_ROW) {
    const unsigned char* t = sqlite3_column_text(st, 0);
    out.push_back({t ? reinterpret_cast<const char*>(t) : "", sqlite3_column_int(st, 1), sqlite3_column_int64(st, 2), sqlite3_column_int64(st, 3)});
  }
  sqlite3_finalize(st);
  return out;
}

bool SqliteStore::add_presence(std::int64_t ts, const std::vector<Presence>& items) {
  if (items.empty()) return true;
  std::lock_guard<std::mutex> lock(mtx_);
  if (!exec(db_, "BEGIN IMMEDIATE", &last_error_)) return false;
  sqlite3_stmt* st = nullptr;
  const char* sql = "INSERT INTO presence(ts, client_id, name, details, state, started, raw) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)";
  if (sqlite3_prepare_v2(db_, sql, -1, &st, nullptr) != SQLITE_OK) {
    last_error_ = sqlite3_errmsg(db_);
    exec(db_, "ROLLBACK", nullptr);
    return false;
  }
  for (const auto& p : items) {
    sqlite3_bind_int64(st, 1, ts);
    sqlite3_bind_text(st, 2, p.client_id.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, p.name.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, p.details.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, p.state.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 6, p.started);
    sqlite3_bind_text(st, 7, p.raw.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(st);
    sqlite3_reset(st);
  }
  sqlite3_finalize(st);
  return exec(db_, "COMMIT", &last_error_);
}

std::vector<Presence> SqliteStore::load_presence(std::int64_t from_ts, std::int64_t to_ts) {
  std::vector<Presence> out;
  std::lock_guard<std::mutex> lock(mtx_);
  sqlite3_stmt* st = nullptr;
  const char* sql = "SELECT client_id, name, details, state, started, raw FROM presence WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts";
  if (sqlite3_prepare_v2(db_, sql, -1, &st, nullptr) != SQLITE_OK) return out;
  sqlite3_bind_int64(st, 1, from_ts);
  sqlite3_bind_int64(st, 2, to_ts);
  auto text = [&](int c) {
    const unsigned char* t = sqlite3_column_text(st, c);
    return std::string(t ? reinterpret_cast<const char*>(t) : "");
  };
  while (sqlite3_step(st) == SQLITE_ROW) out.push_back({text(0), text(1), text(2), text(3), sqlite3_column_int64(st, 4), text(5)});
  sqlite3_finalize(st);
  return out;
}

std::vector<Interval> SqliteStore::load_day(const std::string& day) {
  std::vector<Interval> out;
  std::lock_guard<std::mutex> lock(mtx_);
  sqlite3_stmt* st = nullptr;
  if (sqlite3_prepare_v2(db_, "SELECT app, state, ms FROM usage WHERE day = ?1", -1, &st, nullptr) != SQLITE_OK) {
    last_error_ = sqlite3_errmsg(db_);
    return out;
  }
  sqlite3_bind_text(st, 1, day.c_str(), -1, SQLITE_TRANSIENT);
  while (sqlite3_step(st) == SQLITE_ROW) {
    int state = sqlite3_column_int(st, 1);
    if (state < 0 || state >= kStateCount) continue;
    out.push_back({column_text(st, 0), static_cast<State>(state), Duration(sqlite3_column_int64(st, 2))});
  }
  sqlite3_finalize(st);
  return out;
}

std::vector<std::string> SqliteStore::days(int limit) {
  std::vector<std::string> out;
  std::lock_guard<std::mutex> lock(mtx_);
  sqlite3_stmt* st = nullptr;
  if (sqlite3_prepare_v2(db_, "SELECT DISTINCT day FROM usage ORDER BY day DESC LIMIT ?1", -1, &st, nullptr) != SQLITE_OK) {
    last_error_ = sqlite3_errmsg(db_);
    return out;
  }
  sqlite3_bind_int(st, 1, limit);
  while (sqlite3_step(st) == SQLITE_ROW) out.push_back(column_text(st, 0));
  sqlite3_finalize(st);
  return out;
}

std::string SqliteStore::last_error() const {
  std::lock_guard<std::mutex> lock(mtx_);
  return last_error_;
}

}
