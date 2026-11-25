#import "YZCrash.h"

#import <UIKit/UIKit.h>

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

#include "yozora_core.h"

// a block that writes from a signal handler cannot allocate, take a lock or send a message: everything it prints is made at
// install or read from the kernel, and numbers are formatted by hand. the same writers serve the watchdog thread, which
// holds other threads stopped while it samples them and so must not allocate either until it has let them go

static const off_t YZCrashFileCap = 256 * 1024;
static const int YZCrashSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS };

// the main thread is told from the others by its mach port, saved at install
static mach_port_t YZCrashMainThread;

static int YZCrashFD = -1;
static char YZCrashAppLine[160];
static char YZCrashSystemLine[160];
static char YZCrashBinaryLine[160];
static NSUncaughtExceptionHandler *YZCrashPreviousHandler;
static BOOL YZCrashPreviousCrashed;
static struct sigaction YZCrashPrevious[sizeof YZCrashSignals / sizeof YZCrashSignals[0]];
static char YZCrashStack[64 * 1024];

// the ring of notes, written by the app and read by the handlers. a screen of notes is not enough to see what led to a crash in a
// pool: the last forty eight
#define YZCrashNoteCount 48
#define YZCrashNoteLength 120
static char YZCrashNotes[YZCrashNoteCount][YZCrashNoteLength];
static volatile unsigned YZCrashNoteTotal;
static time_t YZCrashStarted;

// a block also goes to stderr so the log holds it
static volatile sig_atomic_t YZCrashEcho;
// set by the first fault: later faults and the watchdog leave the file alone
static volatile int YZCrashInHandler;
static volatile int YZCrashAfterException;

static void YZCrashWrite(const char *text) {
    size_t length = strlen(text);
    if (YZCrashFD >= 0)
        write(YZCrashFD, text, length);
    if (YZCrashEcho)
        write(STDERR_FILENO, text, length);
}

// decimal and hexadecimal without printf, which is not safe inside a signal handler
static void YZCrashNumber(unsigned long long value, unsigned base, char *out) {
    char digits[24];
    size_t n = 0;
    do {
        digits[n++] = "0123456789abcdef"[value % base];
        value /= base;
    } while (value && n < sizeof digits);
    size_t at = 0;
    if (base == 16) {
        out[at++] = '0';
        out[at++] = 'x';
    }
    while (n)
        out[at++] = digits[--n];
    out[at] = '\0';
}

static void YZCrashField(const char *name, unsigned long long value, unsigned base) {
    char number[32];
    YZCrashNumber(value, base, number);
    YZCrashWrite(name);
    YZCrashWrite(number);
}

// "label  text" with the label padded to nine columns, so a block reads as a table
static void YZCrashRow(const char *label, const char *text) {
    char padded[16];
    size_t length = strlen(label);
    if (length > 9)
        length = 9;
    memcpy(padded, label, length);
    while (length < 9)
        padded[length++] = ' ';
    padded[length++] = ' ';
    padded[length] = '\0';
    YZCrashWrite(padded);
    YZCrashWrite(text);
    YZCrashWrite("\n");
}

// "YYYY-MM-DD HH:MM:SS UTC" from the epoch without localtime, which takes a lock
static void YZCrashDate(time_t when, char *out, size_t capacity) {
    long long seconds = (long long)when;
    long long days = seconds / 86400, rest = seconds % 86400;
    if (rest < 0) {
        rest += 86400;
        --days;
    }
    days += 719468;
    long long era = (days >= 0 ? days : days - 146096) / 146097;
    long long dayOfEra = days - era * 146097;
    long long yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365;
    long long year = yearOfEra + era * 400;
    long long dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
    long long shifted = (5 * dayOfYear + 2) / 153;
    long long day = dayOfYear - (153 * shifted + 2) / 5 + 1;
    long long month = shifted < 10 ? shifted + 3 : shifted - 9;
    if (month <= 2)
        ++year;
    char text[32];
    size_t at = 0;
    long long parts[6] = { year, month, day, rest / 3600, (rest / 60) % 60, rest % 60 };
    const char separators[6] = { '-', '-', ' ', ':', ':', ' ' };
    for (int i = 0; i < 6; ++i) {
        char number[24];
        YZCrashNumber((unsigned long long)parts[i], 10, number);
        size_t length = strlen(number);
        if (i > 0 && length < 2)
            text[at++] = '0';
        memcpy(text + at, number, length);
        at += length;
        text[at++] = separators[i];
    }
    memcpy(text + at, "UTC", 4);
    strlcpy(out, text, capacity);
}

static unsigned long long YZCrashMonotonicMs(void) {
    static mach_timebase_info_data_t base;
    if (!base.denom)
        mach_timebase_info(&base);
    return mach_absolute_time() * base.numer / base.denom / 1000000ULL;
}

// the run marker: a small file mapped shared, so a plain store reaches it even when the process is killed a moment later. the next launch
// reads it to tell a clean end from a kill that the app could not see
#define YZCrashRunMagic 0x797a7231u
enum { YZCrashRunNone = 0, YZCrashRunForeground = 1, YZCrashRunBackground = 2, YZCrashRunClean = 3, YZCrashRunCrashed = 4 };
typedef struct {
    uint32_t magic;
    uint32_t state;
    uint32_t hanging;
    int32_t pid;
    int64_t started;
    int64_t updated;
    uint64_t resident;
    uint64_t free;
    char app[96];
    char screen[96];
    char note[YZCrashNoteLength];
} YZCrashRun;
static YZCrashRun *YZCrashRunState;

static void YZCrashSetRunState(uint32_t state) {
    if (!YZCrashRunState)
        return;
    YZCrashRunState->state = state;
    YZCrashRunState->updated = (int64_t)time(NULL);
}

