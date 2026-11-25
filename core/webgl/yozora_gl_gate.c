/* the gate in front of the driver. ios ends an app that hands the graphics chip work while it is in the
   background, the process dies in the driver at its next submission (on ios 9 with an a5 from 1.5 s after
   applicationDidEnterBackground returned for home, from 0.35 s for a lock). the core thread can still be in a
   script then, because its pause waits for the script and the tasks queued before it, and while downloads go on
   in the background it runs page timers. while the gate is shut a call into the driver waits on the thread that
   made it until the gate opens, and the page goes on where it was: a call that was skipped instead would leave
   the webgl state of the page wrong. the calls of one thread nest (an entry point that calls another), only the
   outermost one waits or is counted */
#define _POSIX_C_SOURCE 200809L
#include "yozora_gl_internal.h"

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/time.h>
#include <time.h>

static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_changed = PTHREAD_COND_INITIALIZER;
/* read without the lock by every call and written with sequentially consistent atomics: a call that saw the
   gate open is counted before the shutting reads the count, a call counted after that read sees the gate shut */
static int gate_shut;
static unsigned gate_inside;

/* __thread is not available to the armv7 slice built for iOS 5, the depth of a thread is a key of the thread */
static pthread_key_t depth_key;
static pthread_once_t depth_once = PTHREAD_ONCE_INIT;

static void make_depth_key(void)
{
    pthread_key_create(&depth_key, NULL);
}

static uintptr_t depth(void)
{
    pthread_once(&depth_once, make_depth_key);
    return (uintptr_t)pthread_getspecific(depth_key);
}

static void set_depth(uintptr_t value)
{
    pthread_setspecific(depth_key, (void *)value);
}

void yozora_gl_enter(void)
{
    uintptr_t outer = depth();
    set_depth(outer + 1);
    if (outer)
        return;
    for (;;) {
        __atomic_add_fetch(&gate_inside, 1, __ATOMIC_SEQ_CST);
        if (!__atomic_load_n(&gate_shut, __ATOMIC_SEQ_CST))
            return;
        /* the call is taken back first, the shutting may be waiting for the count to reach zero */
        pthread_mutex_lock(&gate_lock);
        __atomic_sub_fetch(&gate_inside, 1, __ATOMIC_SEQ_CST);
        pthread_cond_broadcast(&gate_changed);
        while (__atomic_load_n(&gate_shut, __ATOMIC_SEQ_CST))
            pthread_cond_wait(&gate_changed, &gate_lock);
        pthread_mutex_unlock(&gate_lock);
    }
}

void yozora_gl_leave(void)
{
    uintptr_t outer = depth();
    /* a leave without its enter would take the count of another thread */
    if (!outer)
        return;
    set_depth(outer - 1);
    if (outer > 1)
        return;
    if (!__atomic_sub_fetch(&gate_inside, 1, __ATOMIC_SEQ_CST) && __atomic_load_n(&gate_shut, __ATOMIC_SEQ_CST)) {
        pthread_mutex_lock(&gate_lock);
        pthread_cond_broadcast(&gate_changed);
        pthread_mutex_unlock(&gate_lock);
    }
}

int yozora_gl_set_allowed(int allowed)
{
    int settled = 1;
    pthread_mutex_lock(&gate_lock);
    __atomic_store_n(&gate_shut, allowed ? 0 : 1, __ATOMIC_SEQ_CST);
    pthread_cond_broadcast(&gate_changed);
    if (!allowed) {
        /* a call that began before the gate shut ends in the driver in milliseconds, the second is a margin so
           that the app still leaves in time when one never does */
        struct timeval now;
        struct timespec until;
        gettimeofday(&now, NULL);
        until.tv_sec = now.tv_sec + 1;
        until.tv_nsec = (long)now.tv_usec * 1000;
        while (__atomic_load_n(&gate_inside, __ATOMIC_SEQ_CST)) {
            if (pthread_cond_timedwait(&gate_changed, &gate_lock, &until) == ETIMEDOUT) {
                settled = !__atomic_load_n(&gate_inside, __ATOMIC_SEQ_CST);
                break;
            }
        }
    }
    pthread_mutex_unlock(&gate_lock);
    return settled;
}
