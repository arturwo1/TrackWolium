#include "tw/console_sink.hpp"
#include <algorithm>
#include <cstdio>
#include <sstream>

namespace tw {
namespace {

std::size_t display_width(const std::string& s) {
  std::size_t n = 0;
  for (unsigned char c : s) {
    if ((c & 0xC0) != 0x80) ++n;
  }
  return n;
}

std::string fit(const std::string& s, std::size_t width) {
  std::size_t w = display_width(s);
  if (w <= width) return s + std::string(width - w, ' ');

  std::string out;
  std::size_t n = 0;
  for (std::size_t i = 0; i < s.size() && n + 1 < width;) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    std::size_t len = 1;
    if (c >= 0xF0) len = 4;
    else if (c >= 0xE0) len = 3;
    else if (c >= 0xC0) len = 2;
    out.append(s, i, len);
    i += len;
    ++n;
  }
  out += "~";
  return out + std::string(width - n - 1, ' ');
}

std::string right(const std::string& s, std::size_t width) {
  std::size_t w = display_width(s);
  return w >= width ? s : std::string(width - w, ' ') + s;
}

const char* state_color(State s) {
  switch (s) {
    case State::Focused: return "32";
    case State::Open: return "36";
    case State::Minimized: return "33";
    case State::Background: return "90";
  }
  return "0";
}

}

std::string format_duration(Duration d) {
  long long ms = d.count();
  long long total = ms / 1000;
  if (total <= 0) return ms > 0 ? "<1s" : "-";
  long long h = total / 3600;
  long long m = (total % 3600) / 60;
  long long s = total % 60;
  char buf[48];
  if (h > 0) std::snprintf(buf, sizeof buf, "%lldh%02lldm%02llds", h, m, s);
  else if (m > 0) std::snprintf(buf, sizeof buf, "%lldm%02llds", m, s);
  else std::snprintf(buf, sizeof buf, "%llds", s);
  return buf;
}

ConsoleSink::ConsoleSink(std::ostream& out, ConsoleOptions options) : out_(out), opt_(options) {}

ConsoleSink::~ConsoleSink() {
  if (opt_.live && started_) out_ << "\x1b[?25h" << std::flush;
}

void ConsoleSink::render(const Report& r) {
  auto paint = [&](const char* code, const std::string& text) {
    if (!opt_.color) return text;
    return std::string("\x1b[") + code + "m" + text + "\x1b[0m";
  };
  const std::string eol = opt_.live ? "\x1b[K\n" : "\n";

  std::size_t running = 0;
  for (const auto& row : r.rows) {
    if (row.running) ++running;
  }

  std::ostringstream o;
  if (opt_.live) {
    if (!started_) o << "\x1b[?25l\x1b[2J";
    o << "\x1b[H";
  }
  started_ = true;

  o << paint("1", " " + opt_.title);
  if (opt_.show_uptime) o << "   uptime " << format_duration(r.uptime);
  o << "   apps " << running << "/" << r.rows.size();
  if (r.hidden > 0) o << paint("90", "   (+" + std::to_string(r.hidden) + " hidden)");
  o << eol;
  o << eol;
  o << paint("1", " " + fit("APP", 28) + " " + fit("NOW", 11) + right("FOCUS", 9) + right("OPEN", 9) +
                  right("MIN", 9) + right("BG", 9) + right("TOTAL", 10)) << eol;
  o << " " << std::string(28 + 1 + 11 + 9 * 4 + 10, '-') << eol;

  std::size_t shown = std::min(opt_.top, r.rows.size());
  for (std::size_t i = 0; i < shown; ++i) {
    const AppRow& row = r.rows[i];
    std::string now = row.running ? state_name(row.state) : "-";
    std::string line = " " + fit(row.app, 28) + " ";
    o << line << paint(row.running ? state_color(row.state) : "90", fit(now, 11));
    for (int s = 0; s < kStateCount; ++s) {
      o << right(format_duration(row.spent[s]), 9);
    }
    o << right(format_duration(row.total()), 10) << eol;
  }
  if (r.rows.size() > shown) o << " ... " << (r.rows.size() - shown) << " more" << eol;

  o << eol << paint("90", " Ctrl+C to quit") << eol;
  if (opt_.live) o << "\x1b[J";

  out_ << o.str() << std::flush;
}

}
