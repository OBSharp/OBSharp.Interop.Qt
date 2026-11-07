if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/Generated/generated-modules.cmake")
    message(FATAL_ERROR
        "Missing generated Qt sources. Run scripts/Invoke-SourceGenerator.ps1 before configuring.")
endif()

if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/Generated/generated-libraries.cmake")
    message(FATAL_ERROR
        "Missing generated native library manifest. Regenerate the bindings before configuring.")
endif()

option(OBSHARP_NATIVE_PRECOMPILE_HEADERS
    "为 Qt 绑定启用预编译头（显著加快数百个翻译单元的编译）" ON)

# 模块清单由 code-gen.cmake 写入 generated-modules.cmake，其中还带上了
# 生成器输出的预编译头路径（<native-name>.pch.h）。PCH 完全由生成器产出，
# 本文件不再自行拼装或退回旧版生成器的等价头文件。
include(Generated/generated-modules.cmake)

if(OBSHARP_NATIVE_PRECOMPILE_HEADERS AND
   NOT EXISTS "${OBSHARP_QT_PCH_HEADER}")
    message(FATAL_ERROR
        "Missing generated Qt precompiled header: ${OBSHARP_QT_PCH_HEADER}")
endif()

# 库划分清单由生成器写入 generated-libraries.cmake：
# 单个 PE 的导出表上限为 65535 项，导出数超过上限时生成器会自动拆成多个库。
include(Generated/generated-libraries.cmake)

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

foreach(library IN LISTS OBSHARP_NATIVE_LIBRARIES)
    string(TOUPPER "${library}" library_key)
    string(REGEX REPLACE "[^A-Z0-9]" "_" library_key "${library_key}")
    set(library_source_dir "${OBSHARP_NATIVE_LIBRARY_${library_key}_SOURCE_DIR}")

    # 每个库只收自己目录下的 .cpp：主库在 Generated 根目录，附属库在 Generated/<库名>/，
    # 因此这里用 GLOB 而不是 GLOB_RECURSE，避免把别的库的源码拉进来。
    file(GLOB library_sources CONFIGURE_DEPENDS "${library_source_dir}/*.cpp")
    if(NOT library_sources)
        message(FATAL_ERROR
            "No generated C++ sources for native library ${library}: ${library_source_dir}")
    endif()

    add_library(${library} SHARED
        ${library_sources}
        ${OBSHARP_QT_GENERATED_HEADERS}
    )

    target_compile_features(${library} PRIVATE cxx_std_20)
    target_compile_definitions(${library} PRIVATE OBSHARP_EXPORTS)

    # MSVC 专属选项：
    # /bigobj —— 生成的绑定源码符号与节数极多，超出 COFF 默认限制；
    # /utf-8 —— 源码与执行字符集统一为 UTF-8，Qt 头文件中的非 ASCII 字面量不至告警或乱码；
    # /MP —— 生成器按类拆分后每个类是一个翻译单元，且都要解析体积很大的公共头文件，
    #        必须并行编译，否则单个库要编译数小时。
    if(MSVC)
        target_compile_options(${library} PRIVATE
            /bigobj
            /utf-8
            /MP
        )
    endif()

    target_link_libraries(${library} PRIVATE ${qt_targets})

    set_target_properties(${library} PROPERTIES
        OUTPUT_NAME "${library}"
        CXX_EXTENSIONS OFF
    )

    # 预编译头：生成器写入每个类翻译单元的 include 前缀完全相同（700+ 个
    # Qt 公共头文件），用 PCH 让所有翻译单元复用同一次解析结果。
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
