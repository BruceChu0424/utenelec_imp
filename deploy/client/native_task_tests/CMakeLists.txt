cmake_minimum_required(VERSION 3.14)
project(uten_native_task_tests LANGUAGES CXX)
enable_testing()
add_executable(uten_native_task_tests
  main.cpp
  diagnostics_checks.cpp
  ../../../windows/runner/native_diagnostics.cpp
  ../../../windows/runner/update_helper_process.cpp
  ../../../windows/runner/window_background_task.cpp)
target_include_directories(uten_native_task_tests PRIVATE ../../../windows/runner)
target_compile_features(uten_native_task_tests PRIVATE cxx_std_17)
target_compile_definitions(uten_native_task_tests PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(uten_native_task_tests PRIVATE /W4 /WX /EHsc)
target_link_libraries(uten_native_task_tests PRIVATE ole32 shell32)
add_test(NAME native_task_lifecycle COMMAND uten_native_task_tests)
