add_library(tw_capi SHARED src/capi.cpp)
target_include_directories(tw_capi PUBLIC include)
target_link_libraries(tw_capi PRIVATE tw_core)
set_target_properties(tw_capi PROPERTIES OUTPUT_NAME trackwolium)
