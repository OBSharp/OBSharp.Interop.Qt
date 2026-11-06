# =========================================================================
# OBSharp Qt Source Generator
#
# 用法：在 obs-deps.cmake 之后 include 本文件。
#
# 可选配置变量（在 include 本文件之前设置）：
#   OBSHARP_QT_MODULES          Qt 模块列表（不带 Qt 前缀）
#   OBSHARP_QT_INCLUDE_DIR      Qt 头文件根目录
#   OBSHARP_CLANG_TARGET_TRIPLE Clang target triple
#   OBSHARP_SOURCEGEN_NATIVE_ONLY 仅生成非托管源码（ON/OFF）
#
# 例如：
#   set(OBSHARP_SOURCEGEN_NATIVE_ONLY OFF)
#   include("${CMAKE_CURRENT_LIST_DIR}/Invoke-SourceGenerator.cmake")
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

if(DEFINED OBSHARP_QT_INCLUDE_DIR AND
   NOT "${OBSHARP_QT_INCLUDE_DIR}" STREQUAL "")
  get_filename_component(_obsharp_qt_include
    "${OBSHARP_QT_INCLUDE_DIR}" ABSOLUTE)
else()
  set(_obsharp_qt_include "")

  # obs-deps.cmake 成功准备依赖后应公开 OBSHARP_QT_ROOT。
  if(DEFINED OBSHARP_QT_ROOT AND
     EXISTS "${OBSHARP_QT_ROOT}/include/QtCore/QtCore")
    set(_obsharp_qt_include "${OBSHARP_QT_ROOT}/include")
  elseif(DEFINED _target_qt AND
         EXISTS "${_target_qt}/include/QtCore/QtCore")
    # 兼容尚未更新的 obs-deps.cmake。
    set(_obsharp_qt_include "${_target_qt}/include")
  endif()

  # 兼容变量名或 include 顺序发生变化的情况。
  if(NOT _obsharp_qt_include AND DEFINED QT_INCLUDE_DIRS)
    foreach(_candidate IN LISTS QT_INCLUDE_DIRS)
      if(EXISTS "${_candidate}/QtCore/QtCore")
        set(_obsharp_qt_include "${_candidate}")
        break()
      endif()
    endforeach()
  endif()

  # 最后从 .deps 中按目录名倒序探测。
  if(NOT _obsharp_qt_include)
    file(GLOB _obsharp_qt_candidates
      LIST_DIRECTORIES TRUE
      "${_obsharp_project_root}/.deps/obs-deps-qt6-*/include"
    )
    list(SORT _obsharp_qt_candidates ORDER DESCENDING)

    foreach(_candidate IN LISTS _obsharp_qt_candidates)
      if(EXISTS "${_candidate}/QtCore/QtCore")
        set(_obsharp_qt_include "${_candidate}")
        break()
      endif()
    endforeach()
  endif()
endif()

if(NOT IS_DIRECTORY "${_obsharp_qt_include}" OR
   NOT EXISTS "${_obsharp_qt_include}/QtCore/QtCore")
  message(FATAL_ERROR
    "OBSharp: 未找到有效的 Qt 头文件目录。"
    " 请设置 OBSHARP_QT_INCLUDE_DIR，或确认 obs-deps.cmake 已准备好 Qt。"
    " 当前路径：${_obsharp_qt_include}")
endif()

get_filename_component(_obsharp_qt_include
  "${_obsharp_qt_include}" REALPATH)

message(STATUS "OBSharp: Qt 头文件目录：${_obsharp_qt_include}")
message(STATUS "OBSharp: 生成器：dotnet tool run OBSharp.Interop.NativeBindGenerator")

# -------------------------------------------------------------------------
# 收集各模块的公共头文件
# -------------------------------------------------------------------------

# 排除私有实现、平台专属与 global 头，只保留对外公开的 API 头文件。
set(_obsharp_public_header_exclude
  "(_p|_impl|_win|_mac|_platform)\\.h$|^q.*global\\.h$|^q(t_)?(win|mac|darwin|ios|android|unix|bsd|freebsd|wasm|nx|platform).*\\.h$"
)

