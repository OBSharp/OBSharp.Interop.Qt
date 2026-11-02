if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/Generated/generated-sources.cmake")
    message(FATAL_ERROR
        "Missing generated Qt sources. Run scripts/Invoke-SourceGenerator.ps1 before configuring.")
endif()

include(Generated/generated-sources.cmake)

# 现在的 CMAKE_PREFIX_PATH 里已经由 obs-deps.cmake 塞好了刚刚下载的 Qt6 路径
find_package(Qt6 REQUIRED COMPONENTS ${OBSHARP_QT_GENERATED_MODULES})

add_library(OBSharp.Interop.Qt.Native SHARED
    ${OBSHARP_QT_GENERATED_SOURCES}
    ${OBSHARP_QT_GENERATED_HEADERS}
)

target_compile_features(OBSharp.Interop.Qt.Native PRIVATE cxx_std_20)
target_compile_definitions(OBSharp.Interop.Qt.Native PRIVATE OBSHARP_EXPORTS)

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
        find_file(OBSHARP_QT_DESIGNER_COMPONENTS_LIBRARY
            NAMES libQt6DesignerComponents.so.6
            HINTS ${CMAKE_PREFIX_PATH}
            PATH_SUFFIXES "lib/${CMAKE_LIBRARY_ARCHITECTURE}" lib64 lib
            REQUIRED
        )
        list(APPEND qt_targets "${OBSHARP_QT_DESIGNER_COMPONENTS_LIBRARY}")
    endif()
endif()

target_link_libraries(OBSharp.Interop.Qt.Native PRIVATE ${qt_targets})

set_target_properties(OBSharp.Interop.Qt.Native PROPERTIES
    OUTPUT_NAME "OBSharp.Interop.Qt.Native"
    CXX_EXTENSIONS OFF
)

install(TARGETS OBSharp.Interop.Qt.Native
    RUNTIME DESTINATION .
    LIBRARY DESTINATION .
    ARCHIVE DESTINATION lib
)