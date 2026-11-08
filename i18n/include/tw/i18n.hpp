#pragma once
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace tw {
namespace i18n {

enum class Key {
#define S(k, t) k,
#include "lang/en.def"
#undef S
  Count
};

constexpr int kKeyCount = static_cast<int>(Key::Count);

namespace detail {

struct Table {
  const wchar_t* text[kKeyCount];
};

inline Table make_en() {
  Table x{};
#define S(k, t) x.text[static_cast<int>(Key::k)] = t;
#include "lang/en.def"
#undef S
  return x;
}

inline Table make_ru() {
  Table x{};
#define S(k, t) x.text[static_cast<int>(Key::k)] = t;
#include "lang/ru.def"
#undef S
  return x;
}

struct Language {
  const char* code;
  const wchar_t* name;
  Table table;
};

inline const std::vector<Language>& languages() {
  static const std::vector<Language> list = {
      {"en", L"English", make_en()},
      {"ru", L"Русский", make_ru()},
  };
  return list;
}

inline int& current_index() {
  static int index = 0;
  return index;
}

}

inline int count() { return static_cast<int>(detail::languages().size()); }
inline const char* code(int i) { return detail::languages()[static_cast<std::size_t>(i)].code; }
inline const wchar_t* name(int i) { return detail::languages()[static_cast<std::size_t>(i)].name; }
inline int current() { return detail::current_index(); }

inline int find(const std::string& c) {
  for (int i = 0; i < count(); ++i) {
    if (c == code(i)) return i;
  }
  return -1;
}

inline void set(int i) {
  if (i >= 0 && i < count()) detail::current_index() = i;
}

inline int from_langid(unsigned langid) {
  int i = find(langid == 0x19 ? "ru" : "en");
  return i < 0 ? 0 : i;
}

inline const wchar_t* tr(Key k) {
  const auto& langs = detail::languages();
  const wchar_t* t = langs[static_cast<std::size_t>(detail::current_index())].table.text[static_cast<int>(k)];
  return t ? t : langs[0].table.text[static_cast<int>(k)];
}

inline std::string read_code(const std::filesystem::path& file) {
  std::ifstream in(file);
  std::string s;
  if (in) std::getline(in, s);
  while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' ')) s.pop_back();
  return s;
}

inline bool write_code(const std::filesystem::path& file, const std::string& c) {
  std::error_code ec;
  std::filesystem::create_directories(file.parent_path(), ec);
  std::ofstream out(file, std::ios::trunc);
  if (!out) return false;
  out << c << "\n";
  return static_cast<bool>(out);
}

inline void load(const std::filesystem::path& file, unsigned fallback_langid) {
  int i = find(read_code(file));
  set(i >= 0 ? i : from_langid(fallback_langid & 0x3FF));
}

}
}
