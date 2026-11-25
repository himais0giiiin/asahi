# downloads

## what is a download

a response that no viewer shows, or that the server marks as an attachment, is saved by its own curl request with the cookies of the page, three at a time (`yozora_downloads_*`). a download keeps going while the tab changes, the list is the same for every tab. the files go to the downloads folder, made when the first file comes.

## the list

a card for each file in the style of material 3:

- a running download shows the wave bar of the video player (`YZWaveSeekBar`), it travels while bytes come and flattens when the download waits
- the received and total size, the speed and the time left (`core/yozora_transfer.c`, tested on the host, the speed is smoothed)
- a button that pauses or resumes, a button that cancels
- a finished file gets a tonal disc with its extension (`PDF`, `ZIP`), a failed one an error container with the reason, an empty list a card that says so
- a tap opens the file in the viewer of the system, a swipe removes a finished one
- a download of an unknown size shows only its byte count and its bar stays empty

a line along the bottom bar (the toolbar on an ipad) shows the share of the running downloads, and a banner names a file that ended while the page is on the screen.

## pause and resume

a paused download keeps its part file and counts as unfinished. a resume sends `Range` with `If-Range` and takes the answer only when it is a 206 that starts where the file ends. a server that sends no strong validator or no `Accept-Ranges: bytes`, or ignores the range, makes the download start again from the first byte. the downloads end with the app, a part file of an earlier run is not picked up.

## the app is hidden

downloads go on: `applicationDidEnterBackground` takes a background task (the system gives a hidden app a few minutes, ten on ios 5 and 6) and `yozora_set_background_downloads(1)` lets the core thread run in a quiet mode: pages hidden, no passes, the run loop serves the transfers. a page that draws with webgl as the app leaves or in that run waits at the gate of the gl layer until the app is back (see [webgl](webgl.md)), and the transfers wait with the thread. when the last download ends the thread holds still again. when the time runs out the downloads that still run are paused with their part files kept and they resume when the app is shown.

## the system tells

`YZSystemNotifier` is what the person sees outside the page:

- a notification when a file is done or has failed, while the app is not on the screen
- a notification that a download goes on, when the app is hidden with downloads running: the name of the file, or how many files there are
- a notification when the time ran out and the downloads were paused
- the spinner that the system turns in the status bar while a download is queued or running
- the number of running downloads on the icon

ios 8 and later show notifications and the number only after the person allowed them, so the question is asked with the first download. ios 6 has no notification with progress, the animation there is the spinner of the system. ios 10 and later do not show a local notification while the app is on the screen, and there is no `UNUserNotificationCenter` path.
