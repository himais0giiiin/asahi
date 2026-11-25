#ifndef YOZORA_GL_H
#define YOZORA_GL_H

/* the part of the system OpenGL ES that WebGL needs: a context current on a thread without a window and the
   address of a driver function. EGL without a surface on the host (Mesa), EAGL on iOS. the context has no
   drawable, WebGL renders into its own framebuffer objects */

#include "../core/yozora_canvas.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct yozora_gl_context yozora_gl_context;
typedef struct yozora_gl_surface yozora_gl_surface;

/* version is 2 or 3, the context is exactly that version of OpenGL ES. NULL when the system has none */
yozora_gl_context *yozora_gl_context_create(int version);
int yozora_gl_context_version(const yozora_gl_context *context);
/* nonzero when the context is current on the calling thread */
int yozora_gl_context_make_current(yozora_gl_context *context);
/* the calling thread has no current context afterwards */
void yozora_gl_context_release_thread(void);
void yozora_gl_context_destroy(yozora_gl_context *context);

/* the address of a driver function of the current context, NULL when the driver has none */
void *yozora_gl_proc(const char *name);

/* the system ends an app that hands the graphics chip work while it is in the background (ios 9 on an a5: from
   1.5 s after applicationDidEnterBackground returned for home, from 0.35 s for a lock). 0 shuts the gate of
   yozora_gl_gate.c: from then on each call of this layer into the driver waits on the thread that made it until
   1 opens the gate again, so a page that was still drawing goes on where it was when the app is back. 0 returns
   nonzero once no call that began before it is still in the driver, 0 when one was still there after a second.
   the interface thread calls it (app/app_main.m), never from inside a call of this layer */
int yozora_gl_set_allowed(int allowed);

/* a native layer of width by height pixels that shows frames of a texture of `page` with no read back. all
   of these run on the thread that owns `page`, except the retain and release of the canvas, which any thread
   may call. NULL when the system has no such layer (the host) or the driver refuses it, the caller then reads
   the frame back. `opaque` is a layer with no alpha, `premultiplied` says how the texture holds its color.
   the caller owns the reference that this returns and drops it with canvas->release after the close */
yozora_gl_surface *yozora_gl_surface_create(yozora_gl_context *page, unsigned width, unsigned height, int opaque, int premultiplied);
yozora_canvas *yozora_gl_surface_canvas(yozora_gl_surface *surface);
/* draws the texture over the whole layer and shows it. `page` is current, nonzero when the frame is on its way to the screen */
int yozora_gl_surface_present(yozora_gl_surface *surface, unsigned texture);
/* frees what lives in the driver, before the context of the page goes. a closed surface keeps showing its last frame */
void yozora_gl_surface_close(yozora_gl_surface *surface);

#ifdef __cplusplus
}
#endif
#endif
