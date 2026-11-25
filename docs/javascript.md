# javascript

## engines

javascriptcore of the same revision as webcore, linked statically.

- armv7 and arm64: baseline jit, dfg jit and regexp jit
- the jit switch of developer settings is on by default on armv7 and off by default on arm64, where the jit has not run on a device: ios 15 and later may refuse or kill the executable mapping while javascriptcore starts. a switch the person already set is kept. the interpreter of the same binary runs pages with the switch off, noticeably slower on heavy scripts
- when the system refuses executable memory the assembler interpreter of the same binary runs, there is no second build for it
- `YOZORA_ARMV7_JIT=0` at build time builds the c loop instead of the jit, `YOZORA_NO_JIT=1` turns the jit off at run time
- ftl is off, there is no llvm on the phone
- on armv7 the dfg compiles on the thread that runs the script (`useConcurrentJIT` off, the environment variable `JSC_useConcurrentJIT` still wins): two crashes of 1.3.0 on an iPad 4 ended in generated code, one reading at 0x64 inside optimized code and one jumping to the first byte of a page that was not executable, both from a call out of the interpreter into a function, and the compiler thread and the collector are the other writers of that memory. the report of an iPhone 5 on ios 8.4.1 (1.3.0, 62 s after the launch) is the same family: the core thread, running a timer, jumped to address 0 from generated code, entered from the interpreter. both compiler threads and the collector helper were idle then, so a concurrent compile in flight is not proven, and the report cannot be read further because the map of that build was not kept. this is a mitigation of a cause that was not found, it was not run on a device. the next block of the crash record names the registers and the instructions at lr, which say which pointer was null the arm64 slice keeps the concurrent compiler

the jit needs memory that is both writable and executable. the entitlement is signed in `tools/yozora-jit.entitlements`, and the core reserves the executable region early, on the core thread, before uikit starts.


## what was fixed in the port

the 32 bit arm jit of this revision did not run as shipped. `core/patches/webkit-yozora.patch` carries the changes: linked property caches, the darwin calling convention for doubles, concurrent compilation, map and set iterators under dfg. each has a regression in `tests/jit_device.sh` that requires optimized compilation to happen.

## settings

on arm64 a new install asks once at the first launch whether to turn the jit on (`offerJit` in `YZBrowserController`). the answer is stored as the switch and counts at the next launch, because the jit is chosen in `main` before any screen exists.

a launch with the jit sets a mark (`YZJitStarting`) before JavaScriptCore starts and clears it once the browser is up. when the next launch finds the mark, the earlier one died on the way: the jit is turned off, the switch goes off, and a notice says so. this keeps a jit that kills the launch from locking the person out of the switch. a normal quit during the first second leaves the mark too and costs the jit the same way, it can be turned on again.

if the start mark cannot be saved, the app starts in the interpreter and reports the failure. a mark left while the jit is switched off is cleared without turning a later choice off.

developer settings show a jit switch and a line with what javascriptcore reports after it started: baseline, dfg, regexp, or why it is off. the switch is read once in `main`, it counts at the next launch.

## bytecode cache

a script of 16 KB or more keeps its bytecode in `Library/Caches/YozoraBytecode`, 64 MB. a script that loads again skips the parser and the generator. the key is the text of the script and the host, not the address, so a script served from a changing url still hits. when the app leaves the foreground the log gets one line with the scripts loaded from the cache, the stale ones replaced, the files stored and the bytes written (`yozora: bytecode cache, ...`), which is the hit rate on a phone.

- a separate writer thread owns the disk, the page never waits for it
- pending bytes are capped by the memory tier of the phone (6 MB at 512 MB and below)
- cleared with the history
- the private session reads and writes none of it

## scripts that do not return

see [core](core.md): a stuck script is offered to be stopped after 8 seconds, and every long loop checks for it, webassembly included.

## stack

pages that recurse until the stack is full were run with several stack limits, with and without the jit, by `tests/stack_device.py`. the result is a `RangeError`, not a crash.

## measurements

baseline measurements against the c loop were fib 1.5x, loops 1.7x and regexps 5x, property inline caches gave 2x to 4x in property loops. dfg has its own comparison in `tests/jit_device.sh`. real sites are loaded by `tests/site_stress_device.sh`.