// resident and free memory from the kernel. free counts the inactive pages, which the system takes back before it kills anything
static void YZCrashMemory(unsigned long long *resident, unsigned long long *available) {
    *resident = 0;
    *available = 0;
    struct task_basic_info basic;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&basic, &count) == KERN_SUCCESS)
        *resident = basic.resident_size;
    vm_statistics_data_t vm;
    mach_msg_type_number_t vm_count = HOST_VM_INFO_COUNT;
    vm_size_t page = 4096;
    host_page_size(mach_host_self(), &page);
    if (host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vm, &vm_count) == KERN_SUCCESS)
        *available = ((unsigned long long)vm.free_count + vm.inactive_count) * page;
}

static void YZCrashMegabytes(unsigned long long bytes, char *out) {
    char number[32];
    YZCrashNumber(bytes / (1024 * 1024), 10, number);
    strlcpy(out, number, 32);
    strlcat(out, " MB", 32);
}

static void YZCrashMemoryRow(void) {
    unsigned long long resident, available;
    YZCrashMemory(&resident, &available);
    char a[32], b[32], line[96] = "app holds ";
    YZCrashMegabytes(resident, a);
    YZCrashMegabytes(available, b);
    strlcat(line, a, sizeof line);
    strlcat(line, ", the system has ", sizeof line);
    strlcat(line, b, sizeof line);
    strlcat(line, " free or reclaimable", sizeof line);
    YZCrashRow("memory", line);
}

static const char *YZCrashSignalName(int number) {
    switch (number) {
    case SIGSEGV: return "SIGSEGV (segmentation fault)";
    case SIGBUS: return "SIGBUS (bus error)";
    case SIGILL: return "SIGILL (illegal instruction)";
    case SIGFPE: return "SIGFPE (arithmetic fault)";
    case SIGABRT: return "SIGABRT (abort)";
    case SIGTRAP: return "SIGTRAP (trap instruction)";
    case SIGSYS: return "SIGSYS (bad system call)";
    }
    return "signal";
}

// the code of the first part of the report of a block: what, when, where
static void YZCrashHeader(const char *kind) {
    char date[32];
    YZCrashDate(time(NULL), date, sizeof date);
    YZCrashWrite("\n==== ");
    YZCrashWrite(kind);
    YZCrashWrite(" ");
    YZCrashWrite(date);
    YZCrashWrite(" ====\n");
}

// "foreground for 62 s" and the screen, from the marker
static void YZCrashSituation(void) {
    char line[64];
    char number[24];
    YZCrashNumber((unsigned long long)(time(NULL) - YZCrashStarted), 10, number);
    strlcpy(line, YZCrashRunState && YZCrashRunState->state == YZCrashRunBackground ? "background, " : "foreground, ", sizeof line);
    strlcat(line, number, sizeof line);
    strlcat(line, " s after the launch", sizeof line);
    YZCrashRow("state", line);
    YZCrashRow("app", YZCrashAppLine);
    YZCrashRow("binary", YZCrashBinaryLine);
    YZCrashRow("system", YZCrashSystemLine);
    YZCrashMemoryRow();
    if (YZCrashRunState && YZCrashRunState->screen[0])
        YZCrashRow("screen", YZCrashRunState->screen);
}

static void YZCrashNotesWrite(void) {
    unsigned total = YZCrashNoteTotal;
    if (!total)
        return;
    YZCrashWrite("notes, oldest first:\n");
    for (unsigned i = total > YZCrashNoteCount ? total - YZCrashNoteCount : 0; i < total; ++i) {
        YZCrashWrite("  ");
        YZCrashWrite(YZCrashNotes[i % YZCrashNoteCount]);
        YZCrashWrite("\n");
    }
}

// the image that holds an address and the offset into it, from dyld's tables: no allocation and no lock. an address in no image is
// generated code (the jit) or a jump into nothing
static int YZCrashFindImage(uintptr_t address, const char **name, uintptr_t *offset, int *is_app) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header)
            continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
#ifdef __LP64__
        const struct load_command *command = (const struct load_command *)((const char *)header + sizeof(struct mach_header_64));
#else
        const struct load_command *command = (const struct load_command *)((const char *)header + sizeof(struct mach_header));
#endif
        for (uint32_t c = 0; c < header->ncmds; ++c) {
#ifdef __LP64__
            if (command->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
#else
            if (command->cmd == LC_SEGMENT) {
                const struct segment_command *segment = (const struct segment_command *)command;
#endif
                uintptr_t low = (uintptr_t)(segment->vmaddr + slide), high = low + (uintptr_t)segment->vmsize;
                if (address >= low && address < high && segment->vmsize) {
                    const char *path = _dyld_get_image_name(i);
                    const char *slash = path ? strrchr(path, '/') : NULL;
                    *name = slash ? slash + 1 : (path ? path : "?");
                    *offset = address - (uintptr_t)header;
                    *is_app = i == 0;
                    return 1;
                }
            }
            command = (const struct load_command *)((const char *)command + command->cmdsize);
        }
    }
    return 0;
}

// the words of a stack, read with vm_read_overwrite: a bad frame pointer answers with an error where a plain load would fault inside the handler
static int YZCrashRead(uintptr_t address, void *out, size_t length) {
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)address, (vm_size_t)length, (vm_address_t)out, &got) == KERN_SUCCESS && got == length;
}

#define YZCrashFrameCap 32
#define YZCrashThreadCap 48

