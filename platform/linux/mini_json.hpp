#pragma once
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

namespace tw {

struct Json {
  enum Kind { Null, Bool, Number, String, Array, Object } kind = Null;
  bool b = false;
  double n = 0;
  std::string s;
  std::vector<Json> a;
  std::vector<std::pair<std::string, Json>> o;

  const Json* get(const std::string& key) const {
    for (const auto& kv : o) {
      if (kv.first == key) return &kv.second;
    }
    return nullptr;
  }

  std::string str(const std::string& key) const {
    const Json* v = get(key);
    return v && v->kind == String ? v->s : std::string();
  }

  double num(const std::string& key, double fallback = 0) const {
    const Json* v = get(key);
    return v && v->kind == Number ? v->n : fallback;
  }

  bool flag(const std::string& key) const {
    const Json* v = get(key);
    return v && v->kind == Bool && v->b;
  }
};

class JsonParser {
public:
  explicit JsonParser(const std::string& text) : t_(text) {}

  bool parse(Json& out) {
    skip();
    if (!value(out, 0)) return false;
    skip();
    return true;
  }

private:
  void skip() {
    while (i_ < t_.size() && (t_[i_] == ' ' || t_[i_] == '\n' || t_[i_] == '\r' || t_[i_] == '\t')) ++i_;
  }

  bool lit(const char* word) {
    std::size_t n = 0;
    while (word[n]) ++n;
    if (t_.compare(i_, n, word) != 0) return false;
    i_ += n;
    return true;
  }

  bool string(std::string& out) {
    if (i_ >= t_.size() || t_[i_] != '"') return false;
    ++i_;
    while (i_ < t_.size()) {
      char c = t_[i_++];
      if (c == '"') return true;
      if (c != '\\') {
        out.push_back(c);
        continue;
      }
      if (i_ >= t_.size()) return false;
      char e = t_[i_++];
      switch (e) {
        case 'n': out.push_back('\n'); break;
        case 't': out.push_back('\t'); break;
        case 'r': out.push_back('\r'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'u': {
          if (i_ + 4 > t_.size()) return false;
          unsigned cp = static_cast<unsigned>(std::strtoul(t_.substr(i_, 4).c_str(), nullptr, 16));
          i_ += 4;
          if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
          } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
          } else {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
          }
          break;
        }
        default: out.push_back(e);
      }
    }
    return false;
  }

  bool value(Json& out, int depth) {
    if (depth > 64 || i_ >= t_.size()) return false;
    char c = t_[i_];
    if (c == '{') {
      out.kind = Json::Object;
      ++i_;
      skip();
      if (i_ < t_.size() && t_[i_] == '}') {
        ++i_;
        return true;
      }
      while (true) {
        skip();
        std::string key;
        if (!string(key)) return false;
        skip();
        if (i_ >= t_.size() || t_[i_] != ':') return false;
        ++i_;
        skip();
        Json v;
        if (!value(v, depth + 1)) return false;
        out.o.emplace_back(std::move(key), std::move(v));
        skip();
        if (i_ < t_.size() && t_[i_] == ',') {
          ++i_;
          continue;
        }
        if (i_ < t_.size() && t_[i_] == '}') {
          ++i_;
          return true;
        }
        return false;
      }
    }
    if (c == '[') {
      out.kind = Json::Array;
      ++i_;
      skip();
      if (i_ < t_.size() && t_[i_] == ']') {
        ++i_;
        return true;
      }
      while (true) {
        skip();
        Json v;
        if (!value(v, depth + 1)) return false;
        out.a.push_back(std::move(v));
        skip();
        if (i_ < t_.size() && t_[i_] == ',') {
          ++i_;
          continue;
        }
        if (i_ < t_.size() && t_[i_] == ']') {
          ++i_;
          return true;
        }
        return false;
      }
    }
    if (c == '"') {
      out.kind = Json::String;
      return string(out.s);
    }
    if (lit("true")) {
      out.kind = Json::Bool;
      out.b = true;
      return true;
    }
    if (lit("false")) {
      out.kind = Json::Bool;
      return true;
    }
    if (lit("null")) return true;
    char* end = nullptr;
    out.n = std::strtod(t_.c_str() + i_, &end);
    if (end == t_.c_str() + i_) return false;
    out.kind = Json::Number;
    i_ = static_cast<std::size_t>(end - t_.c_str());
    return true;
  }

  const std::string& t_;
  std::size_t i_ = 0;
};

}
