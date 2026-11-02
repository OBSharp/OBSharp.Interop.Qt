cmake_minimum_required(VERSION 3.20)
project(OBSharp.Interop.Qt.Native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 自动下载并配置 Qt6（内部会自己读取 .version 并去 GitHub 下载）
include(cmake/obs-deps.cmake)

# 进入真正的编译目标
add_subdirectory(src/OBSharp.Interop.Qt.Native)