typedef struct {
    mach_port_t port;
    int running;
    int cpu;
    int sampled;
    char name[40];
    uintptr_t pc, lr, sp, fp;
    uintptr_t registers[30];
    unsigned register_count;
    uintptr_t frames[YZCrashFrameCap];
    unsigned frame_count;
} YZCrashThread;
static YZCrashThread YZCrashThreads[YZCrashThreadCap];
static unsigned YZCrashThreadTotal;

// the frames of a stack by the frame pointer chain (r7 on armv7, x29 on arm64), the pc and the link register first. a leaf function does
// not save lr, so the caller of the leaf is the link register and not the first saved word
static void YZCrashWalk(YZCrashThread *thread) {
    unsigned n = 0;
    thread->frames[n++] = thread->pc;
    if (thread->lr && thread->lr != thread->pc)
        thread->frames[n++] = thread->lr;
    uintptr_t frame = thread->fp, previous = 0;
    while (n < YZCrashFrameCap && frame && !(frame & (sizeof(uintptr_t) - 1)) && frame > previous) {
        uintptr_t pair[2];
        if (!YZCrashRead(frame, pair, sizeof pair))
            break;
        if (pair[1] && pair[1] != thread->frames[n - 1])
            thread->frames[n++] = pair[1];
        previous = frame;
        frame = pair[0];
    }
    thread->frame_count = n;
}

static void YZCrashTakeState(YZCrashThread *thread, const ucontext_t *context) {
    __typeof__(context->uc_mcontext) machine = context->uc_mcontext;
    if (!machine)
        return;
#if defined(__arm__)
    for (unsigned i = 0; i < 13; ++i)
        thread->registers[i] = machine->__ss.__r[i];
    thread->register_count = 13;
    thread->sp = machine->__ss.__sp;
    thread->lr = machine->__ss.__lr;
    thread->pc = machine->__ss.__pc;
    thread->fp = machine->__ss.__r[7];
#elif defined(__arm64__)
    for (unsigned i = 0; i < 29; ++i)
        thread->registers[i] = (uintptr_t)machine->__ss.__x[i];
    thread->register_count = 29;
    thread->sp = (uintptr_t)machine->__ss.__sp;
    thread->lr = (uintptr_t)machine->__ss.__lr;
    thread->pc = (uintptr_t)machine->__ss.__pc;
    thread->fp = (uintptr_t)machine->__ss.__fp;
#endif
    thread->sampled = 1;
}

// flavor 5 of thread_info, the one that carries the name. the headers of the old sdk used for the armv7 link do not have it
typedef struct {
    uint64_t user_time, system_time;
    int32_t cpu_usage, policy, run_state, flags, sleep_time, current_priority, priority, max_priority;
    char name[64];
} YZCrashThreadExtended;

static void YZCrashThreadName(mach_port_t port, char *out, size_t capacity) {
    out[0] = '\0';
    YZCrashThreadExtended extended;
    mach_msg_type_number_t count = sizeof extended / sizeof(natural_t);
    if (thread_info(port, 5, (thread_info_t)&extended, &count) != KERN_SUCCESS)
        return;
    extended.name[sizeof extended.name - 1] = '\0';
    size_t at = 0;
    for (size_t i = 0; extended.name[i] && at + 1 < capacity; ++i)
        if ((unsigned char)extended.name[i] >= 32 && (unsigned char)extended.name[i] < 127)
            out[at++] = extended.name[i];
    out[at] = '\0';
}

// stops every thread but the caller one at a time, reads its registers and stack into the static table and lets it go. the table is
// the only thing written while a thread is stopped: a stopped thread may hold the lock of malloc
static void YZCrashCollect(const ucontext_t *own_context) {
    YZCrashThreadTotal = 0;
    mach_port_t self = mach_thread_self();
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
        return;
    for (mach_msg_type_number_t i = 0; i < count && YZCrashThreadTotal < YZCrashThreadCap; ++i) {
        YZCrashThread *thread = &YZCrashThreads[YZCrashThreadTotal];
        memset(thread, 0, sizeof *thread);
        thread->port = threads[i];
        YZCrashThreadName(threads[i], thread->name, sizeof thread->name);
        thread_basic_info_data_t basic;
        mach_msg_type_number_t basic_count = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &basic_count) == KERN_SUCCESS) {
            thread->running = basic.run_state;
            thread->cpu = basic.cpu_usage / 10;
        }
        if (threads[i] == self) {
            if (own_context)
                YZCrashTakeState(thread, own_context);
        } else if (thread_suspend(threads[i]) == KERN_SUCCESS) {
#if defined(__arm__)
            arm_thread_state_t state;
            mach_msg_type_number_t state_count = ARM_THREAD_STATE_COUNT;
            if (thread_get_state(threads[i], ARM_THREAD_STATE, (thread_state_t)&state, &state_count) == KERN_SUCCESS) {
                for (unsigned r = 0; r < 13; ++r)
                    thread->registers[r] = state.__r[r];
                thread->register_count = 13;
                thread->sp = state.__sp;
                thread->lr = state.__lr;
                thread->pc = state.__pc;
                thread->fp = state.__r[7];
                thread->sampled = 1;
            }
#elif defined(__arm64__)
            arm_thread_state64_t state;
            mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&state, &state_count) == KERN_SUCCESS) {
                for (unsigned r = 0; r < 29; ++r)
                    thread->registers[r] = (uintptr_t)state.__x[r];
                thread->register_count = 29;
                thread->sp = (uintptr_t)state.__sp;
                thread->lr = (uintptr_t)state.__lr;
                thread->pc = (uintptr_t)state.__pc;
                thread->fp = (uintptr_t)state.__fp;
                thread->sampled = 1;
            }
