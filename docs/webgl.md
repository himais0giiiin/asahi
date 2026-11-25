# webgl

webgl 1 and webgl 2, always on, there is no switch.

## how

webkit keeps its own context code, written against angle. angle itself is not built, only its headers are used: `core/webgl` makes the entry points of angle (`GL_*`) over the opengl es of the system.

- ios: eagl, es 2.0 on every device, es 3.0 from ios 7 on an a7 or later, so webgl 2 only there
- host: egl without a surface (mesa)
- the shim adds what angle did: the extension list, `*RobustANGLE` calls, reverse row order for reads, zeroed new buffers and texture images, `KHR_debug` that never fires

## the canvas

`core/webcore/GraphicsContextGLYozora.cpp` is the context. when the page asks to display, the frame goes one of two ways.

- ios, armv7 and arm64: the context makes a `CAEAGLLayer` of the size of the drawing buffer (`yozora_gl_surface_create`, `core/webgl/yozora_gl_eagl.m`) and a second EAGL context in the same sharegroup. after a `glFlush` of the page context that context draws the texture of the drawing buffer over the layer and presents it. no pixel crosses the processor and the layer of the canvas is not recorded again for a frame. `YZSceneView` puts the `CAEAGLLayer` into the contents layer of the canvas, over its tiles, and places it by position and scale, never by bounds, because the bounds are the pixels of the context. the scene holds a reference to it (`yozora_canvas`) for as long as it can be shown
- host: Mesa has no layer to present into, `yozora_gl_surface_create` answers NULL and the frame is read back with `glReadPixels` into a picture that `GraphicsLayerYozora` draws in the layer of the canvas. the same path takes over on a phone when the system refuses a layer or a frame, once per size of the canvas, and says so in the log

a native layer costs three buffers of the size of the canvas (the swap chain of Core Animation). a canvas of 2048 by 2048 holds 48 MB of them. `renderInContext` does not draw the layer, so a preview made that way shows the canvas empty.

## the background

ios ends an app that hands the graphics chip work while it is in the background: the process dies in the driver at its next submission, with `gpusSubmitDataBuffers` on top of the crash record. measured on ios 9 with an a5: from 1.5 to 1.65 s after `applicationDidEnterBackground` returned after the home button, from 0.35 s after a lock. the core thread can still draw then. its pause waits for the script that runs and the tasks queued before it, and while downloads go on in the background it runs page timers.

so the gl layer has a gate (`core/webgl/yozora_gl_gate.c`). every call of the layer into the driver passes it: the forwarded entry points, the ones written by hand, and the context and canvas layer calls of `yozora_gl_eagl.m`. the app shuts it as the last thing in `applicationDidEnterBackground` with `yozora_gl_set_allowed(0)`, which returns once no call that began before is still in the driver, or after a second, and opens it first in `applicationWillEnterForeground`. a call made while it is shut waits on its thread and goes on when the app is back, so the page keeps its webgl state: a call that was skipped would leave it wrong. the calls of one thread nest and only the outermost one waits. a page that stopped drawing by itself is never held, a page in the middle of a frame as the app leaves is held like a script that runs on. the core thread then holds what is queued behind it until the app is back: the writes of local storage and of the bytecode cache that `applicationDidEnterBackground` asks for and, in the quiet run of [downloads](downloads.md), the transfers. the host never shuts the gate.

## what a driver does not do

angle checked these, the driver does not, and a page that breaks a rule gets what the driver does with it:

- draw calls are not checked against the rules of webgl: out of range indices, feedback loops, sampler types
- renderbuffers and `texStorage` images are not zeroed
- no antialiasing on es 2.0
- no timer queries
- no `OffscreenCanvas` or webgl in workers

webgl in a video texture is not done.

## debug

`YOZORA_GL_TRACE=1` names every forwarded call that left an error of the driver. it reads the error itself, so the page never sees it.

## tests

- `tests/test_gles_shim.cpp`: the entry points on a host driver
- `tests/test_gl_gate.c`: the shutting waits for a call that is in the driver and gives up after a second, a shut gate holds every call of one thread or of several, nested ones too, until it opens, the held threads go on, a leave without an enter keeps the count
- `tests/test_core_webgl.py`: a page of webgl 1 and of webgl 2 drawn and read back, and the canvas in the picture of the page
- `tests/test_scene_raster.cpp` (`testCanvasSurface`): a native canvas layer reaches the scene with its rectangle and no tile, and the scene keeps the surface alive after the recording is gone
- `tests/test_core_webgl_option.py`: the option of the core
