#include "tw/console_sink.hpp"
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#ifndef ENABLE_VIRTUAL_TERMINAL_PROCESSING
#define ENABLE_VIRTUAL_TERMINAL_PROCESSING 0x0004
#endif

namespace tw {

bool console_setup() {
  SetConsoleOutputCP(CP_UTF8);
  SetConsoleTitleW(L"TrackWolium");
  HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
  DWORD mode = 0;
  if (h == INVALID_HANDLE_VALUE || !GetConsoleMode(h, &mode)) return false;
  return SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0;
}

}
