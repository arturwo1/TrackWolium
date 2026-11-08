add_executable(tw_tests test_main.cpp)
target_link_libraries(tw_tests PRIVATE tw_core tw_platform tw_console tw_capi tw_storage tw_ipc tw_i18n)
add_test(NAME tw_tests COMMAND tw_tests WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
