set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)

set(SPIRV_REFLECT_STATIC_LIB  ON  CACHE INTERNAL "")
set(SPIRV_REFLECT_EXECUTABLE  OFF CACHE INTERNAL "")
set(SPIRV_REFLECT_BUILD_TESTS OFF CACHE INTERNAL "")
set(SPIRV_REFLECT_EXAMPLES    OFF CACHE INTERNAL "")
set(SPIRV_REFLECT_INSTALL     OFF CACHE INTERNAL "")

find_package(PkgConfig REQUIRED)
find_package(Eigen3 CONFIG REQUIRED)
find_package(nlohmann_json CONFIG REQUIRED)
find_package(argparse CONFIG REQUIRED)

if(NOT qjs_DIR)
    foreach(_prefix IN LISTS CMAKE_PREFIX_PATH)
        set(_quickjs_config_dir "${_prefix}/lib/cmake/quickjs")
        if(EXISTS "${_quickjs_config_dir}/qjsConfig.cmake")
            set(qjs_DIR "${_quickjs_config_dir}" CACHE PATH "Path to qjsConfig.cmake")
            break()
        endif()
    endforeach()
endif()

if(NOT qjs_DIR)
    find_path(_quickjs_include_dir
        NAMES quickjs.h
        PATHS ${CMAKE_PREFIX_PATH}
        PATH_SUFFIXES include include/quickjs)
    if(_quickjs_include_dir)
        if(_quickjs_include_dir MATCHES "/include/quickjs$")
            get_filename_component(_quickjs_prefix "${_quickjs_include_dir}/../.." ABSOLUTE)
        else()
            get_filename_component(_quickjs_prefix "${_quickjs_include_dir}/.." ABSOLUTE)
        endif()

        set(_quickjs_config_dir "${_quickjs_prefix}/lib/cmake/quickjs")
        if(EXISTS "${_quickjs_config_dir}/qjsConfig.cmake")
            set(qjs_DIR "${_quickjs_config_dir}" CACHE PATH "Path to qjsConfig.cmake")
        endif()
    endif()
endif()

find_package(qjs CONFIG REQUIRED)
find_package(glslang CONFIG REQUIRED)

function(promote_imported_target target_name)
    if(TARGET ${target_name})
        get_target_property(_is_imported ${target_name} IMPORTED)
        if(_is_imported)
            set_property(TARGET ${target_name} PROPERTY IMPORTED_GLOBAL TRUE)
        endif()
    endif()
endfunction()

promote_imported_target(Eigen3::Eigen)
promote_imported_target(nlohmann_json::nlohmann_json)
promote_imported_target(qjs)
promote_imported_target(qjs::qjs)
promote_imported_target(glslang::glslang)
promote_imported_target(glslang::SPIRV)

add_subdirectory(glad)
add_subdirectory(spirv_reflect EXCLUDE_FROM_ALL)

if(TARGET nlohmann_json::nlohmann_json AND NOT TARGET nlohmann_json)
    add_library(nlohmann_json INTERFACE)
    target_link_libraries(nlohmann_json INTERFACE nlohmann_json::nlohmann_json)
endif()

if(TARGET qjs AND NOT TARGET quickjs::quickjs)
    add_library(quickjs::quickjs ALIAS qjs)
elseif(TARGET qjs::qjs AND NOT TARGET quickjs::quickjs)
    add_library(quickjs::quickjs ALIAS qjs::qjs)
endif()

if(TARGET glslang::glslang AND NOT TARGET glslang)
    add_library(glslang ALIAS glslang::glslang)
endif()

if(TARGET glslang::SPIRV AND NOT TARGET SPIRV)
    add_library(SPIRV ALIAS glslang::SPIRV)
endif()

add_library(miniaudio INTERFACE)
target_include_directories(miniaudio SYSTEM INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/miniaudio)
