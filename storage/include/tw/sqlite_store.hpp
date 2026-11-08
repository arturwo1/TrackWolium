#pragma once
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "tw/store.hpp"

struct sqlite3;

namespace tw {

class SqliteStore : public IStore {
public:
  static std::unique_ptr<SqliteStore> open(const std::string& utf8_path, std::string* error);
  ~SqliteStore() override;

  bool add(const std::string& day, const std::vector<Interval>& intervals) override;
  std::vector<Interval> load_day(const std::string& day) override;
  std::vector<std::string> days(int limit) override;
  std::string last_error() const;

private:
  explicit SqliteStore(sqlite3* db);

  sqlite3* db_;
  mutable std::mutex mtx_;
  std::string last_error_;
};

}
