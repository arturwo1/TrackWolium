#pragma once
#include <string>
#include "tw/types.hpp"

namespace tw {

std::string serialize(const Report& report);
bool deserialize(const std::string& data, Report& out);

}