#endif
            if (thread->sampled)
                YZCrashWalk(thread);
            thread_resume(threads[i]);
        }
        if (threads[i] == self && thread->sampled)
            YZCrashWalk(thread);
        ++YZCrashThreadTotal;
    }
    for (mach_msg_type_number_t i = 0; i < count; ++i)
        mach_port_deallocate(mach_task_self(), threads[i]);
    mach_port_deallocate(mach_task_self(), self);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
}

static const char *YZCrashRunStateName(int state) {
    switch (state) {
    case TH_STATE_RUNNING: return "running";
    case TH_STATE_STOPPED: return "stopped";
    case TH_STATE_WAITING: return "waiting";
    case TH_STATE_UNINTERRUPTIBLE: return "blocked in the kernel";
    case TH_STATE_HALTED: return "halted";
    }
    return "unknown";
}

static void YZCrashFrame(unsigned index, uintptr_t address, int symbolize) {
    YZCrashField("    #", index, 10);
    YZCrashField(" ", address, 16);
    const char *name;
    uintptr_t offset;
    int is_app = 0;
    // a return address points after the call, the symbol of the call is one instruction back. the offset printed is of the address itself
    if (!YZCrashFindImage(address, &name, &offset, &is_app)) {
        YZCrashWrite(address < 4096 ? "  null address\n" : "  in no image: generated code (jit) or a jump into nothing\n");
        return;
    }
    YZCrashWrite("  ");
    YZCrashWrite(name);
    YZCrashField(" +", offset, 10);
    // exported names of a system library are right, those of the app binary are not: its functions are local and the nearest exported
    // name is far off. the app is read with tools/yozora_record.py and the map of the build
    if (symbolize && !is_app) {
        Dl_info info;
        if (dladdr((void *)address, &info) && info.dli_sname) {
            YZCrashWrite("  ");
            YZCrashWrite(info.dli_sname);
        }
    }
    YZCrashWrite("\n");
}

static void YZCrashThreadWrite(const YZCrashThread *thread, const char *mark, int symbolize) {
    YZCrashWrite("\nthread ");
    if (thread->port == YZCrashMainThread)
        YZCrashWrite("main");
    else
        YZCrashField("#", thread->port, 10);
    if (thread->name[0]) {
        YZCrashWrite(" \"");
        YZCrashWrite(thread->name);
        YZCrashWrite("\"");
    }
    if (mark[0]) {
        YZCrashWrite(" ");
        YZCrashWrite(mark);
    }
    YZCrashWrite(": ");
    YZCrashWrite(YZCrashRunStateName(thread->running));
    YZCrashField(", cpu ", (unsigned)thread->cpu, 10);
    YZCrashWrite("%\n");
    if (!thread->sampled) {
        YZCrashWrite("    state not readable\n");
        return;
    }
    for (unsigned i = 0; i < thread->frame_count; ++i)
        YZCrashFrame(i, thread->frames[i], symbolize);
}

static void YZCrashRegistersWrite(const YZCrashThread *thread) {
    if (!thread->register_count)
        return;
    YZCrashWrite("registers:");
    for (unsigned i = 0; i < thread->register_count; ++i) {
        char name[12] = " r";
#if defined(__arm64__)
        name[1] = 'x';
#endif
        YZCrashNumber(i, 10, name + 2);
        strlcat(name, "=", sizeof name);
        YZCrashField(name, thread->registers[i], 16);
    }
    YZCrashField(" sp=", thread->sp, 16);
    YZCrashField(" lr=", thread->lr, 16);
    YZCrashField(" pc=", thread->pc, 16);
    YZCrashWrite("\n");
}

// the halfwords of code around an address, so a call through a register shows which register: the instruction before a return address
// is the call, and the register it names is the one that held the null. read safely, an address in no image may be unmapped
static void YZCrashCodeWrite(const char *label, uintptr_t address) {
    if (address < 4096)
        return;
    uintptr_t start = (address & ~(uintptr_t)1) - 12;
    uint16_t words[10];
    if (!YZCrashRead(start, words, sizeof words))
        return;
    YZCrashWrite(label);
    YZCrashField(" ", start, 16);
    YZCrashWrite(":");
    for (unsigned i = 0; i < 10; ++i) {
        char number[16];
        YZCrashNumber(words[i], 16, number);
        YZCrashWrite(" ");
        YZCrashWrite(number + 2);
    }
    YZCrashWrite("\n");
}

// what the fault says, in words. every line is a reading of the numbers above it and says how sure it is
static void YZCrashVerdict(int signal_number, int code, uintptr_t fault, const YZCrashThread *thread) {
    uintptr_t pc = thread->pc;
    const char *name;
    uintptr_t offset;
    int is_app;
    int in_image = YZCrashFindImage(pc, &name, &offset, &is_app);
    if (signal_number == SIGSEGV || signal_number == SIGBUS) {
        if (pc < 4096) {
            YZCrashRow("verdict", "the thread jumped to address 0: a call through a null function pointer or a null entry point of a function");
            YZCrashRow("", "the return address of the caller is the first frame below, and the instruction before it names the register");
        } else if (!in_image) {
            YZCrashRow("verdict", "the thread ran code that is in no image: generated code (the jit) that is damaged, freed or not executable");
        } else if (fault < 4096) {
            char line[96] = "the thread read or wrote through a null pointer, at offset ";
            char number[24];
            YZCrashNumber(fault, 10, number);
            strlcat(line, number, sizeof line);
            YZCrashRow("verdict", line);
        } else if (thread->sp && fault + 64 * 1024 > thread->sp && fault < thread->sp + 64 * 1024) {
            YZCrashRow("verdict", "the fault is next to the stack pointer: the stack is probably full, a recursion without an end");
        } else if (fault == pc) {
            YZCrashRow("verdict", "the thread jumped to a page that is not executable or not mapped");
        } else {
            YZCrashRow("verdict", "the thread used an address that is not mapped or not allowed: a freed or damaged pointer");
        }
        if (code == 1)
            YZCrashRow("", "the page of the address is not mapped");
        else if (code == 2)
            YZCrashRow("", "the page is mapped, the access is not allowed (write to code, jump to data)");
    } else if (signal_number == SIGABRT) {
        YZCrashRow("verdict", "the app called abort(): an assertion, an uncaught exception or a failed runtime check, the last log lines say which");
    } else if (signal_number == SIGILL || signal_number == SIGTRAP) {
        YZCrashRow("verdict", in_image ? "a trap instruction: a runtime check that failed on purpose" : "an instruction that does not exist, in code that is in no image: generated code that is damaged");
    } else if (signal_number == SIGFPE) {
        YZCrashRow("verdict", "an arithmetic fault, a division of integers by zero");
    }
}

