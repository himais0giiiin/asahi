#import <Foundation/Foundation.h>
#include "yozora_core.h"

/* the stream proxy (core/yozora_stream_proxy.c): AVPlayer uses the system trust store, too old on ios 5 and 6
   for current CDN certificates, and sends neither cookies nor referer. the loopback proxy verifies the chain
   against the app roots, adds both and rewrites HLS playlists so segments come back to it. one instance
   serves every player. the system closes the socket of a suspended app, so it restarts at the next stream and
   the old streams fail */
@interface YZStreamProxy : NSObject
+ (YZStreamProxy *)shared;
/* the address AVPlayer opens for an OPEN request, nil when the proxy cannot run. *stream and *generation
   identify the registration for releaseStream */
- (NSURL *)proxiedURLForRequest:(const yozora_media_request *)request stream:(unsigned *)stream generation:(unsigned *)generation;
/* the address AVPlayer opens for a stream a page's MediaSource made (core/yozora_hls.h), held by the core
   under the player id. nil when the core has none or the proxy cannot run */
- (NSURL *)localURLForMediaID:(unsigned)mediaID core:(yozora_core *)core stream:(unsigned *)stream generation:(unsigned *)generation;
/* the address of any http or https address through the proxy, with the checks of its trust store and no cookie */
- (NSURL *)proxiedURLForAddress:(NSString *)address stream:(unsigned *)stream generation:(unsigned *)generation;
/* files of this app under the address that is returned (ending in a slash), by name. the paths are fixed for as long as the stream lives */
- (NSURL *)localURLForFiles:(NSDictionary *)files stream:(unsigned *)stream generation:(unsigned *)generation;
/* forgets a stream; a stream of an older proxy is left alone, ids start again with every proxy */
- (void)releaseStream:(unsigned)stream generation:(unsigned)generation;
/* the roots changed (a certificate was added or taken away): the proxy stops and the next stream starts one with the new file, streams in
   flight fail */
- (void)rootsChanged;
@end
