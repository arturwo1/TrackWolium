file(READ "${SRC}" hex HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," bytes "${hex}")
file(WRITE "${OUT}" "#include \"tw/localapi.hpp\"\nnamespace tw {\nstd::string widget_html() {\n  static const unsigned char data[] = {${bytes}0x00};\n  return std::string(reinterpret_cast<const char*>(data), sizeof(data) - 1);\n}\n}\n")
