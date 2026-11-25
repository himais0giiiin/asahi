// the entry points of ANGLE (GL_Foo) over the system OpenGL ES. WebKit calls them as if ANGLE were the
// driver, so what ANGLE adds is made here: the extension list, the Robust calls, reverse row order for reads,
// zeroed new storage and KHR_debug that never fires. the rest is forwarded by yozora_gles_forward.inc, made
// from the ANGLE headers
#define GL_GLES_PROTOTYPES 0
#define EGL_EGL_PROTOTYPES 0
#include <angle_gl.h>
#include <entry_points_gles_2_0_autogen.h>
#include <entry_points_gles_3_0_autogen.h>
#include <entry_points_gles_ext_autogen.h>

#include "yozora_gl_internal.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <string>
#include <vector>

namespace {

const GLenum kDebugOutput = 0x92E0;
const GLenum kDebugOutputSynchronous = 0x8242;
const GLenum kTextureRectangle = 0x84F5;
const GLenum kPackReverseRowOrder = 0x93A4;
const GLenum kPackRowLength = 0x0D02;
const GLenum kPixelUnpackBufferBinding = 0x88EF;
const GLenum kShaderSourceLength = 0x8B88;
const GLenum kTranslatedShaderSourceLength = 0x93A0;

void raise(GLenum error)
{
    if (auto* state = yozora_gl_current_state()) {
        if (!state->pending_error)
            state->pending_error = error;
    }
}

}

extern "C" void yozora_gl_raise(unsigned error)
{
    raise(error);
}

namespace {

int slot()
{
    auto* state = yozora_gl_current_state();
    return state && state->version >= 3 ? 1 : 0;
}

// the first name the driver has for the version of the context: see make_gles_forward.py for the two orders
void* firstProc(std::initializer_list<const char*> es3, std::initializer_list<const char*> es2)
{
    auto* state = yozora_gl_current_state();
    for (auto* name : (state && state->version >= 3) ? es3 : es2) {
        if (auto* function = yozora_gl_proc(name))
            return function;
    }
    return nullptr;
}

}

#define yozora_gl_proc_any(...) firstProc(__VA_ARGS__)
#define yozora_gl_slot() slot()