// the system gets the crash too: with the default action restored the signal ends the process the way it would have
static void YZCrashRestoreDefaults(void) {
    for (size_t i = 0; i < sizeof YZCrashSignals / sizeof YZCrashSignals[0]; ++i)
        signal(YZCrashSignals[i], SIG_DFL);
}

static void YZCrashSignalHandler(int signal_number, siginfo_t *info, void *context) {
    if (!__sync_bool_compare_and_swap(&YZCrashInHandler, 0, 1)) {
        // a fault inside the handler: nothing more can be written
        YZCrashRestoreDefaults();
        raise(signal_number);
        return;
    }
    YZCrashEcho = 1;
    YZCrashSetRunState(YZCrashRunCrashed);
    int code = info ? info->si_code : 0;
    uintptr_t fault = (uintptr_t)(info ? info->si_addr : NULL);
    if (YZCrashAfterException) {
        // the uncaught exception above ends in abort(), the same crash a second time adds nothing
        YZCrashWrite("\nthe abort that follows the exception above\n");
    } else {
        YZCrashHeader("CRASH");
        YZCrashRow("what", YZCrashSignalName(signal_number));
        {
            char line[96] = "code ";
            char code_text[24], fault_text[32];
            YZCrashNumber((unsigned)code, 10, code_text);
            YZCrashNumber(fault, 16, fault_text);
            strlcat(line, code_text, sizeof line);
            strlcat(line, ", fault address ", sizeof line);
            strlcat(line, fault_text, sizeof line);
            YZCrashRow("detail", line);
        }
        // the first fault stops the watchdog from writing over this block, a second thread of the app may still run until it is stopped
        YZCrashCollect((const ucontext_t *)context);
        YZCrashThread *crashed = NULL;
        mach_port_t self = mach_thread_self();
        for (unsigned i = 0; i < YZCrashThreadTotal; ++i)
            if (YZCrashThreads[i].port == self)
                crashed = &YZCrashThreads[i];
        mach_port_deallocate(mach_task_self(), self);
        if (crashed)
            YZCrashVerdict(signal_number, code, fault, crashed);
        YZCrashSituation();
        YZCrashNotesWrite();
        if (crashed) {
            YZCrashWrite("\n");
            YZCrashRegistersWrite(crashed);
            YZCrashCodeWrite("code at pc", crashed->pc);
            YZCrashCodeWrite("code at lr", crashed->lr);
            // the symbol lookup takes a lock of dyld that the crashed thread may hold: an alarm ends the process then instead of a hang
            alarm(3);
            YZCrashThreadWrite(crashed, "CRASHED", 1);
        }
        YZCrashWrite("\nother threads, as they were stopped:\n");
        for (unsigned i = 0; i < YZCrashThreadTotal; ++i)
            if (&YZCrashThreads[i] != crashed)
                YZCrashThreadWrite(&YZCrashThreads[i], "", 1);
        alarm(0);
    }
    if (YZCrashFD >= 0)
        fsync(YZCrashFD);
    // the log capture reads the app's stderr on its own thread and writes the file: the last line before a stop (a zombie
    // names its class there) is on its way when this handler starts, so the stop waits a moment for it
    struct timespec pause = { 0, 300 * 1000 * 1000 };
    nanosleep(&pause, NULL);
    YZCrashRestoreDefaults();
    // a fault that the hardware raised is raised again by the same instruction when the handler returns, on the same thread, and the
    // system report names that thread and that pc. raise() sent it to the process instead, the main thread took it and the report of
    // ios 8 named the main thread, idle in mach_msg, while the fault was in the core thread
    int hardware = signal_number != SIGABRT && code > 0 && code < 0x10000;
    if (!hardware)
        pthread_kill(pthread_self(), signal_number);
}

static void YZCrashException(NSException *exception) {
    if (!__sync_bool_compare_and_swap(&YZCrashInHandler, 0, 1)) {
        if (YZCrashPreviousHandler)
            YZCrashPreviousHandler(exception);
        return;
    }
    YZCrashEcho = 1;
    YZCrashAfterException = 1;
    YZCrashSetRunState(YZCrashRunCrashed);
    YZCrashHeader("CRASH");
    YZCrashRow("what", "uncaught Objective-C exception");
    YZCrashRow("detail", [[NSString stringWithFormat:@"%@: %@", [exception name], [exception reason]] UTF8String]);
    YZCrashRow("verdict", "an exception that nothing caught: the reason above and the stack below say what threw it");
    YZCrashSituation();
    YZCrashNotesWrite();
    YZCrashWrite("\nstack of the throwing thread:\n");
    NSArray *symbols = [exception callStackSymbols];
    NSArray *addresses = [exception callStackReturnAddresses];
    for (NSUInteger i = 0; i < [symbols count]; ++i) {
        YZCrashField("    #", i, 10);
        YZCrashWrite("  ");
        YZCrashWrite([[symbols objectAtIndex:i] UTF8String]);
        YZCrashWrite("\n");
    }
    // the raw addresses of the app frames, for the map of the build: the symbols above are the exported ones only
    if ([addresses count]) {
        YZCrashWrite("addresses:");
        for (NSNumber *address in addresses) {
            const char *name;
            uintptr_t offset;
            int is_app = 0;
            if (YZCrashFindImage((uintptr_t)[address unsignedLongLongValue], &name, &offset, &is_app) && is_app)
                YZCrashField(" Yozora+", offset, 10);
        }
        YZCrashWrite("\n");
    }
    if (YZCrashFD >= 0)
        fsync(YZCrashFD);
    if (YZCrashPreviousHandler)
        YZCrashPreviousHandler(exception);
}

