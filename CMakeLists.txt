cmake_minimum_required(VERSION 3.20)

project(OBSharp.Interop.Qt.Native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 准备 Qt6 依赖
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/obs-deps.cmake")

# 生成 Qt 绑定源码
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/code-gen.cmake")

# 配置 Native 编译目标
add_subdirectory(src/OBSharp.Interop.Qt.Native)