namespace {

template<typename Function>
Function native(const char* name)
{
    return reinterpret_cast<Function>(yozora_gl_proc(name));
}

// a hand written entry point passes the gate of yozora_gl_gate.c once around all of its driver calls, so a
// shut gate holds it before the first one and never between two
struct GateScope {
    GateScope() { yozora_gl_enter(); }
    ~GateScope() { yozora_gl_leave(); }
    GateScope(const GateScope&) = delete;
    GateScope& operator=(const GateScope&) = delete;
};

// YOZORA_GL_TRACE=1 names every forwarded call that left a driver error. it reads the error, so the page
// never sees it: a tool for finding which call a driver refuses, not a mode to run a page in
void trace(const char* name)
{
    static const bool enabled = std::getenv("YOZORA_GL_TRACE") != nullptr;
    if (!enabled)
        return;
    auto getError = native<GLenum (GL_APIENTRY*)()>("glGetError");
    for (GLenum error = getError ? getError() : 0; error; error = getError())
    {
        std::fprintf(stderr, "yozora-gl: %s left error 0x%x\n", name, error);
        if (error == GL_INVALID_FRAMEBUFFER_OPERATION) {
            if (auto status = native<GLenum (GL_APIENTRY*)(GLenum)>("glCheckFramebufferStatus"))
                std::fprintf(stderr, "yozora-gl: the framebuffer is 0x%x\n", status(GL_FRAMEBUFFER));
        }
    }
}


// the size of one pixel of a client memory transfer, 0 for a combination that no version of OpenGL ES accepts
size_t pixelBytes(GLenum format, GLenum type)
{
    switch (type) {
    case GL_UNSIGNED_SHORT_5_6_5:
    case GL_UNSIGNED_SHORT_4_4_4_4:
    case GL_UNSIGNED_SHORT_5_5_5_1:
        return 2;
    case GL_UNSIGNED_INT_2_10_10_10_REV:
    case GL_UNSIGNED_INT_10F_11F_11F_REV:
    case GL_UNSIGNED_INT_5_9_9_9_REV:
    case GL_UNSIGNED_INT_24_8:
        return 4;
    case GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
        return 8;
    default:
        break;
    }
    size_t components = 0;
    switch (format) {
    case GL_ALPHA:
    case GL_LUMINANCE:
    case GL_RED:
    case GL_RED_INTEGER:
    case GL_DEPTH_COMPONENT:
    case GL_DEPTH_STENCIL:
        components = 1;
        break;
    case GL_LUMINANCE_ALPHA:
    case GL_RG:
    case GL_RG_INTEGER:
        components = 2;
        break;
    case GL_RGB:
    case GL_RGB_INTEGER:
        components = 3;
        break;
    case GL_RGBA:
    case GL_RGBA_INTEGER:
        components = 4;
        break;
    default:
        return 0;
    }
    size_t size = 0;
    switch (type) {
    case GL_UNSIGNED_BYTE:
    case GL_BYTE:
        size = 1;
        break;
    case GL_UNSIGNED_SHORT:
    case GL_SHORT:
    case GL_HALF_FLOAT:
    case GL_HALF_FLOAT_OES:
        size = 2;
        break;
    case GL_UNSIGNED_INT:
    case GL_INT:
    case GL_FLOAT:
        size = 4;
        break;
    default:
        return 0;
    }
    return components * size;
}

// the bytes a transfer of rows covers when each row starts on a multiple of alignment. false on overflow
bool transferBytes(size_t width, size_t height, size_t depth, size_t pixel, int alignment, size_t& total, size_t& rowBytes)
{
    if (!pixel || alignment < 1)
        return false;
    size_t row = width * pixel;
    if (width && row / width != pixel)
        return false;
    size_t unit = static_cast<size_t>(alignment);
    row = (row + unit - 1) / unit * unit;
    rowBytes = row;
    total = row * height;
    if (height && total / height != row)
        return false;
    size_t layers = total * depth;
    if (depth && layers / depth != total)
        return false;
    total = layers;
    return true;
}

bool hasWord(const std::string& list, const char* word)
{
    size_t length = std::strlen(word);
    for (size_t at = list.find(word); at != std::string::npos; at = list.find(word, at + 1)) {
        bool starts = !at || list[at - 1] == ' ';
        bool ends = at + length == list.size() || list[at + length] == ' ';
        if (starts && ends)
            return true;
    }
    return false;
}

// what the driver has and what ANGLE would show on top for this version: ANGLE extensions that are plain ES
// 3.0 core features or a thin layer over them, and the ones this file makes itself
const char* extensionsMade(int version)
{
    if (version >= 3) {
        return "GL_KHR_debug GL_ANGLE_pack_reverse_row_order GL_ANGLE_translated_shader_source GL_ANGLE_robust_client_memory "
               "GL_ANGLE_framebuffer_multisample GL_ANGLE_framebuffer_blit GL_EXT_occlusion_query_boolean GL_ANGLE_instanced_arrays "
               "GL_EXT_draw_buffers GL_OES_vertex_array_object GL_OES_depth_texture GL_ANGLE_depth_texture GL_OES_packed_depth_stencil "
               "GL_OES_depth24 GL_OES_rgb8_rgba8 GL_OES_standard_derivatives GL_OES_element_index_uint GL_EXT_blend_minmax "
               "GL_OES_texture_half_float GL_EXT_shader_texture_lod";
    }
    return "GL_KHR_debug GL_ANGLE_pack_reverse_row_order GL_ANGLE_translated_shader_source GL_ANGLE_robust_client_memory";
}

const char* extensionsOf(yozora_gl_state& state)
{
    if (state.extensions)
        return state.extensions;
    auto getString = native<const GLubyte* (GL_APIENTRY*)(GLenum)>("glGetString");
    std::string list;
    if (getString) {
        if (auto* text = getString(GL_EXTENSIONS))
            list = reinterpret_cast<const char*>(text);
    }
    std::string extra = extensionsMade(state.version);
    size_t at = 0;
    while (at < extra.size()) {
        size_t end = extra.find(' ', at);
        if (end == std::string::npos)
            end = extra.size();
        std::string word = extra.substr(at, end - at);
        if (!word.empty() && !hasWord(list, word.c_str()))
            list += (list.empty() ? "" : " ") + word;
        at = end + 1;
    }
    // ES 2.0 drivers name some of these under the extension of the vendor: the same entry points, shown under the name WebKit looks for
    if (state.version < 3) {
        if (hasWord(list, "GL_OES_depth_texture") && !hasWord(list, "GL_ANGLE_depth_texture"))
            list += " GL_ANGLE_depth_texture";
        if (hasWord(list, "GL_EXT_instanced_arrays") && !hasWord(list, "GL_ANGLE_instanced_arrays"))
            list += " GL_ANGLE_instanced_arrays";
    }
    state.extensions = static_cast<char*>(std::malloc(list.size() + 1));
    if (!state.extensions)
        return "";
    std::memcpy(state.extensions, list.c_str(), list.size() + 1);
    return state.extensions;
}

}

