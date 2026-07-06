cmake_minimum_required(VERSION 3.4.1)

project(panorama_stitcher_library VERSION 0.0.1 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)

# OpenCV Android SDK is required for the C++ Stitcher API.
# Preferred portable setup for another machine:
#   set OPENCV_ANDROID_SDK=C:/path/to/OpenCV-android-sdk
if(DEFINED ENV{OPENCV_ANDROID_SDK})
  set(OpenCV_DIR "$ENV{OPENCV_ANDROID_SDK}/sdk/native/jni")
elseif(NOT DEFINED OpenCV_DIR)
  set(OpenCV_DIR "C:/Users/asus/Downloads/opencv-4.9.0-android-sdk/OpenCV-android-sdk/sdk/native/jni")
endif()

find_package(OpenCV REQUIRED)

add_library(panorama_stitcher SHARED "panorama_stitcher.cpp")
target_link_libraries(panorama_stitcher ${OpenCV_LIBS} log)