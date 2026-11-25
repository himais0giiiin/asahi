/* the OpenGL ES context on iOS: EAGL with no drawable. ES 3.0 exists from iOS 7 on the A7 and later and is
   asked for by class and selector at run time, so the armv7 slice built with the iOS 5 SDK links and runs on
   every system it supports */
#include "yozora_gl_internal.h"

#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>

struct yozora_gl_context {
    yozora_gl_state state;
    EAGLContext *context;
};

/* __thread is not available to the armv7 slice built for iOS 5, the current context of a thread is a key of the thread */
static pthread_key_t current_key;
static pthread_once_t current_once = PTHREAD_ONCE_INIT;

static void make_key(void)
{
    pthread_key_create(&current_key, NULL);
}

static yozora_gl_context *get_current(void)
{
    pthread_once(&current_once, make_key);
    return pthread_getspecific(current_key);
}

static void set_current(yozora_gl_context *context)
{
    pthread_once(&current_once, make_key);
    pthread_setspecific(current_key, context);
}

yozora_gl_state *yozora_gl_current_state(void)
{
    yozora_gl_context *current = get_current();
    return current ? &current->state : NULL;
}

static yozora_gl_context *context_create(int version)
{
    if (version != 2 && version != 3)
        return NULL;
    /* kEAGLRenderingAPIOpenGLES2 is 2 and OpenGLES3 is 3, the numbers of the versions */
    EAGLContext *handle = [[EAGLContext alloc] initWithAPI:(EAGLRenderingAPI)version];
    if (!handle)
        return NULL;
    yozora_gl_context *context = calloc(1, sizeof *context);
    if (!context) {
        [handle release];
        return NULL;
    }
    context->context = handle;
    context->state.version = version;
    context->state.pack_alignment = 4;
    context->state.unpack_alignment = 4;
    return context;
}

yozora_gl_context *yozora_gl_context_create(int version)
{
    yozora_gl_enter();
    yozora_gl_context *context = context_create(version);
    yozora_gl_leave();
    return context;
}

int yozora_gl_context_version(const yozora_gl_context *context)
{
    return context ? context->state.version : 0;
}

static int context_make_current(yozora_gl_context *context)
{
    if (!context)
        return 0;
    if (get_current() == context)
        return 1;
    if (![EAGLContext setCurrentContext:context->context])
        return 0;
    set_current(context);
    return 1;
}

/* a switch of the current context flushes the one before into the driver, so it waits at a shut gate like a draw */
int yozora_gl_context_make_current(yozora_gl_context *context)
{
    yozora_gl_enter();
    int made = context_make_current(context);
    yozora_gl_leave();
    return made;
}

static void context_release_thread(void)
{
    [EAGLContext setCurrentContext:nil];
    set_current(NULL);
}

void yozora_gl_context_release_thread(void)
{
    yozora_gl_enter();
    context_release_thread();
    yozora_gl_leave();
}

static void context_destroy(yozora_gl_context *context)
{
    if (!context)
        return;
    if (get_current() == context)
        context_release_thread();
    [context->context release];
    free(context->state.extensions);
    free(context);
}

void yozora_gl_context_destroy(yozora_gl_context *context)
{
    yozora_gl_enter();
    context_destroy(context);
    yozora_gl_leave();
}

void *yozora_gl_proc(const char *name)
{
    /* OpenGLES.framework is linked weakly, its functions are found in the image of the process */
    return dlsym(RTLD_DEFAULT, name);
}

/* a canvas shown without a read back: a CAEAGLLayer that a second context of the same sharegroup draws the
   frame texture into. the page context never changes state for it, and its bounds are set once before the
   layer is attached, the scene moves and scales the layer with its transform. the layer is a normal CALayer
   to the app, the core thread only presents into it */
struct yozora_gl_surface {
    yozora_canvas canvas;
    int references;
    CAEAGLLayer *layer;
    EAGLContext *context;
    GLuint framebuffer, renderbuffer, buffer, program;
};

static void surface_retain(yozora_canvas *canvas)
{
    __sync_fetch_and_add(&((yozora_gl_surface *)canvas)->references, 1);
}

static void surface_release(yozora_canvas *canvas)
{
    yozora_gl_surface *surface = (yozora_gl_surface *)canvas;
    if (__sync_sub_and_fetch(&surface->references, 1))
        return;
    /* the owner closes the surface on the core thread, a context that is still here was never drawn with again */
    [surface->context release];
    [surface->layer release];
    free(surface);
}

static GLuint surface_shader(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    GLint ok = 0;
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

/* the texture is read as it lies: GL rows run bottom up and so does the display of a renderbuffer */
static GLuint surface_program(int premultiplied)
{
    static const char *vertex =
        "attribute vec2 p;\n"
        "varying vec2 t;\n"
        "void main() { t = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }\n";
    /* an alpha layer takes premultiplied color, a canvas that is not premultiplied is multiplied here */
    static const char *copy =
        "precision mediump float;\n"
        "varying vec2 t;\n"
        "uniform sampler2D s;\n"
        "void main() { gl_FragColor = texture2D(s, t); }\n";
    static const char *premultiply =
        "precision mediump float;\n"
        "varying vec2 t;\n"
        "uniform sampler2D s;\n"
        "void main() { vec4 c = texture2D(s, t); gl_FragColor = vec4(c.rgb * c.a, c.a); }\n";
    GLuint vs = surface_shader(GL_VERTEX_SHADER, vertex);
    GLuint fs = surface_shader(GL_FRAGMENT_SHADER, premultiplied ? copy : premultiply);
    GLuint program = 0;
    GLint linked = 0;
    if (vs && fs) {
        program = glCreateProgram();
        glAttachShader(program, vs);
        glAttachShader(program, fs);
        glBindAttribLocation(program, 0, "p");
        glLinkProgram(program);
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!linked) {
            glDeleteProgram(program);
            program = 0;
        }
    }
    if (vs)
        glDeleteShader(vs);
    if (fs)
        glDeleteShader(fs);
    return program;
}

