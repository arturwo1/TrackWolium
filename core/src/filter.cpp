#include "tw/filter.hpp"
#include <cctype>

namespace tw {
namespace {

std::string lower(std::string s) {
  for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

std::string trim(const std::string& s) {
  std::size_t b = 0;
  std::size_t e = s.size();
  while (b < e && std::isspace(static_cast<unsigned char>(s[b]))) ++b;
  while (e > b && std::isspace(static_cast<unsigned char>(s[e - 1]))) --e;
  return s.substr(b, e - b);
}

}

std::set<std::string> default_ignore() {
  return {
    "applicationframehost.exe",
    "textinputhost.exe",
    "searchhost.exe",
    "startmenuexperiencehost.exe",
    "shellexperiencehost.exe",
    "lockapp.exe",
  };
}

std::set<std::string> parse_ignore_list(const std::string& csv) {
  std::set<std::string> out;
  std::size_t start = 0;
  while (start <= csv.size()) {
    std::size_t end = csv.find(',', start);
    if (end == std::string::npos) end = csv.size();
    std::string item = lower(trim(csv.substr(start, end - start)));
    if (!item.empty()) out.insert(item);
    start = end + 1;
  }
  return out;
}

Report apply_filter(const Report& report, const FilterOptions& options) {
  Report out;
  out.uptime = report.uptime;
  out.hidden = report.hidden;
  for (const auto& row : report.rows) {
    bool hide = options.ignore.count(lower(row.app)) > 0;
    if (!hide && options.hide_background_only && row.visible() == Duration(0)) hide = true;
    if (hide) ++out.hidden;
    else out.rows.push_back(row);
  }
  return out;
}

FilteredSink::FilteredSink(std::shared_ptr<ISink> inner, FilterOptions options)
    : inner_(std::move(inner)), opt_(std::move(options)) {}

void FilteredSink::render(const Report& report) {
  inner_->render(apply_filter(report, opt_));
}

}
