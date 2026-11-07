# =========================================================================
# OBSharp Qt Source Generator
#
# 用法：在 obs-deps.cmake 之后 include 本文件。
#
# 可选配置变量（在 include 本文件之前设置）：
#   OBSHARP_QT_MODULES            Qt 模块列表（不带 Qt 前缀）
#   OBSHARP_QT_INCLUDE_DIR        Qt 头文件根目录
#   OBSHARP_CLANG_TARGET_TRIPLE   Clang target triple
#   OBSHARP_SOURCEGEN_NATIVE_ONLY 仅生成非托管源码（ON/OFF）
#
# 也可在配置时用 -D 覆盖：
#   OBSHARP_MINIMAL_INCLUDES  按类最小化 include（默认 ON）
#   OBSHARP_RELATIVE_INCLUDES 生成相对 include（默认 ON）
#   OBSHARP_BATCH_SIZE        每 N 个类合并一个 .cpp（默认 1）
#
# 生成器版本由项目根目录的 dotnet-tools.json 固定，本文件要求
# OBSharp.Interop.NativeBindGenerator 0.0.1-alpha.5 及以上：该版本起
# --minimal-includes / --relative-includes / --batch-size 三个选项与
# <native-name>.pch.h 预编译头都是标配产物，无需再做能力探测或自行拼装。
#
# 例如：
#   set(OBSHARP_SOURCEGEN_NATIVE_ONLY OFF)
#   include("${CMAKE_CURRENT_LIST_DIR}/code-gen.cmake")
# =========================================================================

# 由项目根目录的 CMakeLists.txt 负责声明 cmake_minimum_required。
# 防止被重复 include 时重复执行生成器。
include_guard(GLOBAL)

# -------------------------------------------------------------------------
# 配置
# -------------------------------------------------------------------------

if(NOT DEFINED OBSHARP_QT_MODULES)
  set(OBSHARP_QT_MODULES
    Concurrent
    Core
    Designer
    Gui
    Multimedia
    MultimediaWidgets
    Network
    OpenGL
    OpenGLWidgets
    SpatialAudio
    Svg
    SvgWidgets
    UiTools
    Widgets
    Xml
  )
endif()

if(NOT OBSHARP_QT_MODULES)
  message(FATAL_ERROR "OBSharp: 至少需要指定一个 Qt 模块。")
endif()

foreach(_module IN LISTS OBSHARP_QT_MODULES)
  if(NOT _module MATCHES "^[A-Za-z][A-Za-z0-9]*$")
    message(FATAL_ERROR "OBSharp: 非法的 Qt 模块名：${_module}")
  endif()
endforeach()

if(NOT DEFINED OBSHARP_SOURCEGEN_NATIVE_ONLY)
  set(OBSHARP_SOURCEGEN_NATIVE_ONLY OFF)
endif()

