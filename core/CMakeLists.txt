find_package(Threads REQUIRED)

add_library(tw_core STATIC src/tracker.cpp src/probe.cpp src/engine.cpp src/filter.cpp src/serialize.cpp)
target_include_directories(tw_core PUBLIC include)
target_link_libraries(tw_core PUBLIC Threads::Threads)
