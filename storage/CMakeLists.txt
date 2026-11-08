find_package(Threads REQUIRED)

add_library(tw_sqlite3 STATIC third_party/sqlite3.c)
target_include_directories(tw_sqlite3 PUBLIC third_party)
target_compile_definitions(tw_sqlite3 PRIVATE
  SQLITE_THREADSAFE=1
  SQLITE_OMIT_LOAD_EXTENSION
  SQLITE_OMIT_DEPRECATED
  SQLITE_OMIT_SHARED_CACHE
  SQLITE_DEFAULT_MEMSTATUS=0
  SQLITE_DQS=0)
target_link_libraries(tw_sqlite3 PUBLIC Threads::Threads)
if(MSVC)
  target_compile_options(tw_sqlite3 PRIVATE /w)
else()
  target_compile_options(tw_sqlite3 PRIVATE -w)
endif()

add_library(tw_storage STATIC src/sqlite_store.cpp)
target_include_directories(tw_storage PUBLIC include)
target_link_libraries(tw_storage PUBLIC tw_core PRIVATE tw_sqlite3)
