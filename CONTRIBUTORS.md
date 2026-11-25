# contributors

how to build yozora, how to put its engine into your own app, and how to change it without breaking what holds it together. what the engine does is in [README.md](README.md), the details are in [docs/](docs/).

## the tree

- `core/core`: the c api (`yozora_core.h`), the core thread, the page client, the loader, cookies, storage, media, the blocker
- `core/*.c`: portable c99 parts with host tests: navigation, store, address, sign in, playlists, filters, budgets and the like
- `core/webcore`, `core/webgl`, `core/wasm`, `core/text`, `core/runtime`, `core/darwin`: the platform files webkit asks a port for, the webgl entry points, the webassembly engine, fonts, the own libc++, the darwin sources
- `core/patches`: changes to webkit itself, pinned by hashes, see [docs/webkit.md](docs/webkit.md)
- `app`: the ios application, uikit, objective-c, manual reference counting
- `tools`: the headless page runner `yozora-render`, the javascript shell, profilers, the crash symbolizer, asset generators
- `tests`: c tests, python tests, the scripts that drive a phone
- `scripts`: the dependency steps that meow does not model
- `meow.toml`: every target, step and test

## build

you need [meow](https://github.com/sqmrak/meow), a c99 compiler, python 3.12, cmake 3.20, ninja, a c++23 compiler, ruby, perl and sqlite headers. an ios build also needs a cross toolchain with `clang`, `lipo` and `ldid`, a legacy sdk for armv7 and a patched sdk for arm64. `meow doctor` lists what it found and what is missing.

```bash
meow doctor
meow test                     # c and python tests under asan and ubsan
meow build core-fetch core-host core-web-host    # the host core and yozora-render
meow build                    # both ipas
meow build ipa                # one ipa with both slices
meow build app --slice arm64  # one slice of the app
```

a full webcore build takes about 25 minutes with four jobs and about 8 GB of ram. `meow plan NAME` prints the commands and what is stale, `meow why NAME` says what made a step stale, `meow clean NAME` forgets a step.

nothing is read from a fixed path. toolchain, sdks, build trees, source caches and job counts are variables (`YOZORA_TC`, `YOZORA_SDK_V7`, `YOZORA_SDK_V64`, `YOZORA_WEBCORE_IOS_BUILD`, `YOZORA_CORE_CACHE` and the rest), the full list is in [docs/build.md](docs/build.md). a script that needs one and does not find it stops with its name.

two things catch people:

- a build tree keeps the absolute path it was configured in. after the sources move, configure a new tree, an old one cannot compile
- the ipa build needs `app/fonts/AppleColorEmoji.ttf`, which is generated and not committed (`tools/make_emoji_font.py`, see `app/NOTICE-Emoji.txt`)

outputs are `build/ipa/Yozora-armv7.ipa`, `build/ipa/Yozora-arm64.ipa` and `build/ipa/Yozora.ipa`. meow checks the slices, the deployment target, the signature and the linked libraries before it writes an ipa, and reads the ipa back after.

## the headless runner

the quickest way to see the engine without a phone is the host build of `yozora-render`:

```bash
yozora-render FONT_DIRECTORY CA_BUNDLE URL OUTPUT.png [WIDTH HEIGHT]
```

`app/fonts` is the font directory and `app/ca-bundle.crt` the root bundle. it prints the page console, saves a screenshot and, with the `YOZORA_RENDER_*` variables of [docs/debug.md](docs/debug.md), a profile, the downloads and the stored site data. most core tests are scripts around it. `yozora-js` is the javascript shell of the same engine.

## put the engine into your app

the boundary is `core/core/yozora_core.h`, plain c. one thread inside owns webcore for the whole process, your interface thread calls it and never waits for a page. there is no web view class to add: you link the engine, call the api and draw what it gives you.

### link

- compile with `-Icore -Icore/core`
- the link line of the whole port is not written by hand. `webcore-armv7` and `webcore-arm64` build it through cmake, and `scripts/export_link_line.py` writes `build/<slice>/link.rsp` (the core, webcore, javascriptcore, the dependency archives, the own libc++ and the frameworks, in the order cmake linked them). link your app with `@build/<slice>/link.rsp`, as the `app-*` targets of `meow.toml` do
- the c++ library inside is the own one, in the namespace `std::__yozora1`. keep c++ out of the headers you share with it: `yozora_core.h` is c, use only that
- armv7 and arm64 are separate builds with their own staging directories, joined with `lipo` after
- the `app/` files are compiled without arc (`-fno-objc-arc`) and with `-Werror`. if you reuse them, keep that

### sign

the jit needs executable memory. sign the app with `dynamic-codesigning` (`tools/yozora-jit.entitlements`) and leave the jit on. a phone that refuses the mapping runs the assembler interpreter of the same binary, `yozora_jit_info_read` tells which one is running. a default browser also needs `com.apple.developer.web-browser`, see [docs/ui.md](docs/ui.md).

### resources in the bundle

- `fonts/`: the contents of `app/fonts`
- `ca-bundle.crt`: `app/ca-bundle.crt`. the certificate chain, the host and the dates are always checked against it and nothing relaxes that

### start

in this order:

1. in `main`, before `UIApplicationMain`: `yozora_set_jit_requested(1)` (or 0), then `yozora_initialize_javascript()`. ios allows one executable mapping per process and system framework startup can take it first. this is the one step that has to come before anything else of yours
2. once, before the first page: `yozora_set_site_data(dir, error, size)` for cookies, local storage and indexeddb (the profile directory, mode 0700), `yozora_downloads_set_directory`, `yozora_set_http_cache(dir, bytes, ...)` and `yozora_set_bytecode_cache(dir, bytes, ...)` (caches directories, mode 0700). without a site data directory cookies and storage live in memory only
3. `yozora_set_options(&options)`: javascript, text size, third party cookies, reduced motion, web fonts, dark appearance, webgl, links for other apps
4. `yozora_core_create(fontsPath, caBundlePath, error, size)`: one core is one page. the first call starts the core thread. you can hold many, a core you leave can be parked with `yozora_core_set_suspended(core, 1)` and keeps its forms, script state and history
5. `yozora_core_resize(core, width, height, scale)` in points, and `yozora_core_load(core, url, error, size)`

### every frame

from a display link on the interface thread:

- `yozora_core_take_scene(core)` returns a retained layer scene when there is a new one, 0 when not. draw it and `yozora_scene_release` it. `app/YZPageView` and `app/YZSceneView` do it as a native Core Animation layer tree, so scrolling and transform animations go on while a script holds the page. you can take both files (with `YZMediaPlayer`, `YZTheme` and `YZStrings` they pull in) or write your own view over `yozora_scene.h`
- state: `yozora_core_state`, `_url`, `_title`, `_progress`, `_is_secure`, `_can_go_back`, `_can_go_forward`, `_page_error`
- input: `yozora_core_tap`, `_touch`, `_scroll`, `_set_page_zoom`, the keyboard through `_insert_text` and `_delete_backward` once `yozora_core_input_kind` says a field has focus
- what the page asks the person comes as a queue you poll and answer by id: `_take_choice`, `_take_files`, `_take_date`, `_take_auth`, `_take_geolocation_request`, `_take_notification_request`, `_take_media`, `_take_popup`, `_take_external`. a full queue refuses at once, so a page that asks in a loop gets a denial. anything you do not poll is never answered, so wire the ones your app can show and leave the rest unwired knowingly

`yozora_core_tick` is the headless variant: it hands over tiles of pixels instead of a scene, it is what `yozora-render` uses.

### app lifecycle

- `applicationDidEnterBackground`: `yozora_set_background(1)`, and flush on a background task: `yozora_flush_http_cache`, `yozora_flush_bytecode_cache`, `yozora_flush_site_data`. flushes wait for the core thread, which may be inside a script, so never on the main thread of an ios 5 or 6 app (the system kills it for taking too long)
- `applicationDidEnterBackground`, last: `yozora_gl_set_allowed(0)` (`core/webgl/yozora_gl.h`). ios kills a hidden app at its next submission to the graphics chip, on ios 9 from 0.35 s after a lock, and the core thread can still be drawing, so from here its webgl calls wait for the return. it waits up to a second for a call that is in the driver
- foreground: `yozora_gl_set_allowed(1)` first, then `yozora_set_background(0)`
- memory warning: `yozora_core_release_memory(core)` for each core, `yozora_release_memory_async()` for the process. forms, indexeddb, cookies and history are never dropped to free memory
- a script that holds the thread is offered to be stopped: ask `yozora_stop_scripts` from any thread when your interface decides it. nothing ends a script on its own timer
- destroy a core with `yozora_core_destroy_async` when you will not touch it again, `yozora_core_destroy` waits

### private pages

`yozora_set_private_session(1)` before the first private page, `0` once the profile's pages run again, and `yozora_clear_private_session()` when the last private page is gone. no profile page may load while it is on. see [docs/incognito.md](docs/incognito.md).

### from another app

yozora as a program, not a library: it is a default browser (`http`, `https`), and another app can ask it to sign a person in on a site and get the address and the cookies back with `yozora-auth://`, see [docs/signin.md](docs/signin.md).

## how to change things

- start from the doc of the area ([docs/](docs/)), then the header, then the code. `docs/limits.md` lists every bound with the file that holds it
- portable logic (parsers, plans, layout maths, protocol state) goes in a c99 file in `core/` with a table driven test in `tests/`, built with `-Wall -Wextra -Werror -pedantic` under asan and ubsan, and listed in `meow.toml` and `core/Core.cmake`. malformed input, empty input, maximum lengths and truncation are part of the test
- run `meow test` before and after. a change must not move an unrelated expected result
- the interface (`app/`) is manual reference counting: match `retain`, `release` and `autorelease` deliberately, call `[super dealloc]` last, return to the main thread before touching uikit, give every observer, timer, connection and retained block a teardown. the prefix is `YZ`
- apis newer than the deployment target are looked up at run time (`NSClassFromString`, `respondsToSelector:`, weak links) with a fallback. the baseline is real ios 5 behavior on armv7 and ios 7 on arm64
- never edit the unpacked webkit tree. a change to webkit is a patch in `core/patches` with its hashes in `sources.json`, applied by `scripts/apply_core_patches.py`, which refuses a tree it does not recognize
- do not weaken certificate checks, path checks or source hashes to make something pass
- do not commit build directories, generated fonts or release archives
- comments are english, lowercase at the start, say why the code is there or which concrete failure it avoids, no period at the end and no dashes. no comment that repeats the next line, no commented out code
- docs follow the same voice: lowercase, direct, exact paths and commands, what is done and what is not. when a change moves a limit, a path or a switch, change the doc in the same commit

## license

yozora is free software under the GNU General Public License version 3, see `LICENSE`. sources it builds from and bundles keep their own licenses.
