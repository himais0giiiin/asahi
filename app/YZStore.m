#import "YZStore.h"
#import "YZStrings.h"
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

// the recent list feeds the address bar suggestions and the start page tiles
static const size_t YZRecentLimit = 128;

@implementation YZRecord
@synthesize url = _url;
@synthesize title = _title;
@synthesize visits = _visits;
@synthesize timeMs = _timeMs;

- (NSString *)displayTitle {
    return [_title length] ? _title : _url;
}

- (void)dealloc {
    [_url release];
    [_title release];
    [super dealloc];
}
@end

static YZRecord *YZRecordFromCore(const yozora_record *core) {
    YZRecord *record = [[[YZRecord alloc] init] autorelease];
    record.url = [NSString stringWithUTF8String:core->url];
    record.title = [NSString stringWithUTF8String:core->title];
    record.visits = core->visits;
    record.timeMs = core->time_ms;
    return record;
}

@interface YZStore ()
- (NSArray *)fetchWithSelector:(yozora_status (*)(yozora_store *, size_t, yozora_record *, size_t, size_t *))fetch
                        offset:(NSUInteger)offset limit:(NSUInteger)limit;
- (void)reloadBookmarks;
- (void)reloadRecent;
- (yozora_status)runOnQueue:(yozora_status (^)(void))work;
@end

// the core opens the database only for plain files of this user, mode 0600, no other link, else "file access
// failed". files from an install or restore under another user or mode, or a journal a killed run left under
// another owner, are put right once: ours get the mode back, foreign ones move aside (data stays) and the
// next open makes a new database
static NSArray *YZProfileFiles(void) {
    return [NSArray arrayWithObjects:@"browser.sqlite3", @"browser.sqlite3-journal", @"browser.sqlite3-wal", @"browser.sqlite3-shm", nil];
}

static void YZRepairProfile(NSString *directory) {
    for (NSString *name in YZProfileFiles()) {
        const char *path = [[directory stringByAppendingPathComponent:name] fileSystemRepresentation];
        struct stat attributes;
        if (lstat(path, &attributes) != 0)
            continue;
        BOOL plain = S_ISREG(attributes.st_mode) && attributes.st_uid == geteuid() && attributes.st_nlink == 1;
        if (plain) {
            if ((attributes.st_mode & 07777) != 0600 && chmod(path, 0600) != 0)
                NSLog(@"yozora: %@ has mode %o and could not be changed: %s", name, (unsigned)(attributes.st_mode & 07777), strerror(errno));
            else if ((attributes.st_mode & 07777) != 0600)
                NSLog(@"yozora: %@ had mode %o, now 0600", name, (unsigned)(attributes.st_mode & 07777));
            continue;
        }
        char aside[4096];
        snprintf(aside, sizeof aside, "%s.rejected-%ld", path, (long)time(NULL));
        if (rename(path, aside) == 0)
            NSLog(@"yozora: %@ (uid %u, mode %o, links %u) is not a file of this user, moved to %s", name, (unsigned)attributes.st_uid,
                  (unsigned)(attributes.st_mode & 07777), (unsigned)attributes.st_nlink, aside);
        else
            NSLog(@"yozora: %@ (uid %u, mode %o, links %u) is not a file of this user and could not be moved: %s", name, (unsigned)attributes.st_uid,
                  (unsigned)(attributes.st_mode & 07777), (unsigned)attributes.st_nlink, strerror(errno));
    }
}

// shown when the profile still does not open: the owner and mode of each file, so a wrong one is named
static NSString *YZProfileDetail(NSString *directory) {
    NSMutableArray *parts = [NSMutableArray array];
    struct stat attributes;
    if (lstat([directory fileSystemRepresentation], &attributes) == 0)
        [parts addObject:[NSString stringWithFormat:@"dir %o uid %u/%u", (unsigned)(attributes.st_mode & 07777), (unsigned)attributes.st_uid, (unsigned)geteuid()]];
    for (NSString *name in YZProfileFiles()) {
        if (lstat([[directory stringByAppendingPathComponent:name] fileSystemRepresentation], &attributes) == 0)
            [parts addObject:[NSString stringWithFormat:@"%@ %o uid %u links %u", [name substringFromIndex:8], (unsigned)(attributes.st_mode & 07777),
                              (unsigned)attributes.st_uid, (unsigned)attributes.st_nlink]];
    }
    return [parts componentsJoinedByString:@", "];
}

@implementation YZStore

