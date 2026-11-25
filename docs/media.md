# media

## elements

`<video>` and `<audio>` play through the system player (`AVPlayer`, ios 5 to latest). `core/core/YozoraMedia.cpp` is the media engine webcore sees, `app/YZMediaPlayer.m` owns the player. the page gets play, pause, `currentTime`, `duration` and the usual events.

- formats are what the system decodes: h264 and aac in mp4, hls, mp3, m4a, wav. webm, ogg, vp9 and av1 are skipped and the page gets an `error` event
- metadata opens the first source the system plays
- native controls or `play()` inside a tap handler start playback, `play()` without a tap is refused like autoplay
- only http and https addresses reach the player

## on the page

a video plays on the page under a transparent hole the page paints, so what the page draws over it stays over it, and the page controls it with its own buttons or the controls of webcore.

the playback audio session is taken at the first play and kept through pauses. it is released when the video ends, is interrupted, is muted or closed. releasing it on every pause tore the audio pipeline down under the resumed sound.
## full screen

the full screen player (`YZVideoController`) opens only when the page asks: `webkitEnterFullscreen`, `requestFullscreen` of the video or of a container that holds one. closing it fires `fullscreenchange` and the video keeps playing on the page. `document.fullscreenEnabled` is on, any other element is refused with a `TypeError`.

the player is drawn by the app, the state (position, loaded end, buffering, rate, mute) lives in `YZMediaPlayer` and the controller only shows it:

- a wave seek bar (`YZWaveSeekBar`): the played part is a wave that travels while the video plays and flattens on the spring when it pauses, a pill handle squeezes under a finger, the loaded part is a brighter line
- a big play button whose triangle turns into two bars while its body rounds into a circle (`YZPlayButton`)
- ten second skips, a speed list from 0.5 to 2, mute, fit or fill, a back button, the title of the page
- a double tap on a side skips ten seconds with a bubble that adds up, a double tap in the middle plays or pauses, a held finger plays at 2x, pulling the picture apart fills the screen and pinching fits it, a vertical stroke on the left half changes the brightness and it is restored on close
- speed and mute set there belong to the person, the page does not hear of them

## the stream proxy

a stream is fetched through a proxy on the loopback address (`core/yozora_stream_proxy.c`, started by `app/YZStreamProxy.m` with the first player) because the system player cannot send the cookies of the page or trust the roots of the app.

- libcurl verifies the chain and the host name against `ca-bundle.crt`, never turned off
- it sends the cookie header the page has for the stream (left out when it does not fit 4096 bytes) and the origin of the page as the referer
- one `bytes=` range is passed, other range requests are refused
- up to 5 redirects are followed by hand and the cookie goes only to the host and the scheme it was made for
- 200, 206, 403, 404, 410 and 416 pass through, every other status of a server is a 502
- the address of a stream holds a random 128 bit token, so another process cannot ask for what it cannot name
- limits: 16 streams, 8 connections, 2048 addresses per stream, 1 MiB per playlist
- a suspended app loses its listening socket, the proxy starts again at the next stream and the streams of the old one fail
- when the proxy cannot start the system plays the stream directly

hls playlists, found by content type or by `#EXTM3U`, are rewritten by `core/yozora_playlist.c` (rfc 3986 resolution against the final address, every line that is not a tag, every `URI="..."`, line endings kept) so that segments, keys, maps and renditions come back to the proxy.

## fragmented mp4 in hls

AVPlayer plays fragmented mp4 segments (`#EXT-X-MAP`, `.m4s`, cmaf) from ios 10, on ios 5 to 9 such a stream ends in error -11800 and the page gets an `error` event. where the player lacks `setAutomaticallyWaitsToMinimizeStalling:` (the same release) `YZStreamProxy` starts the proxy with `transmux_fmp4`:

- a media playlist with one map file is answered without the `EXT-X-MAP` line and with `#EXT-X-VERSION:3`, the addresses of its segments end in `.ts`
- a request for such a segment fetches the map file and the segment, `yozora_fmp4_to_ts` (`core/yozora_hls.c`, over the mp4 parser and the ts muxer of the mediasource) cuts the samples into 188 byte packets in time order, and the answer is `video/mp2t`. the times keep the `tfdt` of the segment, so the segments of one playlist follow each other. ranges and HEAD work on the result
- H.264 and AAC-LC only. hevc, ac-3 and the rest are refused with a 502, and the stderr of the app (the log) says `a segment from HOST is not H.264 and AAC in fragmented mp4 …` with the status of the conversion
- left as they are, so they fail on ios 9 and earlier as before: playlists with `#EXT-X-KEY` (encrypted), `#EXT-X-BYTERANGE`, `#EXT-X-PART`, `#EXT-X-PRELOAD-HINT`, `#EXT-X-I-FRAMES-ONLY`, a second map file or a map with a byte range, and master playlists (their media playlists are converted when the player asks for them)
- a segment and its map file are held whole in memory, up to 24 MiB and 1 MiB, the result up to 64 MiB. the continuity counters of the packets start again at each segment

tested on the host (`tests/test_fmp4_ts.c`, the proxy group in `tests/test_stream_proxy.py` with fixtures made by the first). not tried on an ios 6 or ios 9 device: whether AVPlayer there accepts the segments, the timestamps and the counters of the result is not known.

## mediasource

the system has no mediasource, so the page's fragmented mp4 is turned into something the system can play:

1. the page appends fmp4 to a source buffer, `core/yozora_mp4.c` parses it, h264 and aac only
2. a webcore `SourceBufferPrivate` (`YozoraMediaSource.cpp`) takes the samples
3. `core/yozora_hls.c` and `core/yozora_ts.c` cut mpeg-ts segments at key frames and serve an event playlist from memory
4. the proxy serves them under `/s/<token>/<name>`, the player opens `yozora-hls:<id>`
5. a seek starts a new epoch, a new player item

the claims for `mp4v.20`, `mp4a.67` and pcm in wave are made in `YozoraMedia.cpp`. `core/patches/webkit-yozora.patch` adds the platform types (the mediasource part of it).

what is tested: the parsers, the cutter and the proxy against local servers, with sanitizers (`meow test`), and the webcore sources with the flag on, syntax only.

## web audio

`AudioContext`, `OfflineAudioContext` and the nodes of webkit: oscillator, gain, filters, analyser, convolver, panner with hrtf, compressor, worklet. the port brings:

- an own fft, `FFTFrameYozora.cpp`, tested against a plain dft by `tests/test_fft_frame.cpp`
- a destination that feeds the sound device (`AudioDestinationYozora.cpp`): an `AudioQueue` of 16 bit samples on the phone, a paced null device on the host
- a reader for `decodeAudioData`: wave everywhere, mp3, aac and the rest through audiotoolbox on the phone only, a clip may hold 16 million samples

`tests/test_core_webaudio.py` covers it on the host.
