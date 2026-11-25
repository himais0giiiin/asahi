#ifndef YOZORA_GL_INTERNAL_H
#define YOZORA_GL_INTERNAL_H

#include "yozora_gl.h"

#ifdef __cplusplus
extern "C" {
#endif

/* what the entry points keep for the context current on the thread: ANGLE keeps the same in its own context
   and WebKit assumes it */
typedef struct yozora_gl_state {
    int version;
    /* an error of the entry points themselves (a function the driver does not have), reported before the error of the driver */
    unsigned pending_error;
    /* GL_ANGLE_pack_reverse_row_order, GL_PACK_ROW_LENGTH on ES 2.0 and the alignments, which the driver does
       not report back in a form that costs nothing */
    int pack_reverse_row_order;
    int pack_row_length;
    int pack_alignment;
    int unpack_alignment;
    /* the extension string the context shows, made on the first request */
    char *extensions;
} yozora_gl_state;

/* NULL when the thread has no current context */
yozora_gl_state *yozora_gl_current_state(void);

/* around each call of this layer into the driver, so that it waits while the gate of yozora_gl_gate.c is shut.
   calls nest on a thread and only the outermost one waits */
void yozora_gl_enter(void);
void yozora_gl_leave(void);

#ifdef __cplusplus
}
#endif
#endif
