#import <Foundation/Foundation.h>
#include "yozora_store.h"

/* a history or bookmark row copied out of the C store */
@interface YZRecord : NSObject {
    NSString *_url;
    NSString *_title;
    int64_t _visits;
    int64_t _timeMs;
}
@property(nonatomic, copy) NSString *url;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, assign) int64_t visits;
@property(nonatomic, assign) int64_t timeMs;
/* the title, or the address when the page has none */
- (NSString *)displayTitle;
@end

/* owns one yozora_store. every call into the core runs on one serial queue because the core is not thread
   safe, the lists the interface reads are touched on the main thread only */
@interface YZStore : NSObject {
    yozora_store *_store;
    dispatch_queue_t _queue;
    NSMutableArray *_bookmarks;
    NSMutableSet *_bookmarkURLs;
    NSMutableArray *_recent;
}
/* the selected durable profile directory, shared by the store and site data */
+ (NSString *)profileDirectory;
+ (BOOL)usesDocumentsProfile;
/* opens ~/Library/Yozora; on failure returns nil and fills error */
+ (YZStore *)openDefaultStore:(NSString **)error;
/* returns at once, the row is written on the store queue. failure runs on the main thread with the reason */
- (void)recordVisit:(const yozora_record *)visit failure:(void (^)(NSString *reason))failure;
/* waits until every queued write is on disk, for the moment the app leaves the foreground */
- (void)flush;
- (NSArray *)bookmarks;
- (NSArray *)recentHistory;
- (NSArray *)historyPageAtOffset:(NSUInteger)offset;
- (BOOL)isBookmarked:(NSString *)url;
- (BOOL)addBookmarkWithURL:(NSString *)url title:(NSString *)title;
- (BOOL)removeBookmarkWithURL:(NSString *)url;
- (BOOL)removeHistoryWithURL:(NSString *)url;
- (BOOL)clearHistory;
@end
