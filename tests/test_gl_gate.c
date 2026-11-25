/* the gate in front of the driver (core/webgl/yozora_gl_gate.c). threads stand in for the core thread inside a
   gl call, a pause stands in for the driver */
#define _POSIX_C_SOURCE 200809L
#include "yozora_gl_internal.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define THREADS 4

static int failures;

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "test_gl_gate: %s:%d: %s\n", __FILE__, __LINE__, #condition); ++failures; } } while (0)

static void pause_ms(long ms)
{
    struct timespec t;
    t.tv_sec = ms / 1000;
    t.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&t, NULL);
}

static void start(pthread_t *thread, void *(*body)(void *), void *context)
{
    /* every later check waits for this thread, without it the test would hang */
    if (pthread_create(thread, NULL, body, context)) {
        fputs("test_gl_gate: no thread\n", stderr);
        exit(1);
    }
}

/* one call nested `depth` deep that stays `stay_ms` in the driver, with `late` it calls another at the end,
   after the gate shut */
typedef struct {
    unsigned depth;
    long stay_ms;
    int late;
    int inside;
    int done;
} stay;

static void *stay_inside(void *context)
{
    stay *call = context;
    unsigned level;
    for (level = 0; level < call->depth; ++level)
        yozora_gl_enter();
    __atomic_store_n(&call->inside, 1, __ATOMIC_SEQ_CST);
    pause_ms(call->stay_ms);
    if (call->late) {
        yozora_gl_enter();
        yozora_gl_leave();
    }
    __atomic_store_n(&call->done, 1, __ATOMIC_SEQ_CST);
    for (level = 0; level < call->depth; ++level)
        yozora_gl_leave();
    return NULL;
}

/* calls in a loop, nested `depth` deep, counted once they are through */
static int stop_loops;
static unsigned in_driver;

typedef struct {
    unsigned depth;
    unsigned long calls;
} loop;

static void *call_in_a_loop(void *context)
{
    loop *self = context;
    unsigned level;
    volatile unsigned spin;
    while (!__atomic_load_n(&stop_loops, __ATOMIC_SEQ_CST)) {
        for (level = 0; level < self->depth; ++level)
            yozora_gl_enter();
        __atomic_add_fetch(&in_driver, 1, __ATOMIC_SEQ_CST);
        for (spin = 0; spin < 2000; ++spin) {
        }
        __atomic_sub_fetch(&in_driver, 1, __ATOMIC_SEQ_CST);
        for (level = 0; level < self->depth; ++level)
            yozora_gl_leave();
        __atomic_add_fetch(&self->calls, 1, __ATOMIC_SEQ_CST);
    }
    return NULL;
}

/* the threads of `loops` that made a call since `before` */
static unsigned moved(const loop *loops, const unsigned long *before, unsigned threads)
{
    unsigned index, count = 0;
    for (index = 0; index < threads; ++index)
        count += __atomic_load_n(&loops[index].calls, __ATOMIC_SEQ_CST) > before[index];
    return count;
}

int main(void)
{
    /* a call in the driver as the gate shuts: the shutting waits for it to leave and gives up after a second.
       a call nested in one that is inside goes through a shut gate, or the two would wait for each other */
    static const struct { unsigned depth; long stay_ms; int late; int settled; } inside_cases[] = {
        { 0, 0, 0, 1 },
        { 1, 200, 0, 1 },
        { 2, 200, 0, 1 },
        { 64, 200, 0, 1 },
        { 1, 200, 1, 1 },
        { 1, 1500, 0, 0 },
        { 3, 1500, 0, 0 },
    };
    /* calls that come while the gate is shut: from one thread or several, nested or not */
    static const struct { unsigned threads; unsigned depth; } held_cases[] = {
        { 1, 1 }, { 1, 3 }, { THREADS, 1 }, { THREADS, 2 },
    };
    size_t i;
    for (i = 0; i < sizeof inside_cases / sizeof inside_cases[0]; ++i) {
        stay call = { inside_cases[i].depth, inside_cases[i].stay_ms, inside_cases[i].late, 0, 0 };
        pthread_t thread;
        int settled;
        start(&thread, stay_inside, &call);
        while (!__atomic_load_n(&call.inside, __ATOMIC_SEQ_CST))
            pause_ms(1);
        settled = yozora_gl_set_allowed(0);
        CHECK(settled == inside_cases[i].settled);
        /* settled means the call had left, given up means it was still there */
        if (call.depth)
            CHECK(__atomic_load_n(&call.done, __ATOMIC_SEQ_CST) == settled);
        CHECK(yozora_gl_set_allowed(1));
        CHECK(!pthread_join(thread, NULL));
    }
    for (i = 0; i < sizeof held_cases / sizeof held_cases[0]; ++i) {
        loop loops[THREADS];
        pthread_t threads[THREADS];
        unsigned long none[THREADS] = { 0 }, before[THREADS];
        unsigned count = held_cases[i].threads, index, waited;
        __atomic_store_n(&stop_loops, 0, __ATOMIC_SEQ_CST);
        for (index = 0; index < count; ++index) {
            loops[index].depth = held_cases[i].depth;
            loops[index].calls = 0;
            start(&threads[index], call_in_a_loop, &loops[index]);
        }
        for (waited = 0; waited < 2000 && moved(loops, none, count) < count; waited += 5)
            pause_ms(5);
        CHECK(moved(loops, none, count) == count);
        CHECK(yozora_gl_set_allowed(0));
        CHECK(!__atomic_load_n(&in_driver, __ATOMIC_SEQ_CST));
        /* a thread that had just left counts its call after the shutting returned */
        pause_ms(20);
        for (index = 0; index < count; ++index)
            before[index] = __atomic_load_n(&loops[index].calls, __ATOMIC_SEQ_CST);
        pause_ms(50);
        CHECK(!__atomic_load_n(&in_driver, __ATOMIC_SEQ_CST));
        CHECK(!moved(loops, before, count));
        /* each held thread goes on where it waited once the gate opens */
        CHECK(yozora_gl_set_allowed(1));
        for (waited = 0; waited < 2000 && moved(loops, before, count) < count; waited += 5)
            pause_ms(5);
        CHECK(moved(loops, before, count) == count);
        __atomic_store_n(&stop_loops, 1, __ATOMIC_SEQ_CST);
        for (index = 0; index < count; ++index)
            CHECK(!pthread_join(threads[index], NULL));
    }
    /* a leave without an enter keeps the count, or the next shutting would wait for a call that is not there */
    yozora_gl_leave();
    CHECK(yozora_gl_set_allowed(0));
    /* shutting a shut gate and opening an open one */
    CHECK(yozora_gl_set_allowed(0));
    CHECK(yozora_gl_set_allowed(1));
    CHECK(yozora_gl_set_allowed(1));
    if (failures)
        return 1;
    puts("gl gate: calls in the driver at the shutting, the second limit, held calls of one and of several threads, nesting and a stray leave passed");
    return 0;
}
