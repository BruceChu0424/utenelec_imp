cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# The same Dart build flag owns the native PE/storage identity. Never infer a
# test profile from a directory name, build mode or installer switch.
include("${FLUTTER_MANAGED_DIR}/ephemeral/generated_config.cmake")
set(UTEN_RUNTIME_DART_DEFINES "")
foreach(UTEN_ENV_ENTRY IN LISTS FLUTTER_TOOL_ENVIRONMENT)
  if(UTEN_ENV_ENTRY MATCHES "^DART_DEFINES=(.*)$")
    set(UTEN_RUNTIME_DART_DEFINES "${CMAKE_MATCH_1}")
  endif()
endforeach()
set(UTEN_PROFILE_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated-runtime")
execute_process(
  COMMAND "${FLUTTER_ROOT}/bin/cache/dart-sdk/bin/dart.exe"
    "${CMAKE_SOURCE_DIR}/../tool/generate_native_runtime_profile.dart"
    "--dart-defines=${UTEN_RUNTIME_DART_DEFINES}"
    "--header=${UTEN_PROFILE_DIR}/client_runtime_profile.g.h"
    "--manifest=${UTEN_PROFILE_DIR}/uten-runtime-profile.json"
  RESULT_VARIABLE UTEN_PROFILE_RESULT
  ERROR_VARIABLE UTEN_PROFILE_ERROR
  OUTPUT_QUIET
)
if(NOT UTEN_PROFILE_RESULT EQUAL 0)
  message(FATAL_ERROR "Invalid runtime build profile: ${UTEN_PROFILE_ERROR}")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${CMAKE_SOURCE_DIR}/../lib/core/runtime/client_runtime_profile.dart"
  "${CMAKE_SOURCE_DIR}/../tool/generate_native_runtime_profile.dart")

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "client_update_channel.cpp"
  "window_background_task.cpp"
  "update_helper_process.cpp"
  "native_diagnostics.cpp"
  "software_download_host.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")
target_compile_definitions(${BINARY_NAME} PRIVATE "UTEN_BUILD_KIND=\"$<CONFIG>\"")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(${BINARY_NAME} PRIVATE "UTEN_GENERATED_RUNTIME_PROFILE=1")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "comctl32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "bcrypt.lib" "shell32.lib" "ole32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(${BINARY_NAME} PRIVATE "${UTEN_PROFILE_DIR}")
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:${BINARY_NAME}>/data"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${UTEN_PROFILE_DIR}/uten-runtime-profile.json"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/data/uten-runtime-profile.json")
install(FILES "${UTEN_PROFILE_DIR}/uten-runtime-profile.json"
  DESTINATION "$<TARGET_FILE_DIR:${BINARY_NAME}>/data" COMPONENT Runtime)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
