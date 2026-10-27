# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(uten_imp LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "uten_imp")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  # Plugins can contain Unicode source; do not decode them through the host ANSI code page.
  target_compile_options(${TARGET} PRIVATE /EHsc /utf-8)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

# === App-local MSVC release runtime ===
# A developer PC's globally installed VC runtime must not hide missing files in
# the employee bundle. Use CMake's compiler discovery, then include the entire
# matching release CRT folder (including helpers newer than CMake's DLL list).
if(MSVC)
  set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
  set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS "")
  set(CMAKE_INSTALL_DEBUG_LIBRARIES FALSE)
  set(CMAKE_INSTALL_DEBUG_LIBRARIES_ONLY FALSE)
  # Windows 10+ supplies UCRT/API sets; this client needs release CRT only,
  # without debug CRT, MFC or OpenMP libraries.
  set(CMAKE_INSTALL_UCRT_LIBRARIES FALSE)
  set(CMAKE_INSTALL_MFC_LIBRARIES FALSE)
  set(CMAKE_INSTALL_OPENMP_LIBRARIES FALSE)
  include(InstallRequiredSystemLibraries)
  set(UTEN_MSVC_CRT_DIR "")
  foreach(runtime IN LISTS CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
    get_filename_component(runtime_name "${runtime}" NAME)
    if(runtime_name STREQUAL "msvcp140.dll")
      get_filename_component(UTEN_MSVC_CRT_DIR "${runtime}" DIRECTORY)
      break()
    endif()
  endforeach()
  string(TOLOWER "${UTEN_MSVC_CRT_DIR}" runtime_directory_lower)
  if(NOT runtime_directory_lower MATCHES "/vc/redist/.*[/]microsoft[.]vc[0-9]+[.]crt$")
    message(FATAL_ERROR "The selected MSVC toolchain has no official release CRT redistributable folder. Install its Visual C++ runtime redistributables.")
  endif()
  get_filename_component(runtime_arch_directory "${UTEN_MSVC_CRT_DIR}" DIRECTORY)
  get_filename_component(runtime_arch "${runtime_arch_directory}" NAME)
  string(TOLOWER "${runtime_arch}" runtime_arch)
  if(runtime_arch STREQUAL "x64")
    set(runtime_machine "6486")
    set(runtime_pe_magic "0b02")
  elseif(runtime_arch STREQUAL "arm64")
    set(runtime_machine "64aa")
    set(runtime_pe_magic "0b02")
  elseif(runtime_arch STREQUAL "x86")
    set(runtime_machine "4c01")
    set(runtime_pe_magic "0b01")
  else()
    message(FATAL_ERROR "Unsupported MSVC CRT architecture: ${runtime_arch}")
  endif()
  if(NOT runtime_arch STREQUAL CMAKE_MSVC_ARCH OR
      (DEFINED FLUTTER_TARGET_PLATFORM AND NOT FLUTTER_TARGET_PLATFORM STREQUAL "windows-${runtime_arch}"))
    message(FATAL_ERROR "MSVC CRT architecture differs from the Flutter/compiler target: ${runtime_arch}")
  endif()
  set(runtime_core msvcp140.dll vcruntime140.dll)
  # x86 does not use the x64/ARM64 exception-handling helper.
  if(NOT runtime_arch STREQUAL "x86")
    list(APPEND runtime_core vcruntime140_1.dll)
  endif()
  foreach(runtime_name IN LISTS runtime_core)
    if(NOT EXISTS "${UTEN_MSVC_CRT_DIR}/${runtime_name}")
      message(FATAL_ERROR "Required MSVC CRT is missing: ${UTEN_MSVC_CRT_DIR}/${runtime_name}")
    endif()
  endforeach()
  file(GLOB UTEN_MSVC_CRT_DLLS CONFIGURE_DEPENDS LIST_DIRECTORIES FALSE
    "${UTEN_MSVC_CRT_DIR}/*.dll")
  foreach(runtime IN LISTS UTEN_MSVC_CRT_DLLS)
    get_filename_component(runtime_name "${runtime}" NAME)
    string(TOLOWER "${runtime_name}" runtime_name_lower)
    if(runtime_name_lower MATCHES "^((msvcp|vcruntime|msvcr|concrt|vcomp|mfc|mfcm)[0-9]+(_[0-9]+)?u?d(_[^.]+)?|ucrtbased)[.]dll$")
      message(FATAL_ERROR "Debug MSVC CRT cannot be distributed: ${runtime}")
    endif()
    file(SIZE "${runtime}" runtime_size)
    file(READ "${runtime}" runtime_dos LIMIT 64 HEX)
    string(LENGTH "${runtime_dos}" runtime_dos_length)
    if(NOT runtime_dos_length EQUAL 128 OR NOT runtime_dos MATCHES "^4d5a")
      message(FATAL_ERROR "Invalid MSVC CRT PE header: ${runtime}")
    endif()
    string(SUBSTRING "${runtime_dos}" 120 2 offset_0)
    string(SUBSTRING "${runtime_dos}" 122 2 offset_1)
    string(SUBSTRING "${runtime_dos}" 124 2 offset_2)
    string(SUBSTRING "${runtime_dos}" 126 2 offset_3)
    math(EXPR runtime_pe_offset "0x${offset_3}${offset_2}${offset_1}${offset_0}")
    math(EXPR runtime_last_header_offset "${runtime_size} - 26")
    if(runtime_pe_offset LESS 64 OR runtime_pe_offset GREATER runtime_last_header_offset)
      message(FATAL_ERROR "MSVC CRT PE header leaves the file: ${runtime}")
    endif()
    file(READ "${runtime}" runtime_pe OFFSET ${runtime_pe_offset} LIMIT 26 HEX)
    string(SUBSTRING "${runtime_pe}" 8 4 actual_machine)
    string(SUBSTRING "${runtime_pe}" 48 4 actual_magic)
    if(NOT runtime_pe MATCHES "^50450000" OR NOT actual_machine STREQUAL runtime_machine
        OR NOT actual_magic STREQUAL runtime_pe_magic)
      message(FATAL_ERROR "MSVC CRT is not a ${runtime_arch} release PE: ${runtime}")
    endif()
    file(SHA256 "${runtime}" runtime_sha256)
    # Missing or replaced redist inputs after configuration must fail install,
    # rather than silently emitting a different/incomplete employee runtime.
    install(CODE "
      if(CMAKE_INSTALL_CONFIG_NAME MATCHES \"^(Profile|Release)$\")
        if(NOT EXISTS \"${runtime}\")
          message(FATAL_ERROR \"Configured MSVC CRT disappeared: ${runtime}\")
        endif()
        file(SHA256 \"${runtime}\" actual_runtime_sha256)
        if(NOT actual_runtime_sha256 STREQUAL \"${runtime_sha256}\")
          message(FATAL_ERROR \"Configured MSVC CRT changed; reconfigure before installing: ${runtime}\")
        endif()
      endif()
      " COMPONENT Runtime)
  endforeach()
  install(FILES ${UTEN_MSVC_CRT_DLLS} DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    CONFIGURATIONS Profile;Release COMPONENT Runtime)
  list(LENGTH UTEN_MSVC_CRT_DLLS runtime_dll_count)
  message(STATUS "App-local MSVC ${runtime_arch} CRT: ${runtime_dll_count} DLLs from ${UTEN_MSVC_CRT_DIR}")
endif()

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

# Trusted updater is installed with the bootstrap client. Update ZIPs exclude
# this directory and cannot replace the script that is applying the release.
install(FILES "runner/client_updater.ps1"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/client_updater" COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
