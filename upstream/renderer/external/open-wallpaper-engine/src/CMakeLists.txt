find_package(OpenGL REQUIRED)
find_package(Threads REQUIRED)
find_package(Freetype REQUIRED)
pkg_check_modules(LZ4 REQUIRED IMPORTED_TARGET liblz4)
pkg_check_modules(AVFORMAT REQUIRED IMPORTED_TARGET libavformat)
pkg_check_modules(AVCODEC REQUIRED IMPORTED_TARGET libavcodec)
pkg_check_modules(AVUTIL REQUIRED IMPORTED_TARGET libavutil)
pkg_check_modules(SWRESAMPLE REQUIRED IMPORTED_TARGET libswresample)

option(ENABLE_RENDERDOC "Build with renderdoc api" OFF)

if(ENABLE_RENDERDOC)
  add_compile_definitions(ENABLE_RENDERDOC_API=1)
endif()

include(TestBigEndian)
test_big_endian(ENDIAN)
if(ENDIAN)
  add_compile_definitions(WP_BIG_ENDIAN)
endif()

if(APPLE)
  find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)
  find_library(AUDIO_TOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
  find_library(AUDIO_UNIT_FRAMEWORK AudioUnit REQUIRED)
  find_library(CORE_AUDIO_FRAMEWORK CoreAudio REQUIRED)
  find_library(CORE_TEXT_FRAMEWORK CoreText REQUIRED)
  find_library(CORE_GRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
  find_library(CORE_MEDIA_FRAMEWORK CoreMedia REQUIRED)
  find_library(CORE_VIDEO_FRAMEWORK CoreVideo REQUIRED)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_library(IOSURFACE_FRAMEWORK IOSurface REQUIRED)
  find_library(METAL_FRAMEWORK Metal REQUIRED)
  find_library(VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)
endif()

set(warn_opts
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wno-unused-variable
    CACHE INTERNAL "")

include_directories(.)

set(PLATFORM_APPLE_SOURCES)
if(APPLE)
  list(APPEND PLATFORM_APPLE_SOURCES
       Platform/Apple/FfmpegVideoInterop.mm
       Platform/Apple/SceneWallpaperBindings.mm)
endif()

add_subdirectory(Fs)
add_subdirectory(Utils)
add_subdirectory(Audio)
add_subdirectory(Scene)
add_subdirectory(Looper)
add_subdirectory(Vulkan)
add_subdirectory(Scene/Timer)
add_subdirectory(Scene/Particle)
add_subdirectory(Scene/VulkanRender)
add_subdirectory(Scene/RenderGraph)

add_library(
  ${PROJECT_NAME} STATIC
  Presentation/WallpaperScaling.cpp
  Scene/WPJson.cpp
  Scene/WPPkgFs.cpp
  Type.cpp
  Runtime/DynamicValue.cpp
  Runtime/SceneRuntimeContext.cpp
  Runtime/SceneSettingResolver.cpp
  Runtime/ScriptedDynamicValue.cpp
  Shader/RustShaderBridge.cpp
  Text/SystemFontResolver.cpp
  Text/TextLayer.cpp
  Scripting/ScriptEngine.cpp
  Scene/Parse/wpscene/WPImageObject.cpp
  Scene/Parse/wpscene/WPParticleObject.cpp
  Scene/Parse/wpscene/WPMaterial.cpp
  Scene/Parse/wpscene/WPScene.cpp
  Scene/Parse/wpscene/WPLightObject.cpp
  Scene/Parse/WPParticleParser.cpp
  Scene/Parse/WPShaderParser.cpp
  Scene/Parse/WPSceneParser.cpp
  Scene/WPShaderValueUpdater.cpp
  Scene/Parse/WPTexImageParser.cpp
  Scene/Parse/WPSoundParser.cpp
  Scene/Parse/WPMdlParser.cpp
  Scene/Parse/WPPuppet.cpp
  Project/ProjectManifest.cpp
  Project/ProjectProperties.cpp
  Runtime/VirtualAssetRegistry.cpp
  Video/FfmpegVideoTextureSource.cpp
  ${PLATFORM_APPLE_SOURCES}
  SceneSourceResolver.cpp
  Scene/SceneWallpaper.cpp)

add_library(wescene::renderer ALIAS ${PROJECT_NAME})

set(InteralLib
    wpAudio
    wpLooper
    wpVulkanRender
    wpFs
    wpScene
    wpVulkan
    wpRGraph
    wpParticle
    wpTimer)

target_link_libraries(
  ${PROJECT_NAME}
  PUBLIC wpUtils
  PRIVATE ${InteralLib} nlohmann_json::nlohmann_json quickjs::quickjs PkgConfig::LZ4
          Freetype::Freetype
          PkgConfig::AVFORMAT
          PkgConfig::AVCODEC
          PkgConfig::AVUTIL
          PkgConfig::SWRESAMPLE
          ${CMAKE_THREAD_LIBS_INIT} ${CMAKE_DL_LIBS})

if(APPLE)
  target_link_libraries(
    ${PROJECT_NAME}
    PUBLIC
      ${CORE_AUDIO_FRAMEWORK}
      ${AUDIO_TOOLBOX_FRAMEWORK}
      ${AUDIO_UNIT_FRAMEWORK}
      ${CORE_MEDIA_FRAMEWORK}
      ${CORE_TEXT_FRAMEWORK}
      ${CORE_VIDEO_FRAMEWORK}
      ${ACCELERATE_FRAMEWORK}
      ${FOUNDATION_FRAMEWORK}
      ${IOSURFACE_FRAMEWORK}
      ${METAL_FRAMEWORK}
      ${VIDEOTOOLBOX_FRAMEWORK})
endif()

target_include_directories(${PROJECT_NAME} PUBLIC . Swapchain)
set_target_properties(${PROJECT_NAME} PROPERTIES
  OBJCXX_STANDARD 20
  OBJCXX_STANDARD_REQUIRED YES)
target_compile_options(${PROJECT_NAME} PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
if(BUILD_TESTS)
  target_compile_definitions(${PROJECT_NAME} PUBLIC WESCENE_BUILD_TESTS=1)
endif()
if(RUST_SHADER_FFI)
  target_compile_definitions(${PROJECT_NAME} PUBLIC WESCENE_HAS_RUST_SHADER_FFI=1)
endif()
if(TARGET wescene_rust_shader)
  target_link_libraries(${PROJECT_NAME} PUBLIC wescene_rust_shader)
endif()
set_property(TARGET ${PROJECT_NAME} PROPERTY POSITION_INDEPENDENT_CODE ON)