static void surface_delete_objects(yozora_gl_surface *surface)
{
    if (surface->program)
        glDeleteProgram(surface->program);
    if (surface->buffer)
        glDeleteBuffers(1, &surface->buffer);
    if (surface->framebuffer)
        glDeleteFramebuffers(1, &surface->framebuffer);
    if (surface->renderbuffer)
        glDeleteRenderbuffers(1, &surface->renderbuffer);
    surface->program = surface->buffer = surface->framebuffer = surface->renderbuffer = 0;
}

static yozora_gl_surface *surface_create(yozora_gl_context *page, unsigned width, unsigned height, int opaque, int premultiplied)
{
    if (!page || !width || !height)
        return NULL;
    yozora_gl_surface *surface = calloc(1, sizeof *surface);
    if (!surface)
        return NULL;
    surface->references = 1;
    surface->canvas.width = width;
    surface->canvas.height = height;
    surface->canvas.retain = surface_retain;
    surface->canvas.release = surface_release;
    surface->context = [[EAGLContext alloc] initWithAPI:page->context.API sharegroup:page->context.sharegroup];
    surface->layer = [[CAEAGLLayer alloc] init];
    if (!surface->context || !surface->layer) {
        surface_release(&surface->canvas);
        return NULL;
    }
    surface->canvas.layer = surface->layer;
    surface->layer.anchorPoint = CGPointZero;
    surface->layer.bounds = CGRectMake(0, 0, width, height);
    surface->layer.contentsScale = 1;
    surface->layer.opaque = opaque ? YES : NO;
    surface->layer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
        kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat, nil];

    EAGLContext *previous = [EAGLContext currentContext];
    int ok = [EAGLContext setCurrentContext:surface->context];
    if (ok) {
        static const GLfloat corners[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
        GLint actualWidth = 0, actualHeight = 0;
        glGenFramebuffers(1, &surface->framebuffer);
        glGenRenderbuffers(1, &surface->renderbuffer);
        glGenBuffers(1, &surface->buffer);
        glBindFramebuffer(GL_FRAMEBUFFER, surface->framebuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, surface->renderbuffer);
        ok = [surface->context renderbufferStorage:GL_RENDERBUFFER fromDrawable:surface->layer];
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, surface->renderbuffer);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &actualWidth);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &actualHeight);
        /* a canvas larger than the driver allows for a renderbuffer gets a smaller one, which would show a scaled frame */
        ok = ok && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
            && (unsigned)actualWidth == width && (unsigned)actualHeight == height;
        if (ok) {
            surface->program = surface_program(premultiplied);
            ok = surface->program != 0;
        }
        if (ok) {
            glBindBuffer(GL_ARRAY_BUFFER, surface->buffer);
            glBufferData(GL_ARRAY_BUFFER, sizeof corners, corners, GL_STATIC_DRAW);
            glUseProgram(surface->program);
            glUniform1i(glGetUniformLocation(surface->program, "s"), 0);
            glDisable(GL_DITHER);
            glViewport(0, 0, (GLsizei)width, (GLsizei)height);
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
            ok = glGetError() == GL_NO_ERROR;
        }
        if (!ok)
            surface_delete_objects(surface);
    }
    [EAGLContext setCurrentContext:previous];
    if (!ok) {
        surface_release(&surface->canvas);
        return NULL;
    }
    return surface;
}

yozora_gl_surface *yozora_gl_surface_create(yozora_gl_context *page, unsigned width, unsigned height, int opaque, int premultiplied)
{
    yozora_gl_enter();
    yozora_gl_surface *surface = surface_create(page, width, height, opaque, premultiplied);
    yozora_gl_leave();
    return surface;
}

yozora_canvas *yozora_gl_surface_canvas(yozora_gl_surface *surface)
{
    return surface ? &surface->canvas : NULL;
}

static int surface_present(yozora_gl_surface *surface, unsigned texture)
{
    if (!surface || !surface->context || !texture)
        return 0;
    /* the page context wrote the texture, the sharegroup sees those commands only after a flush of it */
    glFlush();
    EAGLContext *previous = [EAGLContext currentContext];
    if (![EAGLContext setCurrentContext:surface->context])
        return 0;
    glBindFramebuffer(GL_FRAMEBUFFER, surface->framebuffer);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindRenderbuffer(GL_RENDERBUFFER, surface->renderbuffer);
    int shown = glGetError() == GL_NO_ERROR && [surface->context presentRenderbuffer:GL_RENDERBUFFER];
    glBindTexture(GL_TEXTURE_2D, 0);
    [EAGLContext setCurrentContext:previous];
    return shown;
}

int yozora_gl_surface_present(yozora_gl_surface *surface, unsigned texture)
{
    yozora_gl_enter();
    int shown = surface_present(surface, texture);
    yozora_gl_leave();
    return shown;
}

static void surface_close(yozora_gl_surface *surface)
{
    if (!surface || !surface->context)
        return;
    EAGLContext *previous = [EAGLContext currentContext];
    if ([EAGLContext setCurrentContext:surface->context])
        surface_delete_objects(surface);
    [EAGLContext setCurrentContext:previous];
    [surface->context release];
    surface->context = nil;
}

void yozora_gl_surface_close(yozora_gl_surface *surface)
{
    yozora_gl_enter();
    surface_close(surface);
    yozora_gl_leave();
}
