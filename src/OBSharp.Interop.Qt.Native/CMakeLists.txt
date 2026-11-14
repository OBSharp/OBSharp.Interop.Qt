if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/Generated/generated-modules.cmake")
    message(FATAL_ERROR
        "Missing generated Qt sources. Run scripts/Invoke-SourceGenerator.ps1 before configuring.")
endif()

option(OBSHARP_NATIVE_PRECOMPILE_HEADERS
    "为 Qt 绑定启用预编译头（显著加快数百个翻译单元的编译）" ON)

# 模块清单、预编译头路径与共享库清单路径都由 code-gen.cmake 写入
# generated-modules.cmake，本文件不再自行猜测产物名。
include(Generated/generated-modules.cmake)

if(OBSHARP_NATIVE_PRECOMPILE_HEADERS AND
   NOT EXISTS "${OBSHARP_QT_PCH_HEADER}")
    message(FATAL_ERROR
        "Missing generated Qt precompiled header: ${OBSHARP_QT_PCH_HEADER}")
endif()

# 共享库清单由生成器自己写出：每个库一个 add_library，源文件列表已经写在
# 清单里。单个 PE 的导出表上限为 65535 项，导出数超过上限时生成器会自动
# 拆成多个库并落到不同的清单条目，因此本文件不能再按目录 GLOB 收集源文件，
# 否则每个库都会把全部源码编译一遍。
if(NOT EXISTS "${OBSHARP_NATIVE_MANIFEST}")
    message(FATAL_ERROR
        "Missing generated native library manifest: ${OBSHARP_NATIVE_MANIFEST}")
endif()

# 现在的 CMAKE_PREFIX_PATH 里已经由 obs-deps.cmake 塞好了刚刚下载的 Qt6 路径
find_package(Qt6 REQUIRED COMPONENTS ${OBSHARP_QT_GENERATED_MODULES})

set(qt_targets)
foreach(module IN LISTS OBSHARP_QT_GENERATED_MODULES)
    list(APPEND qt_targets "Qt6::${module}")
endforeach()

if(Designer IN_LIST OBSHARP_QT_GENERATED_MODULES)
    if(APPLE)
        find_package(Qt6DesignerComponentsPrivate REQUIRED)
        list(APPEND qt_targets Qt6::DesignerComponentsPrivate)
    elseif(WIN32)
        # HINTS 确保优先在我们下载的 .deps 目录里找
        find_library(OBSHARP_QT_DESIGNER_COMPONENTS_LIBRARY
            NAMES Qt6DesignerComponents
            HINTS ${CMAKE_PREFIX_PATH}
            PATH_SUFFIXES lib bin
            REQUIRED
        )
        list(APPEND qt_targets "${OBSHARP_QT_DESIGNER_COMPONENTS_LIBRARY}")
    else()
        # Linux 发行版：qt6-tools-dev 提供 Qt6DesignerComponentsPrivate 的
        # CMake 配置包（同时依赖 libqt6designercomponents6 提供 .so.6）。
        # 优先使用导入目标，因为 Qt6 的私有目标会带上必要的编译定义。
        find_package(Qt6DesignerComponentsPrivate QUIET)
        if(TARGET Qt6::DesignerComponentsPrivate)
            list(APPEND qt_targets Qt6::DesignerComponentsPrivate)
        else()
            find_file(OBSHARP_QT_DESIGNER_COMPONENTS_LIBRARY
                NAMES libQt6DesignerComponents.so.6
                HINTS ${CMAKE_PREFIX_PATH}
                PATH_SUFFIXES "lib/${CMAKE_LIBRARY_ARCHITECTURE}" lib64 lib
                REQUIRED
            )
            list(APPEND qt_targets "${OBSHARP_QT_DESIGNER_COMPONENTS_LIBRARY}")
        endif()
    endif()
endif()

file(GLOB OBSHARP_QT_GENERATED_HEADERS CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_LIST_DIR}/Generated/*.h"
    "${CMAKE_CURRENT_LIST_DIR}/Generated/*.hpp"
)

# 清单只负责建库（源文件、include 目录与 OUTPUT_NAME）；库名由清单自己写在
# <目标名大写、非字母数字替换为下划线>_LIBRARIES 里，这里按清单声明的顺序
# 统一补上 Qt 依赖、编译选项与预编译头。不硬编码库名：导出数超过 65535 时
# 生成器会拆出 `<目标名>.<序号>` 之类的后续库，名字随清单内容变化。
include("${OBSHARP_NATIVE_MANIFEST}")

set(OBSHARP_NATIVE_LIBRARIES
    ${OBSHARP_INTEROP_QT_NATIVE_LIBRARIES})

foreach(library IN LISTS OBSHARP_NATIVE_LIBRARIES)
    if(NOT TARGET "${library}")
        message(FATAL_ERROR
            "Native library ${library} listed in ${OBSHARP_NATIVE_MANIFEST} "
            "is not a CMake target")
    endif()
endforeach()

if(NOT OBSHARP_NATIVE_LIBRARIES)
    message(FATAL_ERROR
        "No native libraries defined by ${OBSHARP_NATIVE_MANIFEST}")
endif()

foreach(library IN LISTS OBSHARP_NATIVE_LIBRARIES)
    target_compile_features(${library} PRIVATE cxx_std_20)
    target_sources(${library} PRIVATE ${OBSHARP_QT_GENERATED_HEADERS})
    set_target_properties(${library} PROPERTIES
        CXX_EXTENSIONS OFF
    )

    # MSVC 专属选项：
    # /bigobj —— 生成的绑定源码符号与节数极多，超出 COFF 默认限制；
    # /utf-8 —— 源码与执行字符集统一为 UTF-8，Qt 头文件中的非 ASCII 字面量不至告警或乱码；
    # /MP —— 生成的绑定源码按规模拆成多个翻译单元，且都要解析体积很大的公共头文件，
    #        必须并行编译，否则单个库要编译数小时。
    if(MSVC)
        target_compile_options(${library} PRIVATE
            /bigobj
            /utf-8
            /MP
        )
    endif()

    target_link_libraries(${library} PRIVATE ${qt_targets})

    # 预编译头：生成器写入每个翻译单元（.cpp）的 include 前缀完全相同
    # （数百个 Qt 公共头文件），用 PCH 让所有翻译单元复用同一次解析结果。
    # 在 Windows CI（4 vCPU）上，933 个 TU 的编译耗时从约 66 分钟降到
    # 分钟级；没有 PCH 时每个 TU 都要重新解析全部 Qt 头文件。
    if(OBSHARP_NATIVE_PRECOMPILE_HEADERS)
        target_precompile_headers(${library} PRIVATE
            "${OBSHARP_QT_PCH_HEADER}")
    endif()
endforeach()

install(TARGETS ${OBSHARP_NATIVE_LIBRARIES}
    RUNTIME DESTINATION .
    LIBRARY DESTINATION .
    ARCHIVE DESTINATION lib
)
