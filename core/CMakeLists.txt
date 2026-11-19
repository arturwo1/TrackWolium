find_package(Threads REQUIRED)

add_library(tw_core STATIC src/tracker.cpp src/probe.cpp src/engine.cpp src/filter.cpp src/serialize.cpp src/rpc.cpp src/procstat.cpp src/localapi.cpp ${CMAKE_CURRENT_BINARY_DIR}/widget_html.cpp)
add_custom_command(
  OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/widget_html.cpp
  COMMAND ${CMAKE_COMMAND} -DSRC=${CMAKE_CURRENT_SOURCE_DIR}/src/widget.html -DOUT=${CMAKE_CURRENT_BINARY_DIR}/widget_html.cpp -P ${CMAKE_CURRENT_SOURCE_DIR}/embed.cmake
  DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/widget.html ${CMAKE_CURRENT_SOURCE_DIR}/embed.cmake)
target_include_directories(tw_core PUBLIC include)
target_link_libraries(tw_core PUBLIC Threads::Threads)
