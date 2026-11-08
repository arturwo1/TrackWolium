#include "tw/console_sink.hpp"
#include <unistd.h>
#include <cstdlib>
#include <cstring>

namespace tw {

bool console_setup() {
  if (!isatty(STDOUT_FILENO)) return false;
  const char* term = std::getenv("TERM");
  return term != nullptr && std::strcmp(term, "dumb") != 0;
}

}