extern "C" {

ANGLE_EXPORT GLenum GL_APIENTRY GL_GetError()
{
    GateScope gate;
    auto* state = yozora_gl_current_state();
    if (state && state->pending_error) {
        GLenum error = state->pending_error;
        state->pending_error = 0;
        return error;
    }
    auto function = native<GLenum (GL_APIENTRY*)()>("glGetError");
    return function ? function() : GL_INVALID_OPERATION;
}

ANGLE_EXPORT const GLubyte *GL_APIENTRY GL_GetString(GLenum name)
{
    GateScope gate;
    auto* state = yozora_gl_current_state();
    if (name == GL_EXTENSIONS && state)
        return reinterpret_cast<const GLubyte*>(extensionsOf(*state));
    // ANGLE lists extensions that need a request before they work; a driver has none of those
    if (name == GL_REQUESTABLE_EXTENSIONS_ANGLE)
        return reinterpret_cast<const GLubyte*>("");
    auto function = native<const GLubyte* (GL_APIENTRY*)(GLenum)>("glGetString");
    return function ? function(name) : nullptr;
}

// KHR_debug is shown because WebKit requires it, nothing is reported: a driver answers errors through
// glGetError, which WebKit also reads. WebKit also switches the ANGLE texture rectangle target (for IOSurface
// frames) off around a shader compile, and a driver answers an unknown capability with INVALID_ENUM, which
// the page would read as its own error
ANGLE_EXPORT void GL_APIENTRY GL_Enable(GLenum cap)
{
    GateScope gate;
    if (cap == kDebugOutput || cap == kDebugOutputSynchronous || cap == kTextureRectangle)
        return;
    auto function = native<void (GL_APIENTRY*)(GLenum)>("glEnable");
    if (function)
        function(cap);
}

ANGLE_EXPORT void GL_APIENTRY GL_Disable(GLenum cap)
{
    GateScope gate;
    if (cap == kDebugOutput || cap == kDebugOutputSynchronous || cap == kTextureRectangle)
        return;
    auto function = native<void (GL_APIENTRY*)(GLenum)>("glDisable");
    if (function)
        function(cap);
}

ANGLE_EXPORT GLboolean GL_APIENTRY GL_IsEnabled(GLenum cap)
{
    GateScope gate;
    if (cap == kDebugOutput || cap == kDebugOutputSynchronous || cap == kTextureRectangle)
        return GL_TRUE;
    auto function = native<GLboolean (GL_APIENTRY*)(GLenum)>("glIsEnabled");
    return function ? function(cap) : GL_FALSE;
}

ANGLE_EXPORT void GL_APIENTRY GL_DebugMessageControlKHR(GLenum, GLenum, GLenum, GLsizei, const GLuint*, GLboolean)
{
}

ANGLE_EXPORT void GL_APIENTRY GL_DebugMessageCallbackKHR(GLDEBUGPROCKHR, const void*)
{
}

// the extensions a driver has are on from the start
ANGLE_EXPORT void GL_APIENTRY GL_RequestExtensionANGLE(const GLchar*)
{
}

// the driver compiles the source of WebGL as it is, so the translated source is the source
ANGLE_EXPORT void GL_APIENTRY GL_GetTranslatedShaderSourceANGLE(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* source)
{
    GateScope gate;
    auto function = native<void (GL_APIENTRY*)(GLuint, GLsizei, GLsizei*, GLchar*)>("glGetShaderSource");
    if (!function) {
        raise(GL_INVALID_OPERATION);
        return;
    }
    function(shader, bufSize, length, source);
    trace("GL_GetTranslatedShaderSourceANGLE");
}

ANGLE_EXPORT void GL_APIENTRY GL_GetShaderivRobustANGLE(GLuint shader, GLenum pname, GLsizei, GLsizei* length, GLint* params)
{
    GateScope gate;
    auto function = native<void (GL_APIENTRY*)(GLuint, GLenum, GLint*)>("glGetShaderiv");
    if (!function) {
        raise(GL_INVALID_OPERATION);
        return;
    }
    function(shader, pname == kTranslatedShaderSourceLength ? kShaderSourceLength : pname, params);
    trace("GL_GetShaderivRobustANGLE");
    if (length)
        *length = 1;
}

ANGLE_EXPORT void GL_APIENTRY GL_PixelStorei(GLenum pname, GLint param)
{
    GateScope gate;
    auto* state = yozora_gl_current_state();
    if (state) {
        if (pname == kPackReverseRowOrder) {
            state->pack_reverse_row_order = param != 0;
            return;
        }
        if (pname == GL_PACK_ALIGNMENT)
            state->pack_alignment = param;
        else if (pname == GL_UNPACK_ALIGNMENT)
            state->unpack_alignment = param;
        else if (pname == kPackRowLength && state->version < 3) {
            // ES 2.0 has no row length: a read is tight, and a length that is not the width is not a read it can do
            state->pack_row_length = param;
            return;
        }
    }
    auto function = native<void (GL_APIENTRY*)(GLenum, GLint)>("glPixelStorei");
    if (function)
        function(pname, param);
    trace("GL_PixelStorei");
}

ANGLE_EXPORT void GL_APIENTRY GL_ReadPixelsRobustANGLE(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, GLsizei bufSize, GLsizei* length, GLsizei* columns, GLsizei* rows, void* pixels)
{
    GateScope gate;
    auto read = native<void (GL_APIENTRY*)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*)>("glReadPixels");
    auto* state = yozora_gl_current_state();
    if (!read || !state) {
        raise(GL_INVALID_OPERATION);
        return;
    }
    if (width < 0 || height < 0) {
        raise(GL_INVALID_VALUE);
        return;
    }
    size_t total = 0, rowBytes = 0;
    bool known = transferBytes(width, height, 1, pixelBytes(format, type), state->pack_alignment, total, rowBytes);
    // a read into a buffer object (bufSize 0, pixels an offset) is the driver's, and is not flipped here
    auto binding = native<void (GL_APIENTRY*)(GLenum, GLint*)>("glGetIntegerv");
    GLint packBuffer = 0;
    if (state->version >= 3 && binding)
        binding(GL_PIXEL_PACK_BUFFER_BINDING, &packBuffer);
    if (!packBuffer) {
        if (!known) {
            raise(GL_INVALID_ENUM);
            return;
        }
        if (static_cast<size_t>(bufSize) < total) {
            raise(GL_INVALID_OPERATION);
            return;
        }
    }
    if (packBuffer || !state->pack_reverse_row_order || height < 2) {
        read(x, y, width, height, format, type, pixels);
        trace("GL_ReadPixelsRobustANGLE");
    } else {
        std::vector<uint8_t> flipped(total);
        read(x, y, width, height, format, type, flipped.data());
        auto* out = static_cast<uint8_t*>(pixels);
        for (GLsizei row = 0; row < height; ++row)
            std::memcpy(out + rowBytes * row, flipped.data() + rowBytes * (height - 1 - row), rowBytes);
    }
    if (length)
        *length = static_cast<GLsizei>(total);
    if (columns)
        *columns = width;
    if (rows)
        *rows = height;
}

