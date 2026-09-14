cmake_minimum_required(VERSION 3.14)
project(wescene-renderer)

if(APPLE)
    enable_language(OBJCXX)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Restrict to Clang. The renderer + tests rely on Clang-specific behaviour
# (clang-format style, sanitizer flags wired in src/CMakeLists.txt, and
# observed glslang/FetchContent quirks) and we have no CI matrix for GCC.
# Override with -DWAYWALLEN_ALLOW_NONCLANG=ON if you know what you're doing.
if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang" AND NOT WAYWALLEN_ALLOW_NONCLANG)
    message(FATAL_ERROR
        "wescene-renderer requires Clang (got ${CMAKE_CXX_COMPILER_ID}). "
        "Re-run cmake with `-DCMAKE_CXX_COMPILER=clang++ -DCMAKE_C_COMPILER=clang`, "
        "or pass -DWAYWALLEN_ALLOW_NONCLANG=ON to bypass this check.")
endif()

find_package(PkgConfig REQUIRED)

set(_wescene_is_top_level OFF)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(_wescene_is_top_level ON)
endif()

include_directories(SYSTEM third_party)
add_subdirectory(third_party)

link_libraries(Eigen3::Eigen)

# Test suite — gated by BUILD_TESTS. Include CTest so
# gtest_discover_tests / add_test inside tests/ register with ctest.
set(_wescene_build_tests_default ${_wescene_is_top_level})
option(BUILD_TESTS "Build the wescene-renderer test suite" ${_wescene_build_tests_default})

set(_wescene_rust_shader_ffi_default OFF)
if(DEFINED RUST_SHADER_STATICLIB AND NOT "${RUST_SHADER_STATICLIB}" STREQUAL "")
    set(_wescene_rust_shader_ffi_default ON)
    if(NOT TARGET wescene_rust_shader)
        add_library(wescene_rust_shader INTERFACE IMPORTED GLOBAL)
        set_target_properties(
            wescene_rust_shader
            PROPERTIES INTERFACE_LINK_DEPENDS "${RUST_SHADER_STATICLIB}")
        if(APPLE)
            target_link_options(
                wescene_rust_shader
                INTERFACE "LINKER:-force_load,${RUST_SHADER_STATICLIB}")
        else()
            target_link_options(
                wescene_rust_shader
                INTERFACE
                    "LINKER:--whole-archive"
                    "${RUST_SHADER_STATICLIB}"
                    "LINKER:--no-whole-archive")
        endif()
    endif()
endif()
option(
    RUST_SHADER_FFI
    "Compile the Rust shader bridge against externally resolved rs_shader_* symbols"
    ${_wescene_rust_shader_ffi_default})

add_subdirectory(src)

if(BUILD_TESTS)
    include(CTest)
    add_subdirectory(tests)
endif()

set(_wescene_build_waywallen_default ${_wescene_is_top_level})
if(APPLE OR NOT _wescene_is_top_level)
    set(_wescene_build_waywallen_default OFF)
endif()
option(BUILD_WAYWALLEN "Build the waywallen-renderer executable" ${_wescene_build_waywallen_default})
if(BUILD_WAYWALLEN)
    add_subdirectory(waywallen)
endif()

set(_wescene_build_qml_default OFF)
option(BUILD_QML "Build the QML helper library" ${_wescene_build_qml_default})
if(BUILD_QML)
    find_package(Qt6 COMPONENTS Gui Quick Qml REQUIRED)

    set(CMAKE_AUTOMOC ON) 
    set(CMAKE_AUTORCC ON) 
    set(CMAKE_AUTOUIC ON)

    add_library(${PROJECT_NAME}-qml
    STATIC
        qml_helper/SceneBackend.cpp
        qml_helper/glExtra.cpp
    )
    target_link_libraries(${PROJECT_NAME}-qml
    PUBLIC
        Qt::Quick
        Qt::Gui
        glad
        ${PROJECT_NAME}
    )
    target_include_directories(${PROJECT_NAME}-qml PUBLIC qml_helper third_party)

    set(CMAKE_AUTOMOC OFF) 
    set(CMAKE_AUTORCC OFF) 
    set(CMAKE_AUTOUIC OFF) 
endif()
