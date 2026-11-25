# limits

every number here is in the code, the file is named so it can be changed. a limit is there because something broke or could be exhausted without it, the reason is given when it is not obvious.

## profile

- tabs: 24 (`YZTabLimit`)
- history: 4096 urls, bookmarks: 1024 (`core/yozora_store.h`), the recent list 128, address suggestions 6, a page of the store 64
- an address 4096 bytes, a title 512 (`core/yozora_types.h`)
- site decisions: 512 per kind, the oldest goes first (`YozoraSites.cpp`)
- text size 50 to 200 percent, page zoom 50 to 300, pinch zoom 1 to 3, a minimum font of 9 points

## storage

- local storage 5 MB per origin (`YozoraStorage.cpp`)
- cache storage 32 MB of response bodies for all caches of all sites together, the private session has its own, in memory for the life of the app (`YozoraCacheStorage.cpp`)
- http cache 64 MB, one response up to 4 MB, its headers up to 16 KB (`yozora_httpcache.h`), 4 MB may wait for the writer
- bytecode cache 64 MB, a script of 16 KB or more, 8 MB may wait for the writer
- site icons: 96 in memory, 512 KB each, previews of tabs on disk without a bound that the system may empty
- a sign in request: a link of 16384 bytes, an address 2048, the callback and the state 256, a cookie name 128, an answer 32768, cookies read for it 16384 (`core/yozora_signin.h`, `app/YZSignIn.m`)
- log: 256 KB in memory, 1 MB per run on disk, the crash record 64 KB

## network

- 12 requests active at once, 6 to one host, 3 slots are kept for the most important ones, 6 name lookups at once, 1024 queued (`YozoraLoaderStrategy.cpp`)
- websocket: 8 MB a message, 16 MB buffered, 16 KB of handshake
- downloads: 3 at once, 50 on the list, 10 redirects
- a stream through the proxy: 16 streams, 8 connections, 2048 addresses a stream, a cookie of 4096 bytes, a referer of 512, a playlist of 1 MiB (4 MiB rewritten), 5 redirects

## pages

- scroll: 32 blocks that scroll on their own are published, a find counts up to 500 matches, a select lists up to 256 items
- images: a png or webp frame is refused above 2^25 pixels (about 33 megapixels, 128 MB of pixels), a jpeg is decoded at the size it is drawn
- a surface side up to 2048 pixels, a scale up to 4
- raster budget 16 MB below 400 MB of memory, 24 MB up to 512 MB, then 6 percent from 48 up to 512 MB
- a layer records half a screen beyond the visible one
- an animation holds at most 2048 keyframes (a transform that turns is sampled into up to 32 per segment)
- 8 videos with a player at once (`YOZORA_MAX_VIDEOS`), 8 open requests and 32 queued messages of the media engine
- a script that holds the core thread is offered to be stopped after 8 seconds, 4 after a memory warning
- the parser keeps the thread at most 100 ms before it lets a pass, a tap or a timer through
- a webgl call that is in the driver when the app goes to the background is waited for a second at most, the calls after it wait for the return (`core/webgl/yozora_gl_gate.c`)

## media

- decoded audio: 16 million samples, 64 MB of floats
- mediasource: 8 MB of samples may wait for the other track, 24 MB per segment and 24 MB pending, 8192 segments, a segment of up to 60 seconds, a box of up to 24 MB, 8 tracks, 512 bytes of codec config
- formats are what the system decodes, see [media](media.md). before ios 10 hls with fragmented mp4 segments is converted to transport streams in the proxy, h264 and aac only, without encryption or byte ranges

## webassembly

- a module of 64 MB, a table of 10 million elements, 1 million functions, a call depth of 20000, 16 results, 1000 parameters. a memory has no cap below the 4 GiB of the specification, the system decides
- one million external references per thread

## blocker

4000 network rules, 1000 hiding rules, 256 KB of text, 1024 bytes a line, 512 a pattern and a selector, 2048 bytes of an address looked at.

## what is not done

- service workers, and caches of the cache api on disk: they live in memory and end with the app
- device orientation and motion, getusermedia, webrtc, speech, the gamepad api
- webgl and offscreen canvas in workers, webgl in a video texture
- autocorrect and spell check
- a page that composites very many layers can reach the limit of the layer geometry (`Invalid compositing layer geometry`), a long video feed has hit it
- a site signed by a root the bundle lacks fails with curl error 60
