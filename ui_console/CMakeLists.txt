if(WIN32)
  set(TW_CONSOLE_SETUP console_setup_win.cpp)
else()
  set(TW_CONSOLE_SETUP console_setup_posix.cpp)
endif()

add_library(tw_console STATIC console_sink.cpp ${TW_CONSOLE_SETUP})
target_include_directories(tw_console PUBLIC include)
target_link_libraries(tw_console PUBLIC tw_core)
