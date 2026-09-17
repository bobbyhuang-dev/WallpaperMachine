#Test suite for wescene - renderer.
#
#Strategy : a single gtest binary indexes workshop/* once via DumpWorkshop
# (no on-disk fixtures) and uses TEST_P fixtures to register one test
# instance per (category, version) pair observed in the corpus. Each
# instance asserts category-specific structural invariants on the slice
# of assets matching its parameter.
#
# Adding a new workshop with a previously-unseen pkg/tex/mdl version
# automatically grows the test matrix on the next run — no allow-list
# bumps required, but the new instance must still satisfy the invariants
# in version_tests.cpp or it fails immediately.

include(FetchContent)

FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.14.0
    GIT_SHALLOW    TRUE
)
set(BUILD_GMOCK OFF CACHE INTERNAL "")
set(INSTALL_GTEST OFF CACHE INTERNAL "")
FetchContent_MakeAvailable(googletest)
include(GoogleTest)

# Shared library for the dumper + corpus index. Used by the gtest binary
# and any future ad-hoc tools.
add_library(wpdump_lib STATIC dump.cpp corpus.cpp)
target_link_libraries(
    wpdump_lib
    PUBLIC
        ${PROJECT_NAME}
        wpFs
        wpScene
        nlohmann_json::nlohmann_json
)
target_include_directories(wpdump_lib PUBLIC .)
target_compile_features(wpdump_lib PUBLIC cxx_std_20)
target_compile_definitions(
    wpdump_lib PUBLIC
    "WAYWALLEN_WORKSHOP_DIR=\"${CMAKE_SOURCE_DIR}/workshop\""
    "WAYWALLEN_FIXTURE_DIR=\"${CMAKE_CURRENT_SOURCE_DIR}/fixtures\"")

add_executable(version_tests version_tests.cpp)
target_link_libraries(version_tests PRIVATE wpdump_lib GTest::gtest_main)

