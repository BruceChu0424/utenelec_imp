cmake_minimum_required(VERSION 3.14)
project(uten_native_window_regression LANGUAGES CXX RC)
if(NOT WIN32)
  message(FATAL_ERROR "This harness exercises the actual Windows runner")
endif()
if(NOT DEFINED SUT_PROJECT)
  message(FATAL_ERROR "SUT_PROJECT must identify the frozen Flutter project")
endif()
set(EPHEMERAL "${SUT_PROJECT}/windows/flutter/ephemeral")
set(SUT_BUILD "${SUT_PROJECT}/build/windows/x64")
set(SUT_SOURCE_DIR "${SUT_PROJECT}/windows" CACHE PATH
  "Frozen task-only source tree containing runner/ and flutter/")
set(SUT "${SUT_SOURCE_DIR}")
set(HARNESS_RUNTIME "${CMAKE_CURRENT_BINARY_DIR}/runtime" CACHE PATH
  "Task-local runtime containing the matching engine, AOT and plugin DLLs")
set(HARNESS_APP_VERSION "2.5.35" CACHE STRING "Harness PE application version")
set(HARNESS_BUILD_NUMBER "2535" CACHE STRING "Harness PE build number")
if(NOT HARNESS_APP_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
  message(FATAL_ERROR "HARNESS_APP_VERSION must be major.minor.patch")
endif()
if(NOT HARNESS_BUILD_NUMBER MATCHES "^[0-9]+$")
  message(FATAL_ERROR "HARNESS_BUILD_NUMBER must be numeric")
endif()
string(REPLACE "." ";" HARNESS_VERSION_PARTS "${HARNESS_APP_VERSION}")
list(GET HARNESS_VERSION_PARTS 0 HARNESS_VERSION_MAJOR)
list(GET HARNESS_VERSION_PARTS 1 HARNESS_VERSION_MINOR)
list(GET HARNESS_VERSION_PARTS 2 HARNESS_VERSION_PATCH)
add_executable(uten_native_window_regression WIN32
  harness_main.cpp
  "${SUT}/runner/flutter_window.cpp"
  "${SUT}/runner/win32_window.cpp"
  "${SUT}/runner/client_update_channel.cpp"
  "${SUT}/runner/utils.cpp"
  "${SUT}/runner/Runner.rc"
  "${SUT}/runner/runner.exe.manifest"
  "${SUT}/flutter/generated_plugin_registrant.cc"
)
target_compile_features(uten_native_window_regression PRIVATE cxx_std_17)
target_compile_options(uten_native_window_regression PRIVATE /W4 /WX /utf-8 /EHsc /wd4100)
target_compile_definitions(uten_native_window_regression PRIVATE
  UNICODE _UNICODE NOMINMAX _HAS_EXCEPTIONS=0
  FLUTTER_VERSION="${HARNESS_APP_VERSION}+${HARNESS_BUILD_NUMBER}"
  FLUTTER_VERSION_MAJOR=${HARNESS_VERSION_MAJOR}
  FLUTTER_VERSION_MINOR=${HARNESS_VERSION_MINOR}
  FLUTTER_VERSION_PATCH=${HARNESS_VERSION_PATCH}
  FLUTTER_VERSION_BUILD=${HARNESS_BUILD_NUMBER}
)
target_include_directories(uten_native_window_regression PRIVATE
  "${SUT}" "${SUT}/runner" "${EPHEMERAL}"
  "${EPHEMERAL}/cpp_client_wrapper/include"
)
target_link_libraries(uten_native_window_regression PRIVATE
  "${SUT_BUILD}/flutter/Profile/flutter_wrapper_app.lib"
  "${EPHEMERAL}/flutter_windows.dll.lib"
  dwmapi comctl32 bcrypt shell32 ole32
)
# Read the actual project's native plugin list; FFI packages do not register here.
file(READ "${SUT_PROJECT}/windows/flutter/generated_plugins.cmake" PLUGIN_CONFIG)
string(REGEX MATCH "list\\(APPEND FLUTTER_PLUGIN_LIST([^)]*)\\)" PLUGIN_LIST_MATCH "${PLUGIN_CONFIG}")
set(PLUGIN_LIST_BODY "${CMAKE_MATCH_1}")
string(REGEX MATCHALL "[A-Za-z0-9_]+" NATIVE_PLUGINS "${PLUGIN_LIST_BODY}")
foreach(PLUGIN IN LISTS NATIVE_PLUGINS)
  target_include_directories(uten_native_window_regression PRIVATE
    "${SUT_PROJECT}/windows/flutter/ephemeral/.plugin_symlinks/${PLUGIN}/windows/include")
  target_link_libraries(uten_native_window_regression PRIVATE
    "${SUT_BUILD}/plugins/${PLUGIN}/Profile/${PLUGIN}_plugin.lib")
endforeach()
set_target_properties(uten_native_window_regression PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${HARNESS_RUNTIME}"
  RUNTIME_OUTPUT_DIRECTORY_RELEASE "${HARNESS_RUNTIME}"
)
