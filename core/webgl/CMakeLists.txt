# the OpenGL ES of the system as ANGLE: the entry points WebKit calls for WebGL, and EGL for the few calls it makes outside of the entry points. included
# by the port, which names the ANGLE sources in YOZORA_ANGLE_DIR (Source/ThirdParty/ANGLE of WebKit, used for its headers only)
set(YOZORA_WEBGL_DIR "${CMAKE_CURRENT_LIST_DIR}")
set(yozora_gles_include
    "${YOZORA_ANGLE_DIR}/include"
    "${YOZORA_ANGLE_DIR}/src/libGLESv2")
set(yozora_gles_forward "${CMAKE_CURRENT_BINARY_DIR}/yozora_gles_forward.inc")
add_custom_command(
    OUTPUT "${yozora_gles_forward}"
    COMMAND "${Python_EXECUTABLE}" -B "${YOZORA_WEBGL_DIR}/make_gles_forward.py"
        "${YOZORA_ANGLE_DIR}/src/libGLESv2" "${YOZORA_WEBGL_DIR}/yozora_gles.cpp" "${yozora_gles_forward}"
    DEPENDS "${YOZORA_WEBGL_DIR}/make_gles_forward.py" "${YOZORA_WEBGL_DIR}/yozora_gles.cpp"
    VERBATIM)
set(yozora_gles_sources "${YOZORA_WEBGL_DIR}/yozora_gles.cpp" "${YOZORA_WEBGL_DIR}/yozora_egl.cpp" "${YOZORA_WEBGL_DIR}/yozora_gl_gate.c")
# the gate is portable c99 with a host test (tests/test_gl_gate.c), built here as strictly as there
set_source_files_properties("${YOZORA_WEBGL_DIR}/yozora_gl_gate.c" PROPERTIES COMPILE_OPTIONS "-std=c99;-Wall;-Wextra;-Werror;-pedantic")
if (APPLE)
    list(APPEND yozora_gles_sources "${YOZORA_WEBGL_DIR}/yozora_gl_eagl.m")
    # manual reference counting, like the rest of the app
    set_source_files_properties("${YOZORA_WEBGL_DIR}/yozora_gl_eagl.m" PROPERTIES COMPILE_OPTIONS "-fno-objc-arc")
else ()
    list(APPEND yozora_gles_sources "${YOZORA_WEBGL_DIR}/yozora_gl_egl.c")
endif ()
add_library(YozoraGLES STATIC ${yozora_gles_sources} "${yozora_gles_forward}")
target_include_directories(YozoraGLES PRIVATE "${YOZORA_WEBGL_DIR}" "${CMAKE_CURRENT_BINARY_DIR}" ${yozora_gles_include})
target_include_directories(YozoraGLES PUBLIC "${YOZORA_WEBGL_DIR}")
set_target_properties(YozoraGLES PROPERTIES POSITION_INDEPENDENT_CODE ON C_VISIBILITY_PRESET default CXX_VISIBILITY_PRESET default)
if (NOT APPLE)
    target_link_libraries(YozoraGLES PUBLIC EGL ${CMAKE_DL_LIBS})
else ()
    # CAEAGLLayer lives in QuartzCore and CGPointZero in CoreGraphics, the canvas layer of yozora_gl_eagl.m needs both
    target_link_libraries(YozoraGLES PUBLIC "-weak_framework OpenGLES" "-framework QuartzCore" "-framework CoreGraphics")
endif ()

# <ANGLE/entry_points_*.h> as WebKit includes them: the headers of ANGLE under the folder name of the framework
set(yozora_angle_forward "${CMAKE_CURRENT_BINARY_DIR}/include/ANGLE")
file(MAKE_DIRECTORY "${yozora_angle_forward}")
foreach (yozora_entry IN ITEMS egl_autogen egl_ext_autogen gles_2_0_autogen gles_3_0_autogen gles_ext_autogen)
    file(WRITE "${yozora_angle_forward}/entry_points_${yozora_entry}.h" "#include <entry_points_${yozora_entry}.h>\n")
endforeach ()
target_include_directories(YozoraGLES INTERFACE "${CMAKE_CURRENT_BINARY_DIR}/include" ${yozora_gles_include})