// "uuid ... slide 0x..." of the main binary
static void YZCrashDescribeBinary(void) {
    const struct mach_header *header = _dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    char uuid[40] = "unknown";
    if (header) {
#ifdef __LP64__
        const struct load_command *command = (const struct load_command *)((const char *)header + sizeof(struct mach_header_64));
#else
        const struct load_command *command = (const struct load_command *)((const char *)header + sizeof(struct mach_header));
#endif
        for (uint32_t i = 0; i < header->ncmds; ++i) {
            if (command->cmd == LC_UUID) {
                const struct uuid_command *found = (const struct uuid_command *)command;
                char *out = uuid;
                for (int b = 0; b < 16; ++b)
                    out += snprintf(out, 3, "%02X", found->uuid[b]);
                break;
            }
            command = (const struct load_command *)((const char *)command + command->cmdsize);
        }
    }
    snprintf(YZCrashBinaryLine, sizeof YZCrashBinaryLine, "uuid %s, slide 0x%lx, offsets in this block are from the load address", uuid, (unsigned long)slide);
}

static void YZCrashDescribeSystem(void) {
    char model[32] = "unknown", build[32] = "";
    size_t size = sizeof model;
    sysctlbyname("hw.machine", model, &size, NULL, 0);
    size = sizeof build;
    sysctlbyname("kern.osversion", build, &size, NULL, 0);
    uint64_t memory = 0;
    size = sizeof memory;
    if (sysctlbyname("hw.memsize", &memory, &size, NULL, 0) != 0 || size != sizeof memory) {
        uint32_t small = 0;
        size = sizeof small;
        sysctlbyname("hw.physmem", &small, &size, NULL, 0);
        memory = small;
    }
    const char *version = [[[UIDevice currentDevice] systemVersion] UTF8String];
    snprintf(YZCrashSystemLine, sizeof YZCrashSystemLine, "%s, iOS %s (%s), %llu MB of memory", model, version ? version : "?", build, (unsigned long long)(memory / (1024 * 1024)));
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    const char *arch =
#if defined(__arm64__)
        "arm64";
#elif defined(__arm__)
        "armv7";
#else
        "unknown";
#endif
    snprintf(YZCrashAppLine, sizeof YZCrashAppLine, "Yozora %s (%s) %s, pid %d",
             [[info objectForKey:@"CFBundleShortVersionString"] UTF8String] ?: "?", [[info objectForKey:@"CFBundleVersion"] UTF8String] ?: "?", arch, (int)getpid());
}

static NSString *YZCrashDirectory(void) {
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [caches count] ? [caches objectAtIndex:0] : NSTemporaryDirectory();
}

// the watchdog. one thread, every half second: samples memory into the marker, asks the main thread to answer, and reads how long the
// core thread has been away from its passes. a thread that does not answer for long enough gets a block with the stack of every thread
static volatile unsigned long long YZCrashBeatAt;
static volatile int YZCrashPingPending;
static const unsigned long long YZCrashMainStages[] = { 4000, 12000, 18000 };
static const unsigned long long YZCrashCoreStages[] = { 6000, 20000 };
static int YZCrashHangReports;

static void YZCrashHangBlock(const char *who, unsigned long long stalled_ms, const char *advice) {
    if (YZCrashInHandler || YZCrashHangReports >= 12)
        return;
    ++YZCrashHangReports;
    YZCrashCollect(NULL);
    YZCrashEcho = 1;
    YZCrashHeader("HANG");
    char line[160], number[24];
    YZCrashNumber(stalled_ms / 1000, 10, number);
    snprintf(line, sizeof line, "%s has not answered for %s s", who, number);
    YZCrashRow("what", line);
    YZCrashRow("verdict", advice);
    YZCrashSituation();
    YZCrashNotesWrite();
    for (unsigned i = 0; i < YZCrashThreadTotal && !YZCrashInHandler; ++i) {
        const YZCrashThread *thread = &YZCrashThreads[i];
        // the watchdog itself is not what hangs
        if (strcmp(thread->name, "yozora.watchdog") == 0)
            continue;
        YZCrashThreadWrite(thread, "", 1);
    }
    YZCrashEcho = 0;
    if (YZCrashFD >= 0)
        fsync(YZCrashFD);
}

static void YZCrashHangEnd(const char *who, unsigned long long total_ms) {
    if (YZCrashInHandler)
        return;
    char line[160], number[24];
    YZCrashNumber(total_ms / 1000, 10, number);
    snprintf(line, sizeof line, "%s answers again after about %s s", who, number);
    char date[32];
    YZCrashDate(time(NULL), date, sizeof date);
    YZCrashWrite("\n---- hang ended ");
    YZCrashWrite(date);
    YZCrashWrite(": ");
    YZCrashWrite(line);
    YZCrashWrite("\n");
}