# 本文件预期位于项目根目录的 cmake/ 目录。
get_filename_component(_obsharp_project_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(_obsharp_native_project "${_obsharp_project_root}/src/OBSharp.Interop.Qt.Native")
set(_obsharp_managed_project "${_obsharp_project_root}/src/OBSharp.Interop.Qt")
set(_obsharp_native_name "OBSharp.Interop.Qt.Native")
set(_obsharp_native_output "${_obsharp_native_project}/Generated")
set(_obsharp_managed_output "${_obsharp_managed_project}/Generated")

if(NOT IS_DIRECTORY "${_obsharp_native_project}")
  message(FATAL_ERROR
    "OBSharp: 未找到非托管项目目录：${_obsharp_native_project}")
endif()

if(NOT OBSHARP_SOURCEGEN_NATIVE_ONLY AND
   NOT IS_DIRECTORY "${_obsharp_managed_project}")
  message(FATAL_ERROR
    "OBSharp: 未找到托管项目目录：${_obsharp_managed_project}")
endif()

if(NOT EXISTS "${_obsharp_project_root}/dotnet-tools.json")
  message(FATAL_ERROR
    "OBSharp: 未找到 dotnet-tools.json：${_obsharp_project_root}")
endif()

# -------------------------------------------------------------------------
# Qt include 目录解析
# -------------------------------------------------------------------------

# 兼容四种 Qt 安装布局：
#   常规安装：  <root>/include/QtCore/QtCore
#   直接根目录：<root>/QtCore/QtCore（OBSHARP_QT_INCLUDE_DIR 指向 include 目录）
#   macOS framework：<root>/lib/QtCore.framework/Headers/QtCore
#   Linux 发行版：/usr/include/<multiarch>/qt6/QtCore/QtCore（由 Qt6 CMake 包解析）
set(_obsharp_qt_include "")
set(_obsharp_qt_frameworks_dir "")
set(_obsharp_qt_resolved FALSE)
set(_obsharp_qt_root_candidates "")

# 探测一个候选根目录。命中后写入 _obsharp_qt_include 与
# _obsharp_qt_frameworks_dir，并把 _obsharp_qt_resolved 置为 TRUE。
#
# 注意：macOS 的 obs-deps 是「混合布局」——QtCore/QtGui 等模块以
# framework 形式放在 <root>/lib 下，而 QtUiPlugin 等少数模块只有
# 普通的 <root>/include/Qt<Module> 目录，不存在对应 framework。
# 因此两个根目录需要同时记录，不能互斥。
function(_obsharp_qt_probe_root _candidate)
  if("${_candidate}" STREQUAL "")
    return()
  endif()

  get_filename_component(_root "${_candidate}" ABSOLUTE)
  string(REGEX REPLACE "[/\\\\]+$" "" _root "${_root}")

  # Qt6::Core 的 include 属性在 framework 布局下直接指向
  # .../<Module>.framework/Headers，需要回退到 framework 的父目录。
  if(_root MATCHES "^(.*)/[A-Za-z0-9]+\\.framework/Headers$")
    set(_root "${CMAKE_MATCH_1}")
  elseif(_root MATCHES "^(.*)/[A-Za-z0-9]+\\.framework/Versions/[^/]+/Headers$")
    set(_root "${CMAKE_MATCH_1}")
  elseif(_root MATCHES "^(.*)/[A-Za-z0-9]+\\.framework$")
    set(_root "${CMAKE_MATCH_1}")
  endif()

  set(_probe_include "")
  set(_probe_frameworks_dir "")

  if(EXISTS "${_root}/QtCore/QtCore")
    set(_probe_include "${_root}")
  endif()

  if(EXISTS "${_root}/include/QtCore/QtCore")
    set(_probe_include "${_root}/include")
  endif()

  if(IS_DIRECTORY "${_root}/lib/QtCore.framework")
    set(_probe_frameworks_dir "${_root}/lib")
    # 混合布局：framework 之外仍可能有 <root>/include/Qt<Module>。
    if(NOT _probe_include AND IS_DIRECTORY "${_root}/include")
      set(_probe_include "${_root}/include")
    endif()
  elseif(IS_DIRECTORY "${_root}/QtCore.framework")
    set(_probe_frameworks_dir "${_root}")
  endif()

  if(_probe_include OR _probe_frameworks_dir)
    set(_obsharp_qt_include "${_probe_include}" PARENT_SCOPE)
    set(_obsharp_qt_frameworks_dir "${_probe_frameworks_dir}" PARENT_SCOPE)
    set(_obsharp_qt_resolved TRUE PARENT_SCOPE)
  endif()
endfunction()

# 解析某个 Qt 模块的头文件目录。
# framework 布局下 Headers 是指向 Versions/Current/Headers 的符号链接，
# 解压工具未必保留符号链接，因此这里依次尝试真实目录。
function(_obsharp_qt_module_dir _module _out_var)
  set(_module_name "Qt${_module}")
  set(_candidates "")

  if(_obsharp_qt_frameworks_dir)
    list(APPEND _candidates
      "${_obsharp_qt_frameworks_dir}/${_module_name}.framework/Headers"
      "${_obsharp_qt_frameworks_dir}/${_module_name}.framework/Versions/A/Headers"
      "${_obsharp_qt_frameworks_dir}/${_module_name}.framework/Versions/Current/Headers"
    )
  endif()

  if(_obsharp_qt_include)
    list(APPEND _candidates "${_obsharp_qt_include}/${_module_name}")
  endif()

  foreach(_dir IN LISTS _candidates)
    if(EXISTS "${_dir}/${_module_name}")
      set("${_out_var}" "${_dir}" PARENT_SCOPE)
      return()
    endif()
  endforeach()

  set("${_out_var}" "" PARENT_SCOPE)
endfunction()

if(DEFINED OBSHARP_QT_INCLUDE_DIR AND
   NOT "${OBSHARP_QT_INCLUDE_DIR}" STREQUAL "")
  # 显式配置优先：该变量既可以指向 Qt 安装根目录，也可以直接指向 include 目录。
  _obsharp_qt_probe_root("${OBSHARP_QT_INCLUDE_DIR}")
  if(NOT _obsharp_qt_resolved)
    message(FATAL_ERROR
      "OBSharp: OBSHARP_QT_INCLUDE_DIR 不是有效的 Qt 头文件目录："
      "${OBSHARP_QT_INCLUDE_DIR}")
  endif()
else()
  # 1) 由 obs-deps.cmake 或上层配置显式提供的候选根目录。
  if(DEFINED OBSHARP_QT_ROOT AND NOT "${OBSHARP_QT_ROOT}" STREQUAL "")
    list(APPEND _obsharp_qt_root_candidates "${OBSHARP_QT_ROOT}")
  endif()

  # 兼容尚未更新的 obs-deps.cmake。
  if(DEFINED _target_qt AND NOT "${_target_qt}" STREQUAL "")
    list(APPEND _obsharp_qt_root_candidates "${_target_qt}")
  endif()

  # 兼容变量名或 include 顺序发生变化的情况。
  if(DEFINED QT_INCLUDE_DIRS)
    list(APPEND _obsharp_qt_root_candidates ${QT_INCLUDE_DIRS})
  endif()

  # 2) 先探测显式提供的候选根目录：显式配置的优先级最高。
  foreach(_candidate IN LISTS _obsharp_qt_root_candidates)
    if(_obsharp_qt_resolved)
      break()
    endif()
    _obsharp_qt_probe_root("${_candidate}")
  endforeach()

  # 3) 向 Qt6 的 CMake 包查询头文件目录。
  #    这是 Linux 发行版与 macOS framework 布局下最可靠的来源：
  #    发行版 Qt 的头文件在 /usr/include/<multiarch>/qt6，
  #    仅凭 <prefix>/include 无法推断，必须依赖 Qt6::Core 的目标属性。
  if(NOT _obsharp_qt_resolved)
    find_package(Qt6 QUIET COMPONENTS Core)
    if(TARGET Qt6::Core)
      get_target_property(_obsharp_qt_core_include_dirs
        Qt6::Core INTERFACE_INCLUDE_DIRECTORIES)

      if(_obsharp_qt_core_include_dirs)
        foreach(_candidate IN LISTS _obsharp_qt_core_include_dirs)
          if(_candidate MATCHES "^\\$<")
            # 生成器表达式（如 $<BUILD_INTERFACE:...>）无法在配置期求值。
            continue()
          endif()

          _obsharp_qt_probe_root("${_candidate}")

          # Qt6::Core 的 include 属性通常直接指向 .../qt6 或 .../include，
          # 此时其父目录才是可用于本脚本的根目录。
          if(NOT _obsharp_qt_resolved)
            get_filename_component(_parent "${_candidate}" DIRECTORY)
            _obsharp_qt_probe_root("${_parent}")
          endif()

          if(_obsharp_qt_resolved)
            break()
          endif()
        endforeach()
      endif()

      # framework 布局下 Qt6::Core 未必暴露头文件目录，
      # 可直接从导入目标的位置属性反推 framework 所在目录。
      if(NOT _obsharp_qt_resolved)
        foreach(_property IN ITEMS IMPORTED_LOCATION_RELEASE IMPORTED_LOCATION)
          get_target_property(_obsharp_qt_core_location
            Qt6::Core "${_property}")
          if(_obsharp_qt_core_location AND
             _obsharp_qt_core_location MATCHES "^(.*)/QtCore\\.framework/")
            _obsharp_qt_probe_root("${CMAKE_MATCH_1}")
            if(_obsharp_qt_resolved)
              break()
            endif()
          endif()
        endforeach()
      endif()
    endif()
  endif()

  # 4) 最后从 .deps 中按目录名倒序探测（兼容 include 与 framework 布局）。
  if(NOT _obsharp_qt_resolved)
    file(GLOB _obsharp_deps_qt_candidates
      LIST_DIRECTORIES TRUE
      "${_obsharp_project_root}/.deps/obs-deps-qt6-*"
    )
    list(SORT _obsharp_deps_qt_candidates ORDER DESCENDING)

    foreach(_candidate IN LISTS _obsharp_deps_qt_candidates)
      if(_obsharp_qt_resolved)
        break()
      endif()
      _obsharp_qt_probe_root("${_candidate}")
    endforeach()
  endif()
endif()

if(NOT _obsharp_qt_resolved)
  message(FATAL_ERROR
    "OBSharp: 未找到有效的 Qt 头文件目录。"
    " 请设置 OBSHARP_QT_INCLUDE_DIR，或确认 obs-deps.cmake 已准备好 Qt。"
    " 已尝试的候选根目录：${_obsharp_qt_root_candidates}")
endif()

if(_obsharp_qt_frameworks_dir)
  _obsharp_qt_module_dir("Core" _obsharp_qt_core_module_dir)
else()
  set(_obsharp_qt_core_module_dir "${_obsharp_qt_include}/QtCore")
endif()

if(NOT IS_DIRECTORY "${_obsharp_qt_core_module_dir}" OR
   NOT EXISTS "${_obsharp_qt_core_module_dir}/QtCore")
  message(FATAL_ERROR
    "OBSharp: 未找到有效的 Qt 头文件目录。"
    " 请设置 OBSHARP_QT_INCLUDE_DIR，或确认 obs-deps.cmake 已准备好 Qt。"
    " 当前 include 目录：'${_obsharp_qt_include}'"
    " 当前 framework 目录：'${_obsharp_qt_frameworks_dir}'")
endif()

if(_obsharp_qt_include AND IS_DIRECTORY "${_obsharp_qt_include}")
  get_filename_component(_obsharp_qt_include
    "${_obsharp_qt_include}" REALPATH)
endif()

if(_obsharp_qt_frameworks_dir)
  get_filename_component(_obsharp_qt_frameworks_dir
    "${_obsharp_qt_frameworks_dir}" REALPATH)
  message(STATUS "OBSharp: Qt framework 目录：${_obsharp_qt_frameworks_dir}")
else()
  message(STATUS "OBSharp: Qt 头文件目录：${_obsharp_qt_include}")
endif()

# -------------------------------------------------------------------------
# 收集各模块的公共头文件
# -------------------------------------------------------------------------

# 排除私有实现、平台专属与 global 头，只保留对外公开的 API 头文件。
set(_obsharp_public_header_exclude
  "(_p|_impl|_win|_mac|_platform)\\.h$|^q.*global\\.h$|^q(t_)?(win|mac|darwin|ios|android|unix|bsd|freebsd|wasm|nx|platform).*\\.h$"
)

# 判定某个头文件能否独立用于公开绑定生成。
#
# Linux 发行版的 Qt 会额外安装一批由 D-Bus 在构建期生成的头文件
# （如 QtGui/bus_interface.h、cache_adaptor.h 等），它们属于 AT-SPI
# 无障碍桥的内部实现，却位于公开 include 目录中。这些头文件会
# #include <QtGui/private/...>，而 Qt 私有头文件由单独的
# qt6-base-private-dev 包提供；obs-deps 的 Windows/macOS 预编译包
# 则根本不包含这些文件。
#
# 为了让三端生成的绑定保持一致，这里统一跳过依赖私有头文件的头文件。
function(_obsharp_header_is_public_api _header _result_var)
  file(READ "${_header}" _header_content)

  if(_header_content MATCHES
     "#[ \t]*include[ \t]*[<\"]Qt[A-Za-z0-9]*/private/")
    set("${_result_var}" FALSE PARENT_SCOPE)
  else()
    set("${_result_var}" TRUE PARENT_SCOPE)
  endif()
endfunction()

set(_obsharp_generated_modules "")
set(_obsharp_header_arguments "")

foreach(_module IN LISTS OBSHARP_QT_MODULES)
  set(_module_name "Qt${_module}")
  _obsharp_qt_module_dir("${_module}" _module_dir)

  if(NOT _module_dir)
    message(WARNING
      "OBSharp: 跳过 ${_module_name}：未找到该模块的头文件目录。")
    continue()
  endif()

  set(_umbrella_header "${_module_dir}/${_module_name}")

  if(NOT EXISTS "${_umbrella_header}")
    message(WARNING
      "OBSharp: 跳过 ${_module_name}：伞头文件不存在（${_umbrella_header}）。")
    continue()
  endif()

  file(GLOB _module_headers LIST_DIRECTORIES FALSE
    "${_module_dir}/*.h")
  list(SORT _module_headers)

  set(_public_headers "")
  set(_skipped_private_headers "")
  foreach(_header IN LISTS _module_headers)
    get_filename_component(_header_name "${_header}" NAME)
    if(_header_name MATCHES "${_obsharp_public_header_exclude}")
      continue()
    endif()

    _obsharp_header_is_public_api("${_header}" _header_is_public_api)
    if(NOT _header_is_public_api)
      list(APPEND _skipped_private_headers "${_header_name}")
      continue()
    endif()

    list(APPEND _public_headers "${_header}")
  endforeach()

  if(_skipped_private_headers)
    message(STATUS
      "OBSharp: ${_module_name} 跳过依赖 Qt 私有头文件的文件："
      "${_skipped_private_headers}")
  endif()

  if(NOT _public_headers)
    message(WARNING
      "OBSharp: 跳过 ${_module_name}：没有可用的公共头文件。")
    continue()
  endif()

  list(APPEND _obsharp_generated_modules "${_module}")

  foreach(_header IN LISTS _public_headers)
    list(APPEND _obsharp_header_arguments "--header" "${_header}")
  endforeach()
endforeach()

if(NOT _obsharp_generated_modules)
  message(FATAL_ERROR
    "OBSharp: 没有找到任何可生成的 Qt 模块。"
    " include 目录：'${_obsharp_qt_include}'"
    " framework 目录：'${_obsharp_qt_frameworks_dir}'")
endif()

# -------------------------------------------------------------------------
# 构造 Clang 参数
# -------------------------------------------------------------------------

if(CMAKE_CXX_EXTENSIONS)
  set(_obsharp_clang_standard "gnu++${CMAKE_CXX_STANDARD}")
else()
  set(_obsharp_clang_standard "c++${CMAKE_CXX_STANDARD}")
endif()

set(_obsharp_clang_arguments
  "-std=${_obsharp_clang_standard}"
)

if(_obsharp_qt_include)
  list(APPEND _obsharp_clang_arguments
    "-I" "${_obsharp_qt_include}")
endif()

if(_obsharp_qt_frameworks_dir)
  # framework 布局下 Qt 头文件使用 <QtCore/...> 形式互相引用。
  list(APPEND _obsharp_clang_arguments
    "-F" "${_obsharp_qt_frameworks_dir}")
endif()

if(DEFINED OBSHARP_CLANG_TARGET_TRIPLE AND
   NOT "${OBSHARP_CLANG_TARGET_TRIPLE}" STREQUAL "")
  list(APPEND _obsharp_clang_arguments
    "--target=${OBSHARP_CLANG_TARGET_TRIPLE}")
elseif(APPLE AND CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
  # macOS 交叉编译时显式指定目标架构，避免 Clang 按宿主机架构解析 Qt 头文件。
  list(APPEND _obsharp_clang_arguments "--target=arm64-apple-darwin")
elseif(APPLE AND CMAKE_OSX_ARCHITECTURES STREQUAL "x86_64")
  list(APPEND _obsharp_clang_arguments "--target=x86_64-apple-darwin")
endif()

if(APPLE)
  find_program(_obsharp_xcrun xcrun)
  if(NOT _obsharp_xcrun)
    message(FATAL_ERROR "OBSharp: 找不到 xcrun，无法定位 macOS SDK。")
  endif()

  execute_process(
    COMMAND "${_obsharp_xcrun}" --sdk macosx --show-sdk-path
    RESULT_VARIABLE _xcrun_sdk_result
    OUTPUT_VARIABLE _obsharp_sdk_path
    ERROR_VARIABLE _xcrun_sdk_error
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  if(NOT _xcrun_sdk_result EQUAL 0 OR
     "${_obsharp_sdk_path}" STREQUAL "")
    message(FATAL_ERROR
      "OBSharp: 无法通过 xcrun 定位 macOS SDK：${_xcrun_sdk_error}")
  endif()

  execute_process(
    COMMAND "${_obsharp_xcrun}" --sdk macosx clang -print-resource-dir
    RESULT_VARIABLE _xcrun_resource_result
    OUTPUT_VARIABLE _obsharp_clang_resource_dir
    ERROR_VARIABLE _xcrun_resource_error
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  if(NOT _xcrun_resource_result EQUAL 0 OR
     "${_obsharp_clang_resource_dir}" STREQUAL "")
    message(FATAL_ERROR
      "OBSharp: 无法通过 xcrun 定位 Clang 资源头文件：${_xcrun_resource_error}")
  endif()

  list(APPEND _obsharp_clang_arguments
    "-isysroot" "${_obsharp_sdk_path}"
    "-resource-dir" "${_obsharp_clang_resource_dir}"
  )

elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  find_program(_obsharp_clang clang)
  if(NOT _obsharp_clang)
    message(FATAL_ERROR
      "OBSharp: 找不到 clang，请先安装 Clang。")
  endif()

  execute_process(
    COMMAND "${_obsharp_clang}" -print-resource-dir
    RESULT_VARIABLE _clang_resource_result
    OUTPUT_VARIABLE _obsharp_clang_resource_dir
    ERROR_VARIABLE _clang_resource_error
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  if(NOT _clang_resource_result EQUAL 0 OR
     "${_obsharp_clang_resource_dir}" STREQUAL "")
    message(FATAL_ERROR
      "OBSharp: 无法定位 Clang 资源头文件：${_clang_resource_error}")
  endif()

  list(APPEND _obsharp_clang_arguments
    "-resource-dir" "${_obsharp_clang_resource_dir}")

elseif(WIN32)
  # Clang 解析 MSVC STL 时需要 MSVC 兼容选项。
  list(APPEND _obsharp_clang_arguments
    "-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH"
    "-fms-compatibility"
    "-fms-extensions"
  )

  set(_obsharp_msvc_include_dirs "")

  # 优先使用当前构建环境提供的头文件搜索路径。
  # VS Developer Command Prompt 和由其启动的 Ninja 通常会设置 INCLUDE。
  if(DEFINED ENV{INCLUDE} AND NOT "$ENV{INCLUDE}" STREQUAL "")
    file(TO_CMAKE_PATH "$ENV{INCLUDE}" _obsharp_msvc_include_dirs)
    list(FILTER _obsharp_msvc_include_dirs INCLUDE REGEX ".+")
  elseif(CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    # Visual Studio Generator 不保证 CMake 进程本身具有 INCLUDE 环境变量。
    # MSVC 编译器通常位于：<MSVC_ROOT>/bin/Hostx64/x64/cl.exe
    get_filename_component(
      _obsharp_msvc_compiler_dir
      "${CMAKE_CXX_COMPILER}"
      DIRECTORY
    )
    file(TO_CMAKE_PATH
      "${_obsharp_msvc_compiler_dir}"
      _obsharp_msvc_compiler_dir
    )

    if(_obsharp_msvc_compiler_dir MATCHES
       "^(.*)/bin/Host[^/]+/[^/]+$")
      set(_obsharp_msvc_root "${CMAKE_MATCH_1}")
      set(_obsharp_msvc_include "${_obsharp_msvc_root}/include")

      if(IS_DIRECTORY "${_obsharp_msvc_include}")
        list(APPEND _obsharp_msvc_include_dirs "${_obsharp_msvc_include}")
      endif()
    endif()
  endif()

  if(NOT _obsharp_msvc_include_dirs)
    message(FATAL_ERROR
      "OBSharp: 无法定位 MSVC STL 头文件。"
      " 请使用 MSVC 工具链配置 CMake，或在配置环境中提供 INCLUDE。")
  endif()

  set(_obsharp_valid_msvc_include_dirs "")
  foreach(_include_dir IN LISTS _obsharp_msvc_include_dirs)
    if(IS_DIRECTORY "${_include_dir}")
      list(APPEND _obsharp_valid_msvc_include_dirs "${_include_dir}")
      list(APPEND _obsharp_clang_arguments "-isystem" "${_include_dir}")
    endif()
  endforeach()
  set(_obsharp_msvc_include_dirs "${_obsharp_valid_msvc_include_dirs}")

  if(NOT _obsharp_msvc_include_dirs)
    message(FATAL_ERROR
      "OBSharp: INCLUDE 和 CMAKE_CXX_COMPILER 均未提供有效的 MSVC STL 头文件目录。")
  endif()

  # 确定 Windows SDK 版本：优先使用 Visual Studio Generator 提供的版本，
  # 其次使用 Windows SDK 开发环境提供的 WindowsSDKVersion。
  set(_obsharp_windows_sdk_version "")
  if(DEFINED CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION AND
     NOT "${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}" STREQUAL "")
    set(_obsharp_windows_sdk_version
      "${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}")
  elseif(DEFINED ENV{WindowsSDKVersion} AND
         NOT "$ENV{WindowsSDKVersion}" STREQUAL "")
    set(_obsharp_windows_sdk_version "$ENV{WindowsSDKVersion}")
  endif()

  # 查找 Windows SDK 安装根目录。
  # 优先使用显式 CMake 配置，其次读取开发环境变量，最后查询 SDK 安装注册表。
  set(_obsharp_windows_sdk_root "")

  if(DEFINED OBSHARP_WINDOWS_SDK_ROOT AND
     NOT "${OBSHARP_WINDOWS_SDK_ROOT}" STREQUAL "")
    file(TO_CMAKE_PATH
      "${OBSHARP_WINDOWS_SDK_ROOT}"
      _obsharp_windows_sdk_root
    )
  elseif(DEFINED ENV{WindowsSdkDir} AND
         NOT "$ENV{WindowsSdkDir}" STREQUAL "")
    file(TO_CMAKE_PATH
      "$ENV{WindowsSdkDir}"
      _obsharp_windows_sdk_root
    )
  else()
    # Windows SDK 安装程序会在 KitsRoot10 中登记实际安装位置。
    get_filename_component(
      _obsharp_windows_sdk_root
      "[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots;KitsRoot10]"
      REALPATH
    )
  endif()

  if(NOT _obsharp_windows_sdk_root OR
     NOT _obsharp_windows_sdk_version)
    message(FATAL_ERROR
      "OBSharp: 无法确定 Windows SDK。"
      " 请确认已安装 Windows 10/11 SDK，且 CMake 能读取其安装注册表项。")
  endif()

  # WindowsSDKVersion 环境变量通常以反斜杠结尾。
  string(REGEX REPLACE "[/\\\\]+$" ""
    _obsharp_windows_sdk_version
    "${_obsharp_windows_sdk_version}"
  )

  # 兼容 WindowsSdkDir 指向 SDK 根目录或其上级目录的情况。
  string(REGEX REPLACE "[/\\\\]+$" ""
    _obsharp_windows_sdk_root
    "${_obsharp_windows_sdk_root}"
  )

  set(_obsharp_windows_sdk_include
    "${_obsharp_windows_sdk_root}/Include/${_obsharp_windows_sdk_version}")

  if(NOT IS_DIRECTORY "${_obsharp_windows_sdk_include}")
    set(_obsharp_windows_sdk_candidate
      "${_obsharp_windows_sdk_root}/Windows Kits/10/Include/${_obsharp_windows_sdk_version}")

    if(IS_DIRECTORY "${_obsharp_windows_sdk_candidate}")
      set(_obsharp_windows_sdk_root
        "${_obsharp_windows_sdk_root}/Windows Kits/10")
      set(_obsharp_windows_sdk_include
        "${_obsharp_windows_sdk_candidate}")
    endif()
  endif()

  if(NOT IS_DIRECTORY "${_obsharp_windows_sdk_include}")
    message(FATAL_ERROR
      "OBSharp: Windows SDK include 目录不存在：${_obsharp_windows_sdk_include}"
      "\nSDK 根目录：${_obsharp_windows_sdk_root}"
      "\nSDK 版本：${_obsharp_windows_sdk_version}"
      "\n请检查 Windows SDK 安装状态及 KitsRoot10 注册表项。")
  endif()

  foreach(_kit IN ITEMS ucrt shared um winrt cppwinrt)
    set(_kit_include "${_obsharp_windows_sdk_include}/${_kit}")
    if(IS_DIRECTORY "${_kit_include}")
      list(APPEND _obsharp_clang_arguments "-isystem" "${_kit_include}")
    endif()
  endforeach()

  foreach(_kit IN ITEMS ucrt shared um)
    if(NOT IS_DIRECTORY "${_obsharp_windows_sdk_include}/${_kit}")
      message(FATAL_ERROR
        "OBSharp: Windows SDK 缺少必要目录：${_obsharp_windows_sdk_include}/${_kit}")
    endif()
  endforeach()
endif()

# -------------------------------------------------------------------------
# 生成器选项
# -------------------------------------------------------------------------

# 生成器由 dotnet-tools.json 固定版本，`dotnet tool run` 的 `--`
# 用于分隔 dotnet 自身的参数与工具参数。
set(_obsharp_generator_execute_command
  dotnet tool run OBSharp.Interop.NativeBindGenerator --)

# 旧版生成器没有 --minimal-includes / --relative-includes / --batch-size，
# 也没有 <native-name>.pch.h 产物；本文件直接假定 0.0.1-alpha.5 及以上，
# 缺选项时由生成器自己报错，不再做运行时能力探测。
option(OBSHARP_MINIMAL_INCLUDES
  "每个类只包含实际用到的头文件（大幅减少单 TU 头文件数量）"
  ON)
option(OBSHARP_RELATIVE_INCLUDES
  "生成的 include 使用相对路径（便于编译缓存跨机器复用）"
  ON)
set(OBSHARP_BATCH_SIZE "1"
  CACHE STRING
  "每 N 个类合并为一个翻译单元（1 表示每个类一个 .cpp）")

if(NOT "${OBSHARP_BATCH_SIZE}" MATCHES "^[0-9]+$")
  message(FATAL_ERROR
    "OBSharp: OBSHARP_BATCH_SIZE 必须是正整数：'${OBSHARP_BATCH_SIZE}'")
endif()
if(OBSHARP_BATCH_SIZE LESS 1)
  message(FATAL_ERROR
    "OBSharp: OBSHARP_BATCH_SIZE 必须大于等于 1：'${OBSHARP_BATCH_SIZE}'")
endif()

set(_obsharp_generator_feature_arguments "")

if(OBSHARP_MINIMAL_INCLUDES)
  list(APPEND _obsharp_generator_feature_arguments "--minimal-includes")
endif()

if(OBSHARP_RELATIVE_INCLUDES)
  list(APPEND _obsharp_generator_feature_arguments "--relative-includes")
endif()

if(OBSHARP_BATCH_SIZE GREATER 1)
  list(APPEND _obsharp_generator_feature_arguments
    "--batch-size" "${OBSHARP_BATCH_SIZE}")
endif()

set(_obsharp_generator_arguments
  "--namespace"
  "OBSharp.Interop.Qt"
  "--library-name"
  "${_obsharp_native_name}"
  "--cpp-redirect"
  "--qt"
  "--csharp-output"
  "${_obsharp_managed_output}"
  "--native-output"
  "${_obsharp_native_output}"
  "--native-name"
  "${_obsharp_native_name}"
  "--return-string-marshaller"
  "OBSharp.Interop.Qt.NoFreeUTF8StringMarshaller"
  "--nullable-handle-marshaller"
  "OBSharp.Interop.Qt.NullableSafeHandleMarshaller"
)
list(APPEND _obsharp_generator_arguments ${_obsharp_generator_feature_arguments})
# `--` 之后的内容原样交给 libclang，必须放在全部生成器选项之后。
list(APPEND _obsharp_generator_arguments "--")

# -------------------------------------------------------------------------
# 生成响应文件
# -------------------------------------------------------------------------

# 响应文件的词法规则（由 System.CommandLine 的 ResponseFileTokenizer 决定，
# 已用生成器 0.0.1-alpha.5 实测）：
#   * 每行是一个参数，行首行尾空白被裁剪，空行被忽略；
#   * 含空格的参数可用双引号包裹，但引号只做"去壳"，**不参与转义**——
#     引号内的反斜杠原样保留，`\"` 不等于转义引号，而是"结束字符串"；
#   * 因此 Windows 路径必须原样书写，不能把反斜杠加倍，否则路径会变成
#     `C:\\dir\\file.h` 而找不到头文件；
#   * 参数内部不能出现双引号；单引号不具任何特殊含义。
# 这里据此把含空格的参数整体加引号，并直接拒绝含双引号的参数。
set(_obsharp_rsp_lines "")

foreach(_argument IN LISTS _obsharp_header_arguments
                            _obsharp_generator_arguments
                            _obsharp_clang_arguments)
  if(_argument MATCHES "\"")
    message(FATAL_ERROR
      "OBSharp: 生成器参数不能包含双引号（响应文件不支持转义）：'${_argument}'")
  endif()

  if(_argument MATCHES "[ \t]")
    list(APPEND _obsharp_rsp_lines "\"${_argument}\"")
  else()
    list(APPEND _obsharp_rsp_lines "${_argument}")
  endif()
endforeach()

string(REPLACE ";" "\n" _obsharp_rsp_content "${_obsharp_rsp_lines}")
string(RANDOM LENGTH 12 ALPHABET 0123456789abcdef _obsharp_rsp_id)
set(_obsharp_response_file
  "${CMAKE_CURRENT_BINARY_DIR}/OBSharp.Qt.Bindings.${_obsharp_rsp_id}.rsp")
file(WRITE "${_obsharp_response_file}" "${_obsharp_rsp_content}\n")

# -------------------------------------------------------------------------
# 清理输出并执行生成器
# -------------------------------------------------------------------------

if(OBSHARP_SOURCEGEN_NATIVE_ONLY)
  file(REMOVE_RECURSE "${_obsharp_native_output}")
  file(MAKE_DIRECTORY "${_obsharp_native_output}")
else()
  file(REMOVE_RECURSE
    "${_obsharp_managed_output}"
    "${_obsharp_native_output}")
  file(MAKE_DIRECTORY
    "${_obsharp_managed_output}"
    "${_obsharp_native_output}")
endif()

message(STATUS "OBSharp: 正在生成 Qt 绑定（模块：${_obsharp_generated_modules}）")

execute_process(
  COMMAND ${_obsharp_generator_execute_command}
    "@${_obsharp_response_file}"
  WORKING_DIRECTORY "${_obsharp_project_root}"
  RESULT_VARIABLE _obsharp_generator_result
  ENCODING ANSI
)

file(REMOVE "${_obsharp_response_file}")

if(NOT _obsharp_generator_result EQUAL 0)
  message(FATAL_ERROR
    "OBSharp: NativeBindGenerator 生成失败，退出码：${_obsharp_generator_result}")
endif()

# -------------------------------------------------------------------------
# 校验预编译头（PCH）
# -------------------------------------------------------------------------
# PCH 由生成器自己产出：${_obsharp_native_name}.pch.h，内容是全部模块公共
# 头文件的 include 列表，顺序与每个类 .cpp 的 preamble 完全一致。生成器
# 在 --cpp-redirect 下无条件写出该文件，因此这里不再自行拼装——两处都写
# 会因目录层级不同而解析到不同的同名头文件副本（MSVC C2084/C2995）。
#
# cpp_marshaller.hpp 不在 PCH 中：它只有几 KB，让每个 TU 自己包含的成本
# 可以忽略，而放进 PCH 会让附属库子目录解析到另一份副本。
set(_obsharp_pch_header
  "${_obsharp_native_output}/${_obsharp_native_name}.pch.h")

if(NOT EXISTS "${_obsharp_pch_header}")
  message(FATAL_ERROR
    "OBSharp: 生成器没有输出预编译头：${_obsharp_pch_header}"
    "\n请确认 OBSharp.Interop.NativeBindGenerator 为 0.0.1-alpha.5 或更高版本"
    "（见 dotnet-tools.json），并已执行 dotnet tool restore。")
endif()

message(STATUS "OBSharp: 预编译头：${_obsharp_pch_header}")

# -------------------------------------------------------------------------
# 生成 CMake 模块清单
# -------------------------------------------------------------------------

set(_obsharp_manifest
  "set(OBSHARP_QT_GENERATED_MODULES\n")
foreach(_module IN LISTS _obsharp_generated_modules)
  string(APPEND _obsharp_manifest "  ${_module}\n")
endforeach()
string(APPEND _obsharp_manifest ")\n\n")

# 同时把 PCH 路径交给 Native CMakeLists，避免它自己猜测产物名。
string(APPEND _obsharp_manifest
  "set(OBSHARP_QT_PCH_HEADER\n  \"${_obsharp_pch_header}\")\n")

file(WRITE
  "${_obsharp_native_output}/generated-modules.cmake"
  "${_obsharp_manifest}")

if(NOT OBSHARP_SOURCEGEN_NATIVE_ONLY)
  message(STATUS "OBSharp: 托管绑定输出：${_obsharp_managed_output}")
endif()
message(STATUS "OBSharp: 非托管绑定输出：${_obsharp_native_output}")
