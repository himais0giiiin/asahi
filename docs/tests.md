# tests

## host

`meow test` builds and runs the c tests and the python tests that need nothing from webkit. every c test builds with `-Wall -Wextra -Werror -pedantic`.

- c: navigation, store, address, signin, accent, playlist, mp4 and ts, hls, log, blocklist, filter, sitegrants, budget, http cache, keys, motion, zoom, blur, divdc3, debug, transfer, translate, color, clock, wait, gl gate, system, macho, memory bounds, render plan, scene animation, wasm engine
- python: sources, patches, scripts, the cli of the store and the runtime
- the c tests run under asan and ubsan. `page-adapter-sanitize` stops in upstream wtf (`memcpy` with a null pointer and zero length) and in the css tokenizer vector, so no clean sanitizer run of the whole core is claimed
- `meow test proxy` runs the stream proxy against local http and https servers: ranges, cookies, referers, redirects, hls chains, fragmented mp4 segments made transport streams, bad requests, a client that leaves, the stream limit, stop under load, chain and host name checks. needs libcurl and, for https, openssl
- `meow test wasm` needs node

## core on the host

`meow build core-web-host` builds `yozora-render` and runs the tests that use it against local servers:

- lifecycle: quiet pass count, repeated viewport size, live economy scale, suspended timers, form and history preservation, an independent active tab, resumed pixels, media and indexeddb refusal, suspended teardown
- scenes: immutable ownership, partial repaint equality, cache reuse, independent raster animation and scrolling, transforms, masks, fixed and sticky pixels
- loading, gc, images, deferred image grids, an infinite feed, bytecode, run loop, apis, input, frames, priority, responsive, scroll, fling, stop, inner scroll, select, download, auth, idb, websockets, tiles, paint
- webgl 1 and 2, web audio, webassembly, touch, long press, translation, geolocation, site data

`yozora-scroll-tests` checks pending scroll offsets, the 32 area bound and coherent snapshots during concurrent updates, `--benchmark` compares locked reads with one snapshot. `yozora-scene-tests --benchmark` runs 200 scene updates at 32, 128 and 400 layers. they report host time, not frame rate.

## interface

`yozora-ui-tests` is an ios target: uikit card reuse, resize, theme, title, discarded previews and tab identity, home tile reuse, bounded counts, reordered targets, empty defaults. it runs as a signed app through springboard with the real resources, console uikit on ios 6 does not initialize font services, and writes its result to a log in the caches. `YZUITest.plist` with `arguments: ["--benchmark"]` runs 200 layout passes without a page.

## on a phone

- `tests/test_crash_record.py`: `tools/yozora_record.py` names the app frames of a crash record from a hand made map, passes a block of an unknown build through with a note and leaves other images alone. the recorder itself (`app/YZCrash.m`) needs a phone, only its date and number formatting was run on the host
- `tests/jit_device.sh`: normal jit, forced baseline, synchronous and concurrent dfg against the c loop, and a requirement that optimized compilation happens in the property cache, double abi and map and set iterator regressions
- `tests/site_stress_device.sh`: loads real sites
- `tests/stack_device.py`: pages that recurse until the stack is full, with several stack limits, with and without the jit

## live probes

contact the providers and are not part of the suite: `python3 -B tests/probe_captcha.py yozora-render turnstile OUTPUT` (also `recaptcha`, `hcaptcha`).

## what ran where

- ran on a real armv7 phone: the native compositor, corrected armv7 dfg, linked property caches, the darwin double calling convention, concurrent compilation, layer pixels, scrolling, animations while a script is blocked, local mp4 playback, the tab tray and home page reuse, the scroll snapshot
- `meow test fmp4-ts` converts an init segment and a fragment to a transport stream (packets, tables, key frames, time order, refusals of cuts and other codecs); with a directory as argument it rewrites the fixtures of `tests/data`
- `meow test release` parses the json of the releases api and the atom feed (notes as plain text, assets, refused drafts, foreign addresses, truncation), compares versions and reads the digest file