add_executable(tex_schema_tests tex_schema_tests.cpp)
target_link_libraries(tex_schema_tests PRIVATE ${PROJECT_NAME} wpFs wpScene GTest::gtest_main)
target_include_directories(tex_schema_tests PRIVATE .)
target_compile_features(tex_schema_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    tex_schema_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(scene_schema_tests scene_schema_tests.cpp)
target_link_libraries(scene_schema_tests PRIVATE ${PROJECT_NAME} wpAudio wpFs wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(scene_schema_tests PRIVATE .)
target_compile_features(scene_schema_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    scene_schema_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(mdl_schema_tests mdl_schema_tests.cpp)
target_link_libraries(mdl_schema_tests PRIVATE ${PROJECT_NAME} wpFs wpScene GTest::gtest_main)
target_include_directories(mdl_schema_tests PRIVATE .)
target_compile_features(mdl_schema_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    mdl_schema_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(scene_mesh_tests scene_mesh_tests.cpp)
target_link_libraries(scene_mesh_tests PRIVATE wpScene GTest::gtest_main)
target_include_directories(scene_mesh_tests PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(scene_mesh_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    scene_mesh_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

# CLI for fixture authoring: dumps a single workshop to a JSON file.
add_executable(wpdump wpdump_main.cpp)
target_link_libraries(wpdump PRIVATE wpdump_lib)

# Per-version deep tests live in tests/version/<category>_<version>_test.cpp.
# Each is a tiny gtest TU built into the same binary so the corpus + gtest
# fixture machinery is amortised across them.
file(GLOB version_test_srcs CONFIGURE_DEPENDS "version/*_test.cpp")
if(version_test_srcs)
    add_executable(deep_version_tests ${version_test_srcs})
    target_link_libraries(deep_version_tests PRIVATE wpdump_lib GTest::gtest_main)
    target_include_directories(deep_version_tests PRIVATE .)
endif()

# Use gtest_discover_tests so each TEST_P instance becomes its own ctest
# entry, runnable individually with `ctest -R ScenePkgVersionTest`.
add_executable(
    audio_tests
    audio/audio_response_mono_test.cpp
    audio/ffmpeg_sound_stream_test.cpp
    fs/limited_binary_stream_test.cpp
    audio/sample_math_test.cpp
    audio/sound_layer_control_test.cpp)
target_link_libraries(audio_tests PRIVATE ${PROJECT_NAME} wpAudio wpFs GTest::gtest_main)
target_include_directories(audio_tests PRIVATE .)
target_compile_features(audio_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    audio_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
if(APPLE)
    add_executable(playback_gpu_test playback_gpu_test.mm)
    target_link_libraries(playback_gpu_test PRIVATE
        ${PROJECT_NAME} wpScene wpVulkan wpVulkanRender wpRGraph
        nlohmann_json::nlohmann_json GTest::gtest_main)
    target_include_directories(playback_gpu_test PRIVATE
        . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
    target_compile_features(playback_gpu_test PRIVATE cxx_std_20)
    set_target_properties(playback_gpu_test PROPERTIES
        OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(playback_gpu_test PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    gtest_discover_tests(playback_gpu_test PROPERTIES TIMEOUT 60 DISCOVERY_TIMEOUT 60)
    add_test(
        NAME audio_coreaudio_backend_config
        COMMAND
            ${CMAKE_COMMAND}
            -DHEADER=${CMAKE_SOURCE_DIR}/src/Audio/miniaudio-wrapper.hpp
            -P ${CMAKE_CURRENT_SOURCE_DIR}/audio/coreaudio_backend_config.cmake)
endif()
add_executable(shader_cache_metadata_test shader_cache_metadata_test.cpp)
target_link_libraries(shader_cache_metadata_test PRIVATE ${PROJECT_NAME} wpFs wpScene wpVulkan GTest::gtest_main)
target_include_directories(shader_cache_metadata_test PRIVATE .)
target_compile_features(shader_cache_metadata_test PRIVATE cxx_std_20)
gtest_discover_tests(
    shader_cache_metadata_test
    TEST_PREFIX shader_cache_metadata_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(shader_preprocessor_compat_test shader_preprocessor_compat_test.cpp)
target_link_libraries(shader_preprocessor_compat_test PRIVATE ${PROJECT_NAME} wpFs wpScene wpVulkan GTest::gtest_main)
target_include_directories(shader_preprocessor_compat_test PRIVATE .)
target_compile_features(shader_preprocessor_compat_test PRIVATE cxx_std_20)
gtest_discover_tests(
    shader_preprocessor_compat_test
    TEST_PREFIX shader_preprocessor_compat_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(rust_shader_bridge_test rust_shader_bridge_test.cpp)
target_link_libraries(
    rust_shader_bridge_test
    PRIVATE ${PROJECT_NAME} wpFs wpScene wpVulkan wpVulkanRender wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(rust_shader_bridge_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(rust_shader_bridge_test PRIVATE cxx_std_20)
if(DEFINED RUST_SHADER_STATICLIB AND NOT "${RUST_SHADER_STATICLIB}" STREQUAL "")
    target_link_libraries(rust_shader_bridge_test PRIVATE wescene_rust_shader)
endif()
gtest_discover_tests(
    rust_shader_bridge_test
    TEST_PREFIX rust_shader_bridge_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)

add_executable(unpack_shader_compile_smoke unpack_shader_compile_smoke.cpp)
set(UNPACK_SHADER_COMPILE_SMOKE_CORPUS_ROOT
    "/Users/molyuu/Workspace/WallpaperEngine/unpack"
    CACHE PATH "Root directory containing unpacked Wallpaper Engine workshop scenes for shader smoke tests")
set(UNPACK_SHADER_COMPILE_SMOKE_COMMON_ASSETS
    "/Users/molyuu/Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets"
    CACHE PATH "Wallpaper Engine common assets directory for shader smoke tests")
target_link_libraries(
    unpack_shader_compile_smoke
    PRIVATE ${PROJECT_NAME} wpFs wpScene wpVulkan nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(unpack_shader_compile_smoke PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(unpack_shader_compile_smoke PRIVATE cxx_std_20)
target_compile_definitions(
    unpack_shader_compile_smoke
    PRIVATE
        "UNPACK_SHADER_COMPILE_SMOKE_CORPUS_ROOT=\"${UNPACK_SHADER_COMPILE_SMOKE_CORPUS_ROOT}\""
        "UNPACK_SHADER_COMPILE_SMOKE_COMMON_ASSETS=\"${UNPACK_SHADER_COMPILE_SMOKE_COMMON_ASSETS}\"")
if(TARGET wescene_rust_shader)
    target_link_libraries(unpack_shader_compile_smoke PRIVATE wescene_rust_shader)
else()
    message(FATAL_ERROR
        "unpack_shader_compile_smoke requires the Rust shader static library target. "
        "Configure with -DRUST_SHADER_STATICLIB=<path-to-librust_shader.a>.")
endif()
gtest_discover_tests(
    unpack_shader_compile_smoke
    TEST_PREFIX unpack_shader_compile_smoke.
    PROPERTIES TIMEOUT 600
    DISCOVERY_TIMEOUT 120
)
add_executable(scenescript_sound_layer_smoke scenescript_sound_layer_smoke.cpp)
target_link_libraries(scenescript_sound_layer_smoke PRIVATE ${PROJECT_NAME} wpAudio wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(scenescript_sound_layer_smoke PRIVATE .)
target_compile_features(scenescript_sound_layer_smoke PRIVATE cxx_std_20)
gtest_discover_tests(
    scenescript_sound_layer_smoke
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(media_thumbnail_texture_smoke media_thumbnail_texture_smoke.cpp)
target_link_libraries(media_thumbnail_texture_smoke PRIVATE ${PROJECT_NAME} wpScene nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(media_thumbnail_texture_smoke PRIVATE .)
target_compile_features(media_thumbnail_texture_smoke PRIVATE cxx_std_20)
gtest_discover_tests(
    media_thumbnail_texture_smoke
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(scenescript_media_event_smoke scenescript_media_event_smoke.cpp)
target_link_libraries(scenescript_media_event_smoke PRIVATE ${PROJECT_NAME} wpScene GTest::gtest_main)
target_include_directories(scenescript_media_event_smoke PRIVATE .)
target_compile_features(scenescript_media_event_smoke PRIVATE cxx_std_20)
gtest_discover_tests(
    scenescript_media_event_smoke
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(video_texture_submission_smoke video_texture_submission_smoke.cpp)
target_link_libraries(video_texture_submission_smoke PRIVATE wpVulkan GTest::gtest_main)
target_include_directories(video_texture_submission_smoke PRIVATE
    .
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/Vulkan/include
    ${CMAKE_SOURCE_DIR}/src/Utils/include
    ${CMAKE_SOURCE_DIR}/src/Scene/include
)
target_compile_features(video_texture_submission_smoke PRIVATE cxx_std_20)
gtest_discover_tests(
    video_texture_submission_smoke
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(script_runtime_compat_test script_runtime_compat_test.cpp)
target_link_libraries(script_runtime_compat_test PRIVATE ${PROJECT_NAME} wpScene wpFs wpVulkan nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(script_runtime_compat_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(script_runtime_compat_test PRIVATE cxx_std_20)
gtest_discover_tests(
    script_runtime_compat_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
# Explicit CLI diagnostic, not registered with ctest. Never creates a surface.
add_executable(render_target_lifetime_test render_target_lifetime_test.cpp)
target_link_libraries(render_target_lifetime_test PRIVATE ${PROJECT_NAME} wpScene wpVulkanRender wpVulkan wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(render_target_lifetime_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
gtest_discover_tests(render_target_lifetime_test PROPERTIES TIMEOUT 30)

add_executable(offscreen_scene_probe offscreen_scene_probe.cpp)
target_link_libraries(offscreen_scene_probe PRIVATE ${PROJECT_NAME} wpAudio wpScene wpParticle wpFs wpVulkan wpVulkanRender wpRGraph nlohmann_json::nlohmann_json)
target_include_directories(offscreen_scene_probe PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(offscreen_scene_probe PRIVATE cxx_std_20)

# Explicit CLI diagnostic for cross-load state leaks, not registered with ctest.
add_executable(scene_reload_cycle_probe scene_reload_cycle_probe.cpp)
target_link_libraries(scene_reload_cycle_probe PRIVATE ${PROJECT_NAME} wpAudio wpScene wpParticle wpFs wpVulkan wpVulkanRender wpRGraph nlohmann_json::nlohmann_json)
target_include_directories(scene_reload_cycle_probe PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(scene_reload_cycle_probe PRIVATE cxx_std_20)

add_executable(text_object_runtime_test text_object_runtime_test.cpp)
target_link_libraries(text_object_runtime_test PRIVATE ${PROJECT_NAME} wpAudio wpScene wpFs wpVulkan wpVulkanRender wpRGraph nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(text_object_runtime_test PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(text_object_runtime_test PRIVATE cxx_std_20)
gtest_discover_tests(
    text_object_runtime_test
    TEST_PREFIX text_object_runtime_test.
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(mouse_input_test mouse_input_test.cpp)
target_link_libraries(mouse_input_test PRIVATE ${PROJECT_NAME} wpScene wpVulkan GTest::gtest_main)
target_include_directories(mouse_input_test PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(mouse_input_test PRIVATE cxx_std_20)
gtest_discover_tests(
    mouse_input_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(particle_mouse_controlpoint_test particle_mouse_controlpoint_test.cpp)
target_link_libraries(particle_mouse_controlpoint_test PRIVATE ${PROJECT_NAME} wpScene wpParticle wpAudio nlohmann_json::nlohmann_json GTest::gtest_main)
target_include_directories(particle_mouse_controlpoint_test PRIVATE .)
target_compile_features(particle_mouse_controlpoint_test PRIVATE cxx_std_20)
gtest_discover_tests(
    particle_mouse_controlpoint_test
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
add_executable(vulkan_render_batch_planner_smoke vulkan_render_batch_planner_smoke.cpp)
target_link_libraries(vulkan_render_batch_planner_smoke PRIVATE wpVulkanRender wpVulkan)
target_include_directories(vulkan_render_batch_planner_smoke PRIVATE .)
target_compile_features(vulkan_render_batch_planner_smoke PRIVATE cxx_std_20)
target_compile_options(vulkan_render_batch_planner_smoke PRIVATE -UNDEBUG)
add_test(NAME vulkan_render_batch_planner_smoke COMMAND vulkan_render_batch_planner_smoke)
add_executable(vulkan_sample_count_smoke vulkan_sample_count_smoke.cpp)
target_link_libraries(vulkan_sample_count_smoke PRIVATE ${PROJECT_NAME} wpVulkanRender wpVulkan wpScene wpRGraph GTest::gtest_main)
target_include_directories(vulkan_sample_count_smoke PRIVATE
    .
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/Vulkan/include
    ${CMAKE_SOURCE_DIR}/src/Scene/RenderGraph/include
    ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender
    ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender/include
    ${CMAKE_SOURCE_DIR}/src/Utils/include
    ${CMAKE_SOURCE_DIR}/src/Scene/include
)
target_compile_features(vulkan_sample_count_smoke PRIVATE cxx_std_20)
add_test(NAME vulkan_sample_count_smoke COMMAND vulkan_sample_count_smoke)
add_executable(rendergraph_smoke rendergraph_smoke.cpp)
target_link_libraries(rendergraph_smoke PRIVATE ${PROJECT_NAME} wpVulkanRender wpVulkan wpRGraph wpScene wpAudio wpFs)
target_include_directories(rendergraph_smoke PRIVATE . ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/src/Scene/VulkanRender)
target_compile_features(rendergraph_smoke PRIVATE cxx_std_20)
add_test(NAME rendergraph_smoke COMMAND rendergraph_smoke)
add_executable(timer_tests timer/frame_timer_test.cpp)
target_link_libraries(timer_tests PRIVATE wpTimer GTest::gtest_main)
target_include_directories(timer_tests PRIVATE . ${CMAKE_SOURCE_DIR}/src)
target_compile_features(timer_tests PRIVATE cxx_std_20)
gtest_discover_tests(
    timer_tests
    PROPERTIES TIMEOUT 30
    DISCOVERY_TIMEOUT 60
)
#gtest_discover_tests(
#    version_tests
#    PROPERTIES TIMEOUT 30
#    DISCOVERY_TIMEOUT 60
#)
if(TARGET deep_version_tests)
    gtest_discover_tests(
        deep_version_tests
        PROPERTIES TIMEOUT 30
        DISCOVERY_TIMEOUT 60
    )
endif()
