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
# 注意：obs-deps 的资产命名在各平台并不统一。
#   Windows：x64 / arm64
#   macOS：  x86_64 / arm64
if(APPLE)
  set(_target_arch "x86_64")
else()
  set(_target_arch "x64")
endif()

if(CMAKE_GENERATOR_PLATFORM MATCHES "ARM64" OR CMAKE_VS_PLATFORM_NAME MATCHES "ARM64")
  set(_target_arch "arm64")
elseif(CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
  set(_target_arch "arm64")
elseif(CMAKE_OSX_ARCHITECTURES MATCHES "x86_64")
  set(_target_arch "x86_64")
elseif(APPLE AND NOT CMAKE_OSX_ARCHITECTURES AND
       CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "arm64")
  # 未显式指定架构时按宿主机架构选择；Apple Silicon 上默认是 arm64。
  set(_target_arch "arm64")
endif()

# 3. 从 GitHub API 获取 Release 信息（含各资产的 SHA256 digest）
#
# GitHub API 对未认证请求限流为 60 次/小时/IP，而 GitHub Actions 的
# 托管运行器（尤其 macOS）共享出口 IP，很容易被整体限流，
# 表现为 "HTTP response code said error" 且退避重试无效。
# 因此这里按以下顺序取数据，任一成功即可：
#   1) 已缓存且可解析的 JSON；
#   2) 带 GITHUB_TOKEN / GH_TOKEN 的认证请求（5000 次/小时）；
#   3) 未认证请求（带退避重试），作为最后手段。
set(_gh_json "${CMAKE_CURRENT_BINARY_DIR}/obs-deps-${_obsdeps_version}.json")
set(_gh_json_valid FALSE)

if(EXISTS "${_gh_json}")
  file(READ "${_gh_json}" _gh_json_content)
  if(_gh_json_content)
    string(JSON _assets_type ERROR_VARIABLE _assets_error
      TYPE "${_gh_json_content}" "assets")
    if(NOT _assets_error AND _assets_type STREQUAL "ARRAY")
      set(_gh_json_valid TRUE)
      message(STATUS "OBSharp: 复用已缓存的 GitHub API 响应")
    else()
      message(STATUS "OBSharp: 缓存的 GitHub API 响应无效，将会重新下载...")
    endif()
  endif()
else()
  message(STATUS "OBSharp: GitHub API 缓存不存在，将会下载...")
endif()

# 收集可用的认证令牌（CI 中由 workflow 注入 GITHUB_TOKEN）。
set(_gh_auth_tokens "")
foreach(_gh_token_var IN ITEMS GITHUB_TOKEN GH_TOKEN)
  if(DEFINED ENV{${_gh_token_var}} AND
     NOT "$ENV{${_gh_token_var}}" STREQUAL "")
    list(APPEND _gh_auth_tokens "$ENV{${_gh_token_var}}")
  endif()
endforeach()

# 尝试下载一次 Release JSON；成功且内容可解析时返回 TRUE。
#
# 注意 CMake 的 HTTPHEADER 语义：每个 HTTPHEADER 关键字只接受「一个」
# header 字符串，多传的参数会被静默当作 "Unexpected argument" 丢弃。
# 因此必须为每个 header 重复写 HTTPHEADER，不能写成
# `HTTPHEADER ${header_list}`——那样只有第一个 header 生效，
# Authorization 会被丢掉，token 形同虚设（仍是 60 次/小时的匿名配额）。
# 这里通过 _obsharp_gh_download 的 ARGN 逐条展开成重复的 HTTPHEADER。
function(_obsharp_gh_download _url _out_file _out_ok_var)
  set(_header_arguments "")
  foreach(_header IN LISTS ARGN)
    list(APPEND _header_arguments HTTPHEADER "${_header}")
  endforeach()

  file(DOWNLOAD "${_url}" "${_out_file}"
    ${_header_arguments}
    STATUS _dl_status
    TLS_VERIFY ON)

  list(GET _dl_status 0 _dl_code)
  set(_ok FALSE)

  if(_dl_code EQUAL 0)
    file(READ "${_out_file}" _candidate_content)
    string(JSON _candidate_assets_type ERROR_VARIABLE _candidate_assets_error
      TYPE "${_candidate_content}" "assets")
    if(NOT _candidate_assets_error AND _candidate_assets_type STREQUAL "ARRAY")
      set(_ok TRUE)
    else()
      # 403/404 等错误响应体不是合法 Release JSON，丢弃避免误用。
      file(REMOVE "${_out_file}")
    endif()
  else()
    file(REMOVE "${_out_file}")
  endif()

  set("${_out_ok_var}" "${_ok}" PARENT_SCOPE)
endfunction()

if(NOT _gh_json_valid)
  message(STATUS "OBSharp: 从 GitHub API 获取 Release 信息...")

  set(_gh_tmp "${_gh_json}.tmp")
  set(_gh_download_attempts 4)

  foreach(_attempt RANGE 1 ${_gh_download_attempts})
    if(_gh_auth_tokens)
      # 认证请求配额充足，命中即止。
      foreach(_gh_token IN LISTS _gh_auth_tokens)
        _obsharp_gh_download(
          "https://api.github.com/repos/obsproject/obs-deps/releases/tags/${_obsdeps_version}"
          "${_gh_tmp}" _gh_download_ok
          "User-Agent: OBSharp.Interop.Qt-CMake"
          "Accept: application/vnd.github+json"
          "Authorization: Bearer ${_gh_token}")
        if(_gh_download_ok)
          file(RENAME "${_gh_tmp}" "${_gh_json}")
          set(_gh_json_valid TRUE)
          break()
        endif()
      endforeach()
      if(_gh_json_valid)
        break()
      endif()
    else()
      _obsharp_gh_download(
        "https://api.github.com/repos/obsproject/obs-deps/releases/tags/${_obsdeps_version}"
        "${_gh_tmp}" _gh_download_ok
        "User-Agent: OBSharp.Interop.Qt-CMake"
        "Accept: application/vnd.github+json")
      if(_gh_download_ok)
        file(RENAME "${_gh_tmp}" "${_gh_json}")
        set(_gh_json_valid TRUE)
        break()
      endif()
    endif()

    message(STATUS
      "OBSharp: 获取 GitHub API 失败（第 ${_attempt}/${_gh_download_attempts} 次），将重试")

    if(_attempt LESS ${_gh_download_attempts})
      # 依次退避 2/4/8 秒，避免瞬时故障直接终止配置。
      math(EXPR _gh_backoff "1 << ${_attempt}")
      execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep "${_gh_backoff}")
    endif()
  endforeach()

  if(NOT _gh_json_valid)
    message(FATAL_ERROR
      "OBSharp: 请求 GitHub API 失败。"
      " 未认证请求限流为 60 次/小时/IP，共享运行器很容易触发；"
      " 请设置环境变量 GITHUB_TOKEN 或 GH_TOKEN 后重试。"
      " 目标地址：https://api.github.com/repos/obsproject/obs-deps/releases/tags/${_obsdeps_version}")
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

  # 从 Release JSON 的 assets 中取出该资产的 sha256 digest。
  set(_sha "")
  string(JSON _count LENGTH "${_gh_json_content}" "assets")
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
    message(FATAL_ERROR
      "OBSharp: 在 obs-deps Release ${_obsdeps_version} 中找不到"
      " ${_filename} 的 SHA256 校验值。")
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