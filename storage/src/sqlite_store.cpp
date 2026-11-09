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
      "CREATE TABLE IF NOT EXISTS apps(app TEXT PRIMARY KEY, name TEXT NOT NULL) WITHOUT ROWID;";
  if (!exec(db, schema, error)) {
    sqlite3_close(db);
    return nullptr;
  }
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

bool SqliteStore::set_names(const std::vector<std::pair<std::string, std::string>>& names) {
  if (names.empty()) return true;
  std::lock_guard<std::mutex> lock(mtx_);
  if (!exec(db_, "BEGIN IMMEDIATE", &last_error_)) return false;
  sqlite3_stmt* st = nullptr;
  if (sqlite3_prepare_v2(db_, "INSERT INTO apps(app, name) VALUES(?1, ?2) ON CONFLICT(app) DO UPDATE SET name = excluded.name", -1, &st, nullptr) != SQLITE_OK) {
    last_error_ = sqlite3_errmsg(db_);
    exec(db_, "ROLLBACK", nullptr);
    return false;
  }
  for (const auto& kv : names) {
    sqlite3_bind_text(st, 1, kv.first.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, kv.second.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_step(st);
    sqlite3_reset(st);
  }
  sqlite3_finalize(st);
  return exec(db_, "COMMIT", &last_error_);
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