+ (NSString *)profileDirectory {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *files = [NSFileManager defaultManager];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *primary = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Yozora"];
        NSArray *roots = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *alternative = [roots count] ? [[roots objectAtIndex:0] stringByAppendingPathComponent:@"Yozora"] : nil;
        NSDictionary *mode = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedShort:0700] forKey:NSFilePosixPermissions];
        BOOL selected = [defaults boolForKey:@"YZDocumentsProfile"];
        if (!selected) {
            NSError *failure = nil;
            BOOL created = [files createDirectoryAtPath:primary withIntermediateDirectories:YES attributes:mode error:&failure];
            int modeError = 0;
            if (created && chmod([primary fileSystemRepresentation], 0700) != 0)
                modeError = errno;
            NSError *underlying = [[failure userInfo] objectForKey:NSUnderlyingErrorKey];
            BOOL denied = ([failure.domain isEqualToString:NSCocoaErrorDomain] && failure.code == NSFileWriteNoPermissionError)
                || ([failure.domain isEqualToString:NSPOSIXErrorDomain] && (failure.code == EACCES || failure.code == EPERM))
                || ([underlying.domain isEqualToString:NSPOSIXErrorDomain] && (underlying.code == EACCES || underlying.code == EPERM))
                || modeError == EACCES || modeError == EPERM;
            if (denied && alternative) {
                NSError *alternateError = nil;
                if ([files createDirectoryAtPath:alternative withIntermediateDirectories:YES attributes:mode error:&alternateError]
                    && chmod([alternative fileSystemRepresentation], 0700) == 0) {
                    selected = YES;
                    [defaults setBool:YES forKey:@"YZDocumentsProfile"];
                    [defaults synchronize];
                    NSLog(@"yozora: Library/Yozora is inaccessible (%@); using a separate profile in Documents/Yozora", failure);
                } else {
                    NSLog(@"yozora: Documents/Yozora is unavailable: %@ (%s)", alternateError, strerror(errno));
                }
            }
        }
        directory = [(selected && alternative ? alternative : primary) copy];
    });
    return directory;
}

+ (BOOL)usesDocumentsProfile {
    [self profileDirectory];
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"YZDocumentsProfile"];
}

+ (YZStore *)openDefaultStore:(NSString **)error {
    NSString *directory = [self profileDirectory];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSDictionary *attributes = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedShort:0700]
                                                           forKey:NSFilePosixPermissions];
    NSError *failure = nil;
    if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:attributes error:&failure]) {
        if (error)
            *error = [failure localizedDescription];
        return nil;
    }
    // a directory made by an older run or another tool may have looser permissions
    if (chmod([directory fileSystemRepresentation], 0700) != 0) {
        if (error)
            *error = YZT(@"Не удалось закрыть доступ к папке профиля");
        return nil;
    }
    yozora_store *core = NULL;
    yozora_status status = yozora_store_open([directory fileSystemRepresentation], &core);
    if (status == YOZORA_IO) {
        // once: a profile that still fails after the repair is reported as it is
        YZRepairProfile(directory);
        status = yozora_store_open([directory fileSystemRepresentation], &core);
    }
    if (status != YOZORA_OK) {
        NSString *detail = YZProfileDetail(directory);
        NSLog(@"yozora: the profile did not open: %s (%@)", yozora_status_string(status), detail);
        if (error)
            *error = [NSString stringWithFormat:YZT(@"Профиль не открыт: %s"), yozora_status_string(status)];
        if (error && [detail length])
            *error = [*error stringByAppendingFormat:@" (%@)", detail];
        return nil;
    }
    YZStore *store = [[[YZStore alloc] init] autorelease];
    store->_store = core;
    store->_queue = dispatch_queue_create("yozora.store", DISPATCH_QUEUE_SERIAL);
    store->_bookmarks = [[NSMutableArray alloc] init];
    store->_bookmarkURLs = [[NSMutableSet alloc] init];
    store->_recent = [[NSMutableArray alloc] init];
    [store reloadBookmarks];
    [store reloadRecent];
    return store;
}

// runs on the store queue
- (NSArray *)readRowsWithSelector:(yozora_status (*)(yozora_store *, size_t, yozora_record *, size_t, size_t *))fetch
                           offset:(NSUInteger)offset limit:(NSUInteger)limit {
    NSMutableArray *result = [NSMutableArray array];
    yozora_record *rows = malloc(sizeof(yozora_record) * YOZORA_STORE_PAGE_LIMIT);
    if (!rows)
        return result;
    while ([result count] < limit) {
        size_t count = 0;
        yozora_status status = fetch(_store, offset + [result count], rows, YOZORA_STORE_PAGE_LIMIT, &count);
        if (status != YOZORA_OK) {
            NSLog(@"yozora: store read failed: %s", yozora_status_string(status));
            break;
        }
        for (size_t i = 0; i < count && [result count] < limit; ++i)
            [result addObject:YZRecordFromCore(&rows[i])];
        if (count < YOZORA_STORE_PAGE_LIMIT)
            break;
    }
    free(rows);
    return result;
}

