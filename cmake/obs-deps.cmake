# =========================================================================
# OBSharp 依赖管理：只负责下载、校验、解压 Qt6，并向全局暴露路径。
# 不需要预先安装任何 C++ 环境，只要有网络即可。
# =========================================================================

# 防止被重复 include 时重复执行生成器。
include_guard(GLOBAL)

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(STATUS "OBSharp: Linux 平台使用系统包 (qt6-base-dev 等) ，跳过自动下载")
  return()
endif()

# 1. 读取根目录的 .version
set(_obsdeps_version_file "${CMAKE_CURRENT_LIST_DIR}/../.version")
if(NOT EXISTS "${_obsdeps_version_file}")
  message(FATAL_ERROR "OBSharp: 找不到版本文件 ${_obsdeps_version_file}")
endif()
file(READ "${_obsdeps_version_file}" _obsdeps_version)
string(STRIP "${_obsdeps_version}" _obsdeps_version)
message(STATUS "OBSharp: 依赖版本读取为 ${_obsdeps_version}")

# 2. 判定目标架构（结合你的 CMakePresets.json）
set(_target_arch "x64")
if(CMAKE_GENERATOR_PLATFORM MATCHES "ARM64" OR CMAKE_VS_PLATFORM_NAME MATCHES "ARM64")
  set(_target_arch "arm64")