// WebGL requires new storage to read as zero, and a driver gives whatever the memory held before
ANGLE_EXPORT void GL_APIENTRY GL_BufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage)
{
    GateScope gate;
    auto function = native<void (GL_APIENTRY*)(GLenum, GLsizeiptr, const void*, GLenum)>("glBufferData");
    if (!function) {
        raise(GL_INVALID_OPERATION);
        return;
    }
    if (data || size <= 0) {
        function(target, size, data, usage);
        return;
    }
    void* zeros = std::calloc(1, static_cast<size_t>(size));
    if (!zeros) {
        raise(GL_OUT_OF_MEMORY);
        return;
    }
    function(target, size, zeros, usage);
    trace("GL_BufferData");
    std::free(zeros);
}

}

namespace {

// a texture image with no data reads as zero. with a buffer bound to the unpack target the null pointer is an
// offset and is left to the driver
bool unpackBufferBound(const yozora_gl_state& state)
{
    if (state.version < 3)
        return false;
    auto query = native<void (GL_APIENTRY*)(GLenum, GLint*)>("glGetIntegerv");
    GLint bound = 0;
    if (query)
        query(kPixelUnpackBufferBinding, &bound);
    return bound != 0;
}

void* zeroImage(const yozora_gl_state& state, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type)
{
    size_t total = 0, rowBytes = 0;
    if (width < 0 || height < 0 || depth < 0 || !transferBytes(width, height, depth, pixelBytes(format, type), state.unpack_alignment, total, rowBytes))
        return nullptr;
    return std::calloc(1, total ? total : 1);
}

}