- (NSArray *)fetchWithSelector:(yozora_status (*)(yozora_store *, size_t, yozora_record *, size_t, size_t *))fetch
                        offset:(NSUInteger)offset limit:(NSUInteger)limit {
    __block NSArray *result = nil;
    dispatch_sync(_queue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        result = [[self readRowsWithSelector:fetch offset:offset limit:limit] retain];
        [pool drain];
    });
    return [result autorelease];
}

- (yozora_status)runOnQueue:(yozora_status (^)(void))work {
    __block yozora_status status = YOZORA_OK;
    dispatch_sync(_queue, ^{ status = work(); });
    return status;
}

- (void)reloadBookmarks {
    NSArray *rows = [self fetchWithSelector:yozora_store_bookmarks offset:0 limit:YOZORA_BOOKMARK_LIMIT];
    [_bookmarks setArray:rows];
    [_bookmarkURLs removeAllObjects];
    for (YZRecord *record in rows)
        [_bookmarkURLs addObject:record.url];
}

- (void)reloadRecent {
    [_recent setArray:[self fetchWithSelector:yozora_store_history offset:0 limit:YZRecentLimit]];
}

- (void)recordVisit:(const yozora_record *)visit failure:(void (^)(NSString *reason))failure {
    yozora_record row = *visit;
    void (^report)(NSString *) = failure ? [failure copy] : nil;
    // the blocks outlive this call, the store must outlive them
    [self retain];
    dispatch_async(_queue, ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        yozora_status status = yozora_store_visit(_store, row.url, row.title, row.time_ms);
        NSString *reason = status == YOZORA_OK ? nil : [NSString stringWithUTF8String:yozora_status_string(status)];
        // the list is read on the same queue, so it already contains the row
        NSArray *recent = status == YOZORA_OK ? [[self readRowsWithSelector:yozora_store_history offset:0 limit:YZRecentLimit] retain] : nil;
        [reason retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (recent)
                [_recent setArray:recent];
            if (reason) {
                NSLog(@"yozora: history write failed: %@", reason);
                if (report)
                    report(reason);
            }
            [recent release];
            [reason release];
            [report release];
            [self release];
        });
        [pool drain];
    });
}

- (void)flush {
    dispatch_sync(_queue, ^{ });
}

- (NSArray *)bookmarks { return _bookmarks; }
- (NSArray *)recentHistory { return _recent; }

- (NSArray *)historyPageAtOffset:(NSUInteger)offset {
    return [self fetchWithSelector:yozora_store_history offset:offset limit:YOZORA_STORE_PAGE_LIMIT];
}

- (BOOL)isBookmarked:(NSString *)url {
    return url && [_bookmarkURLs containsObject:url];
}

- (BOOL)addBookmarkWithURL:(NSString *)url title:(NSString *)title {
    struct timeval now;
    gettimeofday(&now, NULL);
    int64_t millis = (int64_t)now.tv_sec * 1000 + now.tv_usec / 1000;
    yozora_status status = [self runOnQueue:^{ return yozora_store_bookmark(_store, [url UTF8String], title ? [title UTF8String] : "", millis); }];
    if (status != YOZORA_OK) {
        NSLog(@"yozora: bookmark write failed: %s", yozora_status_string(status));
        return NO;
    }
    [self reloadBookmarks];
    return YES;
}

- (BOOL)removeBookmarkWithURL:(NSString *)url {
    yozora_status status = [self runOnQueue:^{ return yozora_store_remove_bookmark(_store, [url UTF8String]); }];
    if (status != YOZORA_OK && status != YOZORA_NOT_FOUND) {
        NSLog(@"yozora: bookmark delete failed: %s", yozora_status_string(status));
        return NO;
    }
    [self reloadBookmarks];
    return YES;
}

- (BOOL)removeHistoryWithURL:(NSString *)url {
    yozora_status status = [self runOnQueue:^{ return yozora_store_remove_history(_store, [url UTF8String]); }];
    if (status != YOZORA_OK && status != YOZORA_NOT_FOUND) {
        NSLog(@"yozora: history delete failed: %s", yozora_status_string(status));
        return NO;
    }
    [self reloadRecent];
    return YES;
}

- (BOOL)clearHistory {
    yozora_status status = [self runOnQueue:^{ return yozora_store_clear_history(_store); }];
    if (status != YOZORA_OK) {
        NSLog(@"yozora: history clear failed: %s", yozora_status_string(status));
        return NO;
    }
    [self reloadRecent];
    return YES;
}

- (void)dealloc {
    [self flush];
    if (_store && yozora_store_close(_store) != YOZORA_OK)
        NSLog(@"yozora: profile did not close cleanly");
    if (_queue)
        dispatch_release(_queue);
    [_bookmarks release];
    [_bookmarkURLs release];
    [_recent release];
    [super dealloc];
}
@end
