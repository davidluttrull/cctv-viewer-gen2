cmake_minimum_required(VERSION 3.19)

# Standalone on purpose. This is a measurement tool, not a component of CCTV
# Viewer, and the top-level CMakeLists knows nothing about it -- so it can be
# deleted wholesale once it has answered its question, without unpicking the
# real build. Configure it through ios/make-probe.sh.
project(cctv-probe LANGUAGES C OBJC)

if(NOT DEFINED FFMPEG_PREFIX)
    message(FATAL_ERROR
        "FFMPEG_PREFIX is not set. Build the static FFmpeg first:\n"
        "    sh ios/make-ffmpeg.sh\n"
        "then pass -DFFMPEG_PREFIX=build-ios/ffmpeg/prefix/<target>")
endif()

if(NOT EXISTS "${FFMPEG_PREFIX}/lib/libavcodec.a")
    message(FATAL_ERROR "no libavcodec.a under ${FFMPEG_PREFIX}/lib")
endif()

set(STREAMS "${CMAKE_CURRENT_SOURCE_DIR}/streams.json")
if(NOT EXISTS "${STREAMS}")
    message(FATAL_ERROR
        "ios/probe/streams.json is missing. Generate it from the saved macOS "
        "layout:\n    sh ios/probe/make-streams.sh")
endif()

set(PROBE_EXECUTABLE cctv-probe)
set(PROBE_BUNDLE_ID "org.cctv-viewer.probe")
set(PROBE_MIN_OS "${CMAKE_OSX_DEPLOYMENT_TARGET}")

# Device and simulator bundles must declare which platform they are for, and
# getting it wrong is one of the ways an install fails with no useful message.
if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
    set(PROBE_PLATFORM "iPhoneSimulator")
else()
    set(PROBE_PLATFORM "iPhoneOS")
endif()

configure_file(Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

add_executable(cctv-probe MACOSX_BUNDLE probe.m)

# Automatic signing asks Apple for an App ID matching PRODUCT_BUNDLE_IDENTIFIER
# and issues a profile for that string. It has to be the same identifier the
# Info.plist declares, or the build signs one bundle ID and the device refuses
# to install another -- so both come from PROBE_BUNDLE_ID and nowhere else.
set_target_properties(cctv-probe PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${PROBE_BUNDLE_ID}"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${PROBE_BUNDLE_ID}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)

target_include_directories(cctv-probe PRIVATE "${FFMPEG_PREFIX}/include")

# Static archives, so link order is load-bearing: each one must appear before
# the libraries it depends on. avdevice -> avfilter -> avformat -> avcodec ->
# swresample/swscale -> avutil is the dependency order FFmpeg itself documents.
foreach(lib avdevice avfilter avformat avcodec swresample swscale avutil)
    list(APPEND FFMPEG_ARCHIVES "${FFMPEG_PREFIX}/lib/lib${lib}.a")
endforeach()

target_link_libraries(cctv-probe PRIVATE
    ${FFMPEG_ARCHIVES}
    z                       # --enable-zlib; zlib ships inside the iOS SDK
    "-framework UIKit"
    "-framework Foundation"
    "-framework CoreFoundation"
    "-framework CoreGraphics"
    "-framework QuartzCore"
    "-framework CoreMedia"      # VideoToolbox sample buffers
    "-framework CoreVideo"      # the CVPixelBuffers the probe counts
    "-framework VideoToolbox"   # the thing being measured
    "-framework AudioToolbox"   # libavdevice/libavcodec audio paths
    "-framework AVFoundation"   # libavdevice's iOS capture input
)

# iOS bundles are flat: the bundle root *is* the resource directory, so under
# the Makefile generator the Resources/ subdirectory MACOSX_PACKAGE_LOCATION
# creates is a place NSBundle never looks, and URLForResource: returns nil at
# runtime with no hint as to why. Copy it to the root instead.
#
# The Xcode generator needs the opposite treatment, for two reasons. Its
# $<TARGET_BUNDLE_DIR:> expands to a path containing a literal
# ${EFFECTIVE_PLATFORM_NAME} that nothing substitutes, so the POST_BUILD copy
# silently creates a sibling directory called Release${EFFECTIVE_PLATFORM_NAME}
# and the bundle ships without streams.json -- the probe then dies with its own
# "no streams.json in the bundle" message. And a POST_BUILD copy happens after
# Xcode has signed, so even landing it correctly would leave a bundle whose
# signature does not cover it, which a device refuses to install. Xcode's
# Resources phase avoids both: on iOS it copies to the bundle root, and it runs
# before signing.
if(CMAKE_GENERATOR STREQUAL "Xcode")
    target_sources(cctv-probe PRIVATE "${STREAMS}")
    set_source_files_properties("${STREAMS}" PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources")
else()
    add_custom_command(TARGET cctv-probe POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${STREAMS}" "$<TARGET_BUNDLE_DIR:cctv-probe>/streams.json"
        COMMENT "Copying streams.json into the app bundle"
        VERBATIM)
endif()
