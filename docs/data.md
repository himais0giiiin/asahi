# data

## profile

`Library/Yozora`, mode 0700.

if the system denies access to that directory, the app creates a separate profile in `Documents/Yozora`, mode 0700, and reports it once. the choice persists across restarts so new data stays together. the inaccessible profile is not moved or deleted; its history and site data do not appear in the new profile.

- `browser.sqlite3`: history (4096 urls) and bookmarks (1024), mode 0600
- `cookies.db`
- `local-storage.txt`: 5 MB per origin
- `IndexedDB/`: a crypto key a site stores is kept as webcore serializes it, without a master key, as on the gtk and wpe ports
- the cache storage api (`caches`) keeps nothing here, its caches live in memory and end with the app, see [limits](limits.md)
- `geolocation.txt`, `notifications.txt`, `adblock-sites.txt`: decisions of sites, see [permissions](permissions.md)
- `adblock-rules.txt`: the rules of the person, see [adblock](adblock.md)

## caches

in `Library/Caches`, which the system may empty and does not back up:

- `Yozora`: the http cache, 64 MB
- `YozoraBytecode`: bytecode of scripts, 64 MB, cleared with the history
- `YozoraThumbnails`: previews of tabs
- `YozoraIcons`: site icons
- `yozora.log`, `yozora-previous.log`: the log of this run and of the run before, see [debug](debug.md)
- `yozora-crash.log`: the crash record, 64 KB, see [debug](debug.md)

## the store

`core/yozora_store.c` opens the database only under strict conditions, and answers "file access failed" for any other:

- the directory is a directory of this user with mode 0700
- the database and its journal files are plain files of this user with mode 0600 and no other link
- no symlink, no foreign owner, no path with `..`, `.` or `//`
- it waits 250 ms for a lock

when the open fails for that reason the app puts its own files right once: a file of this user gets its mode back, a file that is not its own is moved aside under a name with `.rejected-` and the time, the data stays on the disk and the next open makes a new database. a profile that still does not open is reported with the owner and the mode of each file.

## private tabs

memory only, gone on close, see [incognito](incognito.md).

## the old directory

`Library/Akari` is not migrated, move it by hand to keep history and logins.