extern "C" {

ANGLE_EXPORT void GL_APIENTRY GL_TexImage2DRobustANGLE(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, GLsizei bufSize, const void* pixels)
{
    GateScope gate;
    auto function = native<void (GL_APIENTRY*)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*)>("glTexImage2D");
    auto* state = yozora_gl_current_state();
    if (!function || !state) {
        raise(GL_INVALID_OPERATION);
        return;
    }
    if (!pixels && !bufSize && !unpackBufferBound(*state)) {
        if (void* zeros = zeroImage(*state, width, height, 1, format, type)) {
            function(target, level, internalformat, width, height, border, format, type, zeros);
            std::free(zeros);
            return;
        }
    }
    function(target, level, internalformat, width, height, border, format, type, pixels);
}

ANGLE_EXPORT void GL_APIENTRY GL_TexImage3DRobustANGLE(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLenum format, GLenum type, GLsizei bufSize, const void* pixels)
{
    GateScope gate;
    auto function = native<void (GL_APIENTRY*)(GLenum, GLint, GLint, GLsizei, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*)>("glTexImage3D");
    auto* state = yozora_gl_current_state();
    if (!function || !state) {
        raise(GL_INVALID_OPERATION);
        return;
    }
    if (!pixels && !bufSize && !unpackBufferBound(*state)) {
        if (void* zeros = zeroImage(*state, width, height, depth, format, type)) {
            function(target, level, internalformat, width, height, depth, border, format, type, zeros);
            std::free(zeros);
            return;
        }
    }
    function(target, level, internalformat, width, height, depth, border, format, type, pixels);
}

}

extern "C" void yozora_gl_raise(unsigned error);

#define yozora_gl_trace(name) trace(name)
#include "yozora_gles_forward.inc"
