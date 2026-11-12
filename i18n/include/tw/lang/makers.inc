inline Table make_en() {
  Table x{};
#define S(k, t) x.text[static_cast<int>(Key::k)] = t;
#include "en.def"
#undef S
  return x;
}

inline Table make_ru() {
  Table x{};
#define S(k, t) x.text[static_cast<int>(Key::k)] = t;
#include "ru.def"
#undef S
  return x;
}