static void *YZCrashWatchdog(void *unused) {
    (void)unused;
    pthread_setname_np("yozora.watchdog");
    unsigned long long tick = YZCrashMonotonicMs();
    int main_stage = 0, core_stage = 0;
    unsigned long long main_since = 0, core_since = 0;
    for (;;) {
        struct timespec pause = { 0, 500 * 1000 * 1000 };
        nanosleep(&pause, NULL);
        if (YZCrashInHandler)
            return NULL;
        unsigned long long now = YZCrashMonotonicMs();
        unsigned long long gap = now - tick;
        tick = now;
        if (YZCrashRunState) {
            unsigned long long resident, available;
            YZCrashMemory(&resident, &available);
            YZCrashRunState->resident = resident;
            YZCrashRunState->free = available;
            YZCrashRunState->updated = (int64_t)time(NULL);
        }
        // a hidden app does not run, and a gap in this thread's own ticks means the process was suspended: neither counts as a hang
        int foreground = !YZCrashRunState || YZCrashRunState->state == YZCrashRunForeground;
        if (!foreground || gap > 2500) {
            YZCrashBeatAt = now;
            if (main_stage) {
                main_stage = 0;
                if (YZCrashRunState)
                    YZCrashRunState->hanging = 0;
            }
            core_stage = 0;
            continue;
        }
        if (!YZCrashPingPending) {
            YZCrashPingPending = 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                YZCrashBeatAt = YZCrashMonotonicMs();
                YZCrashPingPending = 0;
            });
        }
        unsigned long long stalled = now > YZCrashBeatAt ? now - YZCrashBeatAt : 0;
        if (stalled >= YZCrashMainStages[0]) {
            if (!main_stage)
                main_since = now - stalled;
            int target = 0;
            for (int i = 0; i < 3; ++i)
                if (stalled >= YZCrashMainStages[i])
                    target = i + 1;
            if (target > main_stage) {
                main_stage = target;
                if (YZCrashRunState)
                    YZCrashRunState->hanging = 1;
                YZCrashHangBlock("the main thread (the interface)", stalled,
                                 target == 3 ? "the system ends an app whose main thread is stuck this long (0x8badf00d), the stack of main shows where it waits"
                                             : "the interface is frozen, the stack of main shows what it is doing or what it waits for");
            }
        } else if (main_stage && stalled < 1500) {
            YZCrashHangEnd("the main thread", now - main_since);
            main_stage = 0;
            if (YZCrashRunState)
                YZCrashRunState->hanging = 0;
        }
        long long core = yozora_core_stalled_ms();
        if (core >= (long long)YZCrashCoreStages[0]) {
            if (!core_stage)
                core_since = now - (unsigned long long)core;
            int target = core >= (long long)YZCrashCoreStages[1] ? 2 : 1;
            if (target > core_stage) {
                core_stage = target;
                YZCrashHangBlock("the core thread (the page)", (unsigned long long)core,
                                 "the page does not paint or answer: a script runs without end, or the thread waits on a lock, the stack of yozora.core shows which");
            }
        } else if (core_stage && core < 1500) {
            YZCrashHangEnd("the core thread", now - core_since);
            core_stage = 0;
        }
    }
    return NULL;
}

// what the marker of the run before says. a clean end, a crash and the hidden app need no block: a crash wrote its own, a hidden app is
// ended by the system all the time. an app that was in the foreground is a kill: by the watchdog when a hang was open, by the memory
// pressure otherwise, which is the usual case for a browser
static void YZCrashReadPreviousRun(const YZCrashRun *previous) {
    if (previous->magic != YZCrashRunMagic || previous->state != YZCrashRunForeground)
        return;
    char date[32], line[200], a[32], b[32];
    YZCrashHeader("PREVIOUS RUN ENDED WITHOUT A TRACE");
    YZCrashRow("what", "the app was in the foreground and vanished: no crash handler ran and the app did not exit by itself");
    YZCrashRow("app", previous->app);
    YZCrashDate((time_t)previous->started, date, sizeof date);
    snprintf(line, sizeof line, "started %s, last sign of life %lld s later", date, (long long)(previous->updated - previous->started));
    YZCrashRow("run", line);
    YZCrashMegabytes(previous->resident, a);
    YZCrashMegabytes(previous->free, b);
    snprintf(line, sizeof line, "at the last sample (about a second before the end) the app held %s, the system had %s free or reclaimable", a, b);
    YZCrashRow("memory", line);
    if (previous->screen[0])
        YZCrashRow("screen", previous->screen);
    if (previous->note[0])
        YZCrashRow("last note", previous->note);
    if (previous->hanging) {
        YZCrashRow("verdict", "a hang of the main thread was open when it ended: the system watchdog (0x8badf00d) ended the app, the HANG block above has the stack");
    } else if (previous->free < 24ULL * 1024 * 1024) {
        YZCrashRow("verdict", "the phone had almost no free memory: the system ended the app for memory (jetsam), the usual end of a heavy page");
    } else {
        YZCrashRow("verdict", "no hang and memory was not short at the last sample: a kill from outside (the system, a respring, a tool), a crash in a thread the handler could not reach, or a power loss");
    }
}

static void YZCrashRotate(const char *path) {
    struct stat info;
    if (stat(path, &info) != 0 || info.st_size <= YZCrashFileCap)
        return;
    // the older half is kept as .1 and the one before it dropped, so the newest crash is never lost to a cap
    char older[1100];
    snprintf(older, sizeof older, "%s.1", path);
    rename(path, older);
}

@implementation YZCrash

+ (NSString *)path {
    return [YZCrashDirectory() stringByAppendingPathComponent:@"yozora-crash.log"];
}

+ (BOOL)previousRunCrashed { return YZCrashPreviousCrashed; }

