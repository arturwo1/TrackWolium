#pragma once
#include <memory>
#include <set>
#include <string>
#include "tw/sink.hpp"

namespace tw {

struct FilterOptions {
  bool hide_background_only = true;
  std::set<std::string> ignore;
};

std::set<std::string> default_ignore();
std::set<std::string> parse_ignore_list(const std::string& csv);
Report apply_filter(const Report& report, const FilterOptions& options);

class FilteredSink : public ISink {
public:
  FilteredSink(std::shared_ptr<ISink> inner, FilterOptions options);
  void render(const Report& report) override;

private:
  std::shared_ptr<ISink> inner_;
  FilterOptions opt_;
};

}
