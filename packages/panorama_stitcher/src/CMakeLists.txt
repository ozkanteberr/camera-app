cmake_minimum_required(VERSION 3.4.1)

project(panorama_stitcher_library VERSION 0.0.1 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)

set(OPENCV_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/opencv")
set(OPENCV_LIB "${OPENCV_ROOT}/libs/${ANDROID_ABI}/libopencv_java4.so")

if(NOT EXISTS "${OPENCV_LIB}")
  message(FATAL_ERROR "OpenCV library not found for ABI ${ANDROID_ABI}: ${OPENCV_LIB}")
endif()

add_library(opencv_java4 SHARED IMPORTED)
set_target_properties(opencv_java4 PROPERTIES IMPORTED_LOCATION "${OPENCV_LIB}")

add_library(panorama_stitcher SHARED "panorama_stitcher.cpp")
target_include_directories(panorama_stitcher PRIVATE "${OPENCV_ROOT}/include")
target_link_libraries(panorama_stitcher opencv_java4 log)