+ (void)install {
    static BOOL installed;
    if (installed)
        return;
    installed = YES;
    YZCrashStarted = time(NULL);
    YZCrashMainThread = pthread_mach_thread_np(pthread_self());
    YZCrashDescribeBinary();
    YZCrashDescribeSystem();
    const char *path = [[self path] fileSystemRepresentation];
    YZCrashRotate(path);
    YZCrashFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (YZCrashFD < 0)
        NSLog(@"yozora: the crash record %s cannot be opened: %s", path, strerror(errno));
    // the marker of the run before is read first and then taken over by this run
    {
        NSString *marker = [YZCrashDirectory() stringByAppendingPathComponent:@"yozora-run.state"];
        int fd = open([marker fileSystemRepresentation], O_RDWR | O_CREAT, 0644);
        if (fd >= 0) {
            struct stat info;
            if (fstat(fd, &info) == 0 && info.st_size < (off_t)sizeof(YZCrashRun))
                ftruncate(fd, sizeof(YZCrashRun));
            void *mapped = mmap(NULL, sizeof(YZCrashRun), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            close(fd);
            if (mapped != MAP_FAILED) {
                YZCrashRunState = (YZCrashRun *)mapped;
                YZCrashRun previous = *YZCrashRunState;
                YZCrashPreviousCrashed = previous.magic == YZCrashRunMagic && previous.state == YZCrashRunCrashed;
                memset(YZCrashRunState, 0, sizeof(YZCrashRun));
                YZCrashRunState->magic = YZCrashRunMagic;
                YZCrashRunState->pid = getpid();
                YZCrashRunState->started = (int64_t)YZCrashStarted;
                strlcpy(YZCrashRunState->app, YZCrashAppLine, sizeof YZCrashRunState->app);
                YZCrashSetRunState(YZCrashRunForeground);
                YZCrashReadPreviousRun(&previous);
            }
        }
    }
    YZCrashPreviousHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(YZCrashException);
    // a stack overflow cannot run a handler on the stack that overflowed. the alternate stack belongs to the thread that sets it, so it
    // covers the main thread only, a thread that overflows its own stack leaves nothing
    stack_t alternate;
    alternate.ss_sp = YZCrashStack;
    alternate.ss_size = sizeof YZCrashStack;
    alternate.ss_flags = 0;
    sigaltstack(&alternate, NULL);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = YZCrashSignalHandler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < sizeof YZCrashSignals / sizeof YZCrashSignals[0]; ++i)
        sigaction(YZCrashSignals[i], &action, &YZCrashPrevious[i]);
    {
        char date[32], line[200];
        YZCrashDate(YZCrashStarted, date, sizeof date);
        snprintf(line, sizeof line, "\n---- launch %s: %s, %s\n", date, YZCrashAppLine, YZCrashSystemLine);
        YZCrashWrite(line);
    }
    YZCrashBeatAt = YZCrashMonotonicMs();
    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attributes, 128 * 1024);
    if (pthread_create(&thread, &attributes, YZCrashWatchdog, NULL) != 0)
        NSLog(@"yozora: the watchdog thread did not start, hangs are not recorded");
    pthread_attr_destroy(&attributes);
}

+ (void)applicationDidEnterBackground {
    YZCrashSetRunState(YZCrashRunBackground);
    [self note:@"background"];
}

+ (void)applicationWillEnterForeground {
    YZCrashBeatAt = YZCrashMonotonicMs();
    YZCrashSetRunState(YZCrashRunForeground);
    [self note:@"foreground"];
}

+ (void)applicationWillTerminate {
    YZCrashSetRunState(YZCrashRunClean);
}

+ (void)note:(NSString *)text {
    const char *utf8 = [text UTF8String];
    if (!utf8)
        return;
    unsigned at = YZCrashNoteTotal % YZCrashNoteCount;
    snprintf(YZCrashNotes[at], YZCrashNoteLength, "+%lds %s", (long)(time(NULL) - YZCrashStarted), utf8);
    ++YZCrashNoteTotal;
    if (YZCrashRunState) {
        strlcpy(YZCrashRunState->note, YZCrashNotes[at], sizeof YZCrashRunState->note);
        if (strncmp(utf8, "screen ", 7) == 0)
            strlcpy(YZCrashRunState->screen, utf8 + 7, sizeof YZCrashRunState->screen);
    }
}

+ (void)noteLifecycle:(NSString *)event object:(id)object {
    [self note:[NSString stringWithFormat:@"%@ %@ %p", event, object ? NSStringFromClass([object class]) : @"nil", object]];
}

+ (BOOL)enableZombies {
    // the same switch as the NSZombieEnabled variable, which cannot be set from a launch from the home screen
    void (*enable)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "_CFEnableZombies");
    if (!enable) {
        NSLog(@"yozora: zombie objects cannot be turned on, this system has no _CFEnableZombies");
        [self note:@"zombies: not available"];
        return NO;
    }
    enable();
    [self note:@"zombies on"];
    NSLog(@"yozora: zombie objects on: a message to a freed object is logged with its class and the app stops there");
    return YES;
}

+ (NSString *)report {
    NSMutableData *data = [NSMutableData data];
    NSData *older = [NSData dataWithContentsOfFile:[[self path] stringByAppendingString:@".1"]];
    if ([older length])
        [data appendData:older];
    NSData *current = [NSData dataWithContentsOfFile:[self path]];
    if ([current length])
        [data appendData:current];
    if (![data length])
        return nil;
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

+ (void)clearReport {
    if (YZCrashFD >= 0)
        ftruncate(YZCrashFD, 0);
    else
        [[NSFileManager defaultManager] removeItemAtPath:[self path] error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:[[self path] stringByAppendingString:@".1"] error:NULL];
}

@end
