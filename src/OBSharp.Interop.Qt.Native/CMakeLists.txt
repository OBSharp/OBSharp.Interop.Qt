if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/Generated/generated-sources.cmake")
    message(FATAL_ERROR
        "Missing generated Qt sources. Run scripts/Invoke-SourceGenerator.ps1 before configuring.")
endif()

include(Generated/generated-sources.cmake)

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