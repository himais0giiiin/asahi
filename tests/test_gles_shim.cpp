// the ANGLE entry points over the host driver (Mesa without a display): extension list, errors, Robust calls,
// reverse row order, zeroed texture images and buffers, for ES 2.0 and ES 3.0 contexts
#define GL_GLES_PROTOTYPES 0
#define EGL_EGL_PROTOTYPES 0
#include <angle_gl.h>
#include <entry_points_gles_2_0_autogen.h>
#include <entry_points_gles_3_0_autogen.h>
#include <entry_points_gles_ext_autogen.h>

#include "yozora_gl.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static int failures;

#define CHECK(condition) do { if (!(condition)) { std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); ++failures; } } while (0)

static bool has(const std::string& list, const char* word)
{
    return (" " + list + " ").find(std::string(" ") + word + " ") != std::string::npos;
}

static void testContext(int version)
{
    std::fprintf(stderr, "es %d\n", version);
    auto* context = yozora_gl_context_create(version);
    if (!context) {
        std::fprintf(stderr, "no es %d context on this machine, skipped\n", version);
        return;
    }
    CHECK(yozora_gl_context_make_current(context));
    CHECK(yozora_gl_context_version(context) == version);
    CHECK(GL_GetError() == GL_NO_ERROR);

    std::string extensions = reinterpret_cast<const char*>(GL_GetString(GL_EXTENSIONS));
    CHECK(has(extensions, "GL_KHR_debug"));
    CHECK(has(extensions, "GL_ANGLE_pack_reverse_row_order"));
    CHECK(has(extensions, "GL_ANGLE_translated_shader_source"));
    CHECK(version < 3 || has(extensions, "GL_ANGLE_framebuffer_multisample"));
    CHECK(version < 3 || has(extensions, "GL_EXT_occlusion_query_boolean"));
    CHECK(std::string(reinterpret_cast<const char*>(GL_GetString(GL_REQUESTABLE_EXTENSIONS_ANGLE))).empty());

    // KHR_debug is switched on by WebKit and must not leave an error behind
    GL_Enable(GL_DEBUG_OUTPUT);
    GL_DebugMessageControlKHR(GL_DONT_CARE, GL_DONT_CARE, GL_DONT_CARE, 0, nullptr, 0);
    CHECK(GL_GetError() == GL_NO_ERROR);

    // a framebuffer with a color texture of four rows: the bottom half red, the top half green
    GLuint texture = 0, framebuffer = 0;
    GL_GenTextures(1, &texture);
    GL_BindTexture(GL_TEXTURE_2D, texture);
    GL_TexImage2DRobustANGLE(GL_TEXTURE_2D, 0, GL_RGBA, 2, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0, nullptr);
    GL_GenFramebuffers(1, &framebuffer);
    GL_BindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    GL_FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    CHECK(GL_CheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    // a texture made without data reads as zero
    uint8_t pixels[2 * 4 * 4];
    std::memset(pixels, 0xAA, sizeof pixels);
    GL_ReadPixelsRobustANGLE(0, 0, 2, 4, GL_RGBA, GL_UNSIGNED_BYTE, sizeof pixels, nullptr, nullptr, nullptr, pixels);
    bool zero = true;
    for (uint8_t byte : pixels)
        zero = zero && !byte;
    CHECK(zero);
    GL_Enable(GL_SCISSOR_TEST);
    GL_Scissor(0, 0, 2, 2);
    GL_ClearColor(1, 0, 0, 1);
    GL_Clear(GL_COLOR_BUFFER_BIT);
    GL_Scissor(0, 2, 2, 2);
    GL_ClearColor(0, 1, 0, 1);
    GL_Clear(GL_COLOR_BUFFER_BIT);
    GL_Disable(GL_SCISSOR_TEST);
    GLsizei length = 0, columns = 0, rows = 0;
    GL_ReadPixelsRobustANGLE(0, 0, 2, 4, GL_RGBA, GL_UNSIGNED_BYTE, sizeof pixels, &length, &columns, &rows, pixels);
    CHECK(length == 32 && columns == 2 && rows == 4);
    CHECK(pixels[0] == 255 && pixels[1] == 0);         // the first row of memory is the bottom row of the image
    CHECK(pixels[3 * 8 + 0] == 0 && pixels[3 * 8 + 1] == 255);
    GL_PixelStorei(GL_PACK_REVERSE_ROW_ORDER_ANGLE, 1);
    GL_ReadPixelsRobustANGLE(0, 0, 2, 4, GL_RGBA, GL_UNSIGNED_BYTE, sizeof pixels, nullptr, nullptr, nullptr, pixels);
    GL_PixelStorei(GL_PACK_REVERSE_ROW_ORDER_ANGLE, 0);
    CHECK(pixels[0] == 0 && pixels[1] == 255);         // reversed: the top row first
    CHECK(pixels[3 * 8 + 0] == 255 && pixels[3 * 8 + 1] == 0);
    // a buffer that is too small is refused with an error and the memory is not touched
    uint8_t guard[4] = { 7, 7, 7, 7 };
    GL_ReadPixelsRobustANGLE(0, 0, 2, 4, GL_RGBA, GL_UNSIGNED_BYTE, 4, nullptr, nullptr, nullptr, guard);
    CHECK(GL_GetError() == GL_INVALID_OPERATION);
    CHECK(guard[0] == 7 && guard[3] == 7);
    CHECK(GL_GetError() == GL_NO_ERROR);

    // new buffer storage reads as zero
    GLuint buffer = 0;
    GL_GenBuffers(1, &buffer);
    GL_BindBuffer(GL_ARRAY_BUFFER, buffer);
    GL_BufferData(GL_ARRAY_BUFFER, 64, nullptr, GL_STATIC_DRAW);
    CHECK(GL_GetError() == GL_NO_ERROR);

    // robust getters write through the plain call
    GLint maxTexture = 0;
    GL_GetIntegervRobustANGLE(GL_MAX_TEXTURE_SIZE, 1, nullptr, &maxTexture);
    CHECK(maxTexture >= 64);
    GLint isBuffer = 0;
    GL_GetBufferParameterivRobustANGLE(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, 1, nullptr, &isBuffer);
    CHECK(isBuffer == 64);

    // a shader reads back as the translated source, and its length through the ANGLE query
    GLuint shader = GL_CreateShader(GL_VERTEX_SHADER);
    const char* source = "attribute vec4 p; void main() { gl_Position = p; }";
    GL_ShaderSource(shader, 1, &source, nullptr);
    GL_CompileShader(shader);
    GLint status = 0, sourceLength = 0;
    GL_GetShaderivRobustANGLE(shader, GL_COMPILE_STATUS, 1, nullptr, &status);
    GL_GetShaderivRobustANGLE(shader, GL_TRANSLATED_SHADER_SOURCE_LENGTH_ANGLE, 1, nullptr, &sourceLength);
    CHECK(version >= 3 || status == GL_TRUE);
    CHECK(sourceLength == static_cast<GLint>(std::strlen(source)) + 1);
    std::vector<char> translated(sourceLength);
    GL_GetTranslatedShaderSourceANGLE(shader, sourceLength, nullptr, translated.data());
    CHECK(std::strcmp(translated.data(), source) == 0);

    // a function that only some drivers have is either made or an error of the entry point, and never a crash
    GL_ProvokingVertexANGLE(GL_FIRST_VERTEX_CONVENTION_ANGLE);
    GLenum provoking = GL_GetError();
    CHECK(provoking == GL_NO_ERROR || provoking == GL_INVALID_OPERATION);
    CHECK(GL_GetError() == GL_NO_ERROR);

    if (version >= 3) {
        GLint sampleCount = -1;
        GL_GetInternalformativRobustANGLE(GL_RENDERBUFFER, GL_RGBA8, GL_NUM_SAMPLE_COUNTS, 1, nullptr, &sampleCount);
        CHECK(GL_GetError() == GL_NO_ERROR);
        CHECK(sampleCount >= 0);
        // the core calls reach the driver under the names of ES 3.0
        GLuint array = 0;
        GL_GenVertexArraysOES(1, &array);
        GL_BindVertexArrayOES(array);
        CHECK(GL_IsVertexArrayOES(array));
        CHECK(GL_GetError() == GL_NO_ERROR);
    }
    yozora_gl_context_destroy(context);
}

int main()
{
    testContext(2);
    testContext(3);
    if (failures)
        return 1;
    std::puts("gles shim: extensions, errors, robust calls, reverse rows and zeroed storage passed");
    return 0;
}