elseif(CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
  set(_target_arch "arm64")
endif()

# 3. 从 GitHub API 获取 Release 信息并缓存
set(_gh_json "${CMAKE_CURRENT_BINARY_DIR}/obs-deps-${_obsdeps_version}.json")
if(NOT EXISTS "${_gh_json}")
  message(STATUS "OBSharp: GitHub API 缓存不存在，将会下载...")
  set(_need_download_json TRUE)
else()
  file(READ "${_gh_json}" _gh_json_content)
  if(NOT _gh_json_content)
    message(STATUS "OBSharp: GitHub API 缓存为空，将会重新下载...")
    set(_need_download_json TRUE)
  endif()
endif()

if(_need_download_json)
  message(STATUS "OBSharp: 从 GitHub API 获取 Release 信息...")
  file(DOWNLOAD "https://api.github.com/repos/obsproject/obs-deps/releases/tags/${_obsdeps_version}" "${_gh_json}" STATUS _dl_status)
  list(GET _dl_status 0 _dl_code)
  if(NOT _dl_code EQUAL 0)
    message(FATAL_ERROR "OBSharp: 请求 GitHub API 失败，请检查网络。")
  endif()
endif()
file(READ "${_gh_json}" _gh_json_content)

# 4. 内部函数：执行具体的下载、校验和解压
function(_obsharp_download_qt6 _arch _out_dir)
  if(WIN32)
    set(_filename "windows-deps-qt6-${_obsdeps_version}-${_arch}.zip")
  elseif(APPLE)
    set(_filename "macos-deps-qt6-${_obsdeps_version}-${_arch}.tar.xz")
  endif()

  # 从 JSON 里提取 digest
  string(JSON _count LENGTH "${_gh_json_content}" "assets")
  set(_sha "")
  if(_count GREATER 0)
    math(EXPR _max "${_count}-1")
    foreach(_i RANGE 0 ${_max})
      string(JSON _name GET "${_gh_json_content}" "assets" ${_i} "name")
      if(_name STREQUAL _filename)
        string(JSON _digest GET "${_gh_json_content}" "assets" ${_i} "digest")
        string(REPLACE "sha256:" "" _sha "${_digest}")
        break()
      endif()
    endforeach()
  endif()

  if(NOT _sha)
    message(FATAL_ERROR "OBSharp: 在 Release 中找不到 ${_filename} 的哈希校验值。")
  endif()

  # 区分缓存目录和依赖解压目录
  set(_cache_dir "${CMAKE_CURRENT_SOURCE_DIR}/.cache")
  set(_deps_dir "${CMAKE_CURRENT_SOURCE_DIR}/.deps")
  
  file(MAKE_DIRECTORY "${_cache_dir}")
  file(MAKE_DIRECTORY "${_deps_dir}")
  
  set(_archive "${_cache_dir}/${_filename}")
  set(_dest "${_deps_dir}/obs-deps-qt6-${_obsdeps_version}-${_arch}")

  if(EXISTS "${_dest}/lib/cmake/Qt6/Qt6Config.cmake")
    message(STATUS "OBSharp: Qt6 ${_arch} 依赖已解压，跳过下载")
  else()
    set(_need_download TRUE)
    
    # 【新增】：如果缓存包存在，先计算它的 SHA256 并比对
    if(EXISTS "${_archive}")
      message(STATUS "OBSharp: 发现 .cache 中已有压缩包，正在校验 SHA256...")
      file(SHA256 "${_archive}" _actual_hash)
      if(_actual_hash STREQUAL _sha)
        set(_need_download FALSE)
        message(STATUS "OBSharp: 缓存包校验通过，跳过下载。")
      else()
        message(WARNING "OBSharp: 缓存包校验失败！实际哈希: ${_actual_hash}，期望: ${_sha}")
        message(STATUS "OBSharp: 正在删除损坏的缓存包并准备重新下载...")
        file(REMOVE "${_archive}")
      endif()
    endif()

    if(_need_download)
      message(STATUS "OBSharp: 开始下载 ${_filename} (首次约需 30-60MB，请耐心等待)...")
      file(DOWNLOAD "https://github.com/obsproject/obs-deps/releases/download/${_obsdeps_version}/${_filename}" "${_archive}"
           EXPECTED_HASH SHA256=${_sha} STATUS _dl_status SHOW_PROGRESS TLS_VERIFY ON)
      list(GET _dl_status 0 _dl_code)
      if(NOT _dl_code EQUAL 0)
        list(GET _dl_status 1 _dl_msg)
        file(REMOVE "${_archive}")
        message(FATAL_ERROR "OBSharp: 下载失败：${_dl_msg}")
      endif()
    endif()

    message(STATUS "OBSharp: 正在解压 ${_filename} 到 .deps ...")
    # 先解压到 .deps 下的临时目录，避免解压失败留下残余
    set(_unpack "${_dest}.unpack")
    file(REMOVE_RECURSE "${_unpack}")
    file(ARCHIVE_EXTRACT INPUT "${_archive}" DESTINATION "${_unpack}")
    file(REMOVE_RECURSE "${_dest}")
    file(RENAME "${_unpack}" "${_dest}")
  endif()
  
  set(${_out_dir} "${_dest}" PARENT_SCOPE)
endfunction()

# 5. Windows ARM64 交叉编译需要额外的 x64 Host Tools
if(WIN32 AND _target_arch STREQUAL "arm64")
  _obsharp_download_qt6("x64" _host_qt)
  set(QT_HOST_PATH "${_host_qt}" CACHE PATH "Qt6 host tools for arm64" FORCE)
  set(QT_REQUIRE_HOST_PATH_CHECK TRUE CACHE STRING "Qt Host Tools Check Required" FORCE)
  message(STATUS "OBSharp: 已配置交叉编译环境，QT_HOST_PATH = ${_host_qt}")
endif()

# 6. 下载目标架构并加入 CMAKE_PREFIX_PATH
_obsharp_download_qt6("${_target_arch}" _target_qt)
set(OBSHARP_QT_ROOT "${_target_qt}")
list(APPEND CMAKE_PREFIX_PATH "${_target_qt}")
message(STATUS "OBSharp: Qt6 目标路径已加入 OBSHARP_QT_ROOT: ${_target_qt}")
message(STATUS "OBSharp: Qt6 目标路径已加入 CMAKE_PREFIX_PATH: ${_target_qt}")