set(_obsharp_module_header_map "")
set(_obsharp_generated_modules "")
set(_obsharp_header_arguments "")

foreach(_module IN LISTS OBSHARP_QT_MODULES)
  set(_module_name "Qt${_module}")
  set(_module_dir "${_obsharp_qt_include}/${_module_name}")
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
  foreach(_header IN LISTS _module_headers)
    get_filename_component(_header_name "${_header}" NAME)
    if(NOT _header_name MATCHES "${_obsharp_public_header_exclude}")
      list(APPEND _public_headers "${_header}")
    endif()
  endforeach()

  if(NOT _public_headers)
    message(WARNING
      "OBSharp: 跳过 ${_module_name}：没有可用的公共头文件。")
    continue()
  endif()

  list(APPEND _obsharp_generated_modules "${_module}")

  foreach(_header IN LISTS _public_headers)
    # Clang response file 中含空格的参数必须使用双引号。
    if(_header MATCHES "[ \t]")
      string(REPLACE "\\" "\\\\" _rsp_header "${_header}")
      string(REPLACE "\"" "\\\"" _rsp_header "${_rsp_header}")
      list(APPEND _obsharp_header_arguments "--header \"${_rsp_header}\"")
    else()
      list(APPEND _obsharp_header_arguments "--header ${_header}")
    endif()
  endforeach()
endforeach()

if(NOT _obsharp_generated_modules)
  message(FATAL_ERROR
    "OBSharp: 在 ${_obsharp_qt_include} 下没有找到任何可生成的 Qt 模块。")
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
  "-I"
  "${_obsharp_qt_include}"
  "-std=${_obsharp_clang_standard}"
)

if(DEFINED OBSHARP_CLANG_TARGET_TRIPLE AND
   NOT "${OBSHARP_CLANG_TARGET_TRIPLE}" STREQUAL "")
  list(APPEND _obsharp_clang_arguments
    "--target=${OBSHARP_CLANG_TARGET_TRIPLE}")
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
# 生成响应文件
# -------------------------------------------------------------------------

set(_obsharp_rsp_lines "")
list(APPEND _obsharp_rsp_lines ${_obsharp_header_arguments})

set(_obsharp_generator_arguments
  "--namespace"
  "OBSharp.Interop.Qt"
  "--library-name"
  "OBSharp.Interop.Qt.Native"
  "--cpp-redirect"
  "--qt"
  "--csharp-output"
  "${_obsharp_managed_output}"
  "--native-output"
  "${_obsharp_native_output}"
  "--native-name"
  "OBSharp.Interop.Qt.Native"
  "--return-string-marshaller"
  "OBSharp.Interop.Qt.NoFreeUTF8StringMarshaller"
  "--nullable-handle-marshaller"
  "OBSharp.Interop.Qt.NullableSafeHandleMarshaller"
  "--"
)

# 将生成器参数转换成响应文件的逐行参数格式。
foreach(_argument IN LISTS _obsharp_generator_arguments _obsharp_clang_arguments)
  if(_argument MATCHES "[ \t]")
    string(REPLACE "\\" "\\\\" _rsp_argument "${_argument}")
    string(REPLACE "\"" "\\\"" _rsp_argument "${_rsp_argument}")
    list(APPEND _obsharp_rsp_lines "\"${_rsp_argument}\"")
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
  COMMAND dotnet tool run OBSharp.Interop.NativeBindGenerator
    -- "@${_obsharp_response_file}"
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
# 生成 CMake 模块清单
# -------------------------------------------------------------------------

set(_obsharp_manifest
  "set(OBSHARP_QT_GENERATED_MODULES\n")
foreach(_module IN LISTS _obsharp_generated_modules)
  string(APPEND _obsharp_manifest "  ${_module}\n")
endforeach()
string(APPEND _obsharp_manifest ")\n")

file(WRITE
  "${_obsharp_native_output}/generated-modules.cmake"
  "${_obsharp_manifest}")

if(NOT OBSHARP_SOURCEGEN_NATIVE_ONLY)
  message(STATUS "OBSharp: 托管绑定输出：${_obsharp_managed_output}")
endif()
message(STATUS "OBSharp: 非托管绑定输出：${_obsharp_native_output}")
