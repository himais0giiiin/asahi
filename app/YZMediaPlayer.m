#import "YZMediaPlayer.h"
#import "YZStreamProxy.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <dlfcn.h>
#include <math.h>

static const int32_t YZTimescale = 600;
static const NSTimeInterval YZTimeStep = 0.25;
static char YZStatusContext;
static char YZRateContext;
static char YZBufferContext;
static char YZSizeContext;
static char YZDisplayContext;
// notification names and keys of ios 6 are plain strings here, the symbols are absent from the ios 5 runtime
static NSString *const YZInterruptionName = @"AVAudioSessionInterruptionNotification";
static NSString *const YZInterruptionTypeKey = @"AVAudioSessionInterruptionTypeKey";
// the number of players that hold the playback audio session, which is released with the last of them
static NSUInteger YZSessionHolders;

@interface YZMediaPlayer () {
    yozora_core *_core;
    unsigned _mediaID;
    NSString *_title;
    AVPlayer *_player;
    AVPlayerItem *_item;
    AVPlayerLayer *_layer;
    id _timeToken;
    double _rate;
    double _volume;
    BOOL _muted;
    BOOL _wantPlaying;
    BOOL _ended;
    BOOL _shut;
    BOOL _observing;
    BOOL _layerObserving;
    BOOL _holdsSession;
    BOOL _keepSession;
    BOOL _sentSize;
    BOOL _sentFrame;
    BOOL _displayEvents;
    BOOL _failed;
    NSUInteger _seekToken;
    unsigned _streamID;
    unsigned _streamGeneration;
}
- (void)send:(yozora_media_event_kind)kind value:(double)value extra:(double)extra;
- (void)reportItem;
- (void)reportBuffer;
- (void)reportSize;
- (void)failWithError:(NSError *)error;
- (void)updateSession;
- (BOOL)activateSession:(AVAudioSession *)session category:(NSString *)category;
- (void)applyVolume;
@end

@implementation YZMediaPlayer

@synthesize mediaID = _mediaID;
@synthesize title = _title;

- (id)initWithRequest:(const yozora_media_request *)request core:(yozora_core *)core {
    self = [super init];
    if (!self)
        return nil;
    _core = core;
    _mediaID = request->id;
    _title = [[NSString stringWithUTF8String:request->title] copy];
    _rate = 1;
    _volume = 1;
    // a MediaSource of a page has no address: its stream is made by the core and served by the proxy from memory
    BOOL local = strncmp(request->url, "yozora-hls:", 11) == 0;
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:request->url]];
    NSString *scheme = [[url scheme] lowercaseString];
    if (local) {
        NSURL *playURL = [[YZStreamProxy shared] localURLForMediaID:_mediaID core:_core stream:&_streamID generation:&_streamGeneration];
        if (!playURL) {
            NSLog(@"yozora: media %u has no stream of a media source", _mediaID);
            [self send:YOZORA_MEDIA_ERROR value:4 extra:0];
            _shut = YES;
            _failed = YES;
            return self;
        }
        NSLog(@"yozora: media %u plays the stream of a media source at %@", _mediaID, [playURL path]);
        url = playURL;
    } else if (!url || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        [self send:YOZORA_MEDIA_ERROR value:4 extra:0];
        _shut = YES;
        _failed = YES;
        return self;
    }
    // the stream goes through the app proxy: it verifies certificates against the app roots and sends the
    // cookie and referer of the page, which the system player does not. when the proxy cannot run (no socket,
    // no roots) the address is played directly
    NSURL *playURL = local ? url : [[YZStreamProxy shared] proxiedURLForRequest:request stream:&_streamID generation:&_streamGeneration];
    if (!playURL) {
        NSLog(@"yozora: media %u plays %@ without the proxy", _mediaID, [url host]);
        _streamID = 0;
        playURL = url;
    }
    _player = [[AVPlayer alloc] initWithURL:playURL];
    _item = [_player.currentItem retain];
    if (!_item) {
        [self send:YOZORA_MEDIA_ERROR value:4 extra:0];
        _shut = YES;
        _failed = YES;
        return self;
    }
    if (request->video) {
        _layer = [[AVPlayerLayer playerLayerWithPlayer:_player] retain];
        // the page already sized the layer to the picture, with the proportions of the video
        _layer.videoGravity = AVLayerVideoGravityResize;
        _layer.backgroundColor = [[UIColor blackColor] CGColor];
        // readyForDisplay exists from ios 6, earlier systems send the first picture with the first data
        if ([_layer respondsToSelector:@selector(isReadyForDisplay)]) {
            [_layer addObserver:self forKeyPath:@"readyForDisplay" options:0 context:&YZDisplayContext];
            _layerObserving = YES;
            _displayEvents = YES;
        }
    }
    [_item addObserver:self forKeyPath:@"status" options:0 context:&YZStatusContext];
    [_item addObserver:self forKeyPath:@"loadedTimeRanges" options:0 context:&YZBufferContext];
    [_item addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:0 context:&YZBufferContext];
    [_item addObserver:self forKeyPath:@"playbackBufferEmpty" options:0 context:&YZBufferContext];
    [_item addObserver:self forKeyPath:@"presentationSize" options:0 context:&YZSizeContext];
    [_player addObserver:self forKeyPath:@"rate" options:0 context:&YZRateContext];
    _observing = YES;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(itemEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:_item];
    [center addObserver:self selector:@selector(itemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:_item];
    [center addObserver:self selector:@selector(sessionInterrupted:) name:YZInterruptionName object:nil];
    [center addObserver:self selector:@selector(appBecameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    // the block does not retain the player, shutDown removes the observer before the player goes
    __block YZMediaPlayer *player = self;
    _timeToken = [[_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(YZTimeStep, YZTimescale) queue:NULL
                                                   usingBlock:^(CMTime time) { [player tick:CMTimeGetSeconds(time)]; }] retain];
    return self;
}

- (void)dealloc {
    [self shutDown];
    [_layer release];
    [_title release];
    [super dealloc];
}

- (BOOL)playing { return !_shut && _player.rate > 0; }
- (BOOL)failed { return _failed; }
- (double)position {
    double seconds = _player ? CMTimeGetSeconds([_player currentTime]) : 0;
    return isfinite(seconds) && seconds > 0 ? seconds : 0;
}
- (double)duration {
    double seconds = _item && CMTIME_IS_NUMERIC(_item.duration) ? CMTimeGetSeconds(_item.duration) : 0;
    return isfinite(seconds) && seconds > 0 ? seconds : 0;
}

- (double)bufferedEnd {
    if (!_item)
        return 0;
    double position = CMTimeGetSeconds([_player currentTime]);
    for (NSValue *value in _item.loadedTimeRanges) {
        CMTimeRange range = [value CMTimeRangeValue];
        double start = CMTimeGetSeconds(range.start);
        double end = start + CMTimeGetSeconds(range.duration);
        if (isfinite(start) && isfinite(end) && position + 0.5 >= start && position <= end + 0.5)
            return end;
    }
    return 0;
}

// asked to play, not ended, and the picture does not move: the stream opens or ran dry
- (BOOL)buffering {
    return !_shut && !_failed && _wantPlaying && !_ended && _player.rate == 0;
}

- (BOOL)muted { return _muted; }
- (void)setMuted:(BOOL)muted {
    if (_shut || muted == _muted)
        return;
    _muted = muted;
    [self applyVolume];
    [self updateSession];
}

- (double)playbackRate { return _rate; }
- (void)setPlaybackRate:(double)rate {
    if (_shut || !isfinite(rate) || rate <= 0)
        return;
    _rate = rate;
    if (_wantPlaying)
        _player.rate = (float)_rate;
}

- (void)skipBy:(double)seconds {
    if (_shut || !isfinite(seconds))
        return;
    double target = self.position + seconds;
    double length = self.duration;
    if (length > 0)
        target = MIN(target, length);
    [self seekTo:MAX(target, 0)];
}

- (CALayer *)videoLayer {
    return _layer;
}

- (void)send:(yozora_media_event_kind)kind value:(double)value extra:(double)extra {
    if (_core)
        yozora_core_media_event(_core, _mediaID, kind, value, extra);
}

#pragma mark requests

- (void)handleRequest:(const yozora_media_request *)request {
    if (_shut)
        return;
    switch (request->command) {
    case YOZORA_MEDIA_PLAY:
        if (request->value > 0)
            _rate = request->value;
        [self play];
        break;
    case YOZORA_MEDIA_PAUSE:
        [self pause];
        break;
    case YOZORA_MEDIA_SEEK:
        [self seekTo:request->value];
        break;
    case YOZORA_MEDIA_VOLUME:
        _volume = request->value;
        _muted = request->muted != 0;
        [self applyVolume];
        [self updateSession];
        break;
    case YOZORA_MEDIA_RATE:
        if (request->value > 0)
            _rate = request->value;
        if (_wantPlaying)
            _player.rate = (float)_rate;
        break;
    case YOZORA_MEDIA_CLOSE:
        [self shutDown];
        break;
    default:
        break;
    }
}

- (void)play {
    _wantPlaying = YES;
    _keepSession = YES;
    _ended = NO;
    BOOL held = _holdsSession;
    [self updateSession];
    // a session kept through a pause may have been deactivated by the system while the app was away
    if (held)
        [self appBecameActive:nil];
    _player.rate = (float)_rate;
}

- (void)pause {
    _wantPlaying = NO;
    [_player pause];
}

- (void)seekTo:(double)seconds {
    if (!isfinite(seconds))
        return;
    _ended = NO;
    NSUInteger token = ++_seekToken;
    YZMediaPlayer *player = self;
    [_player seekToTime:CMTimeMakeWithSeconds(MAX(seconds, 0), YZTimescale) completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // a newer seek replaced this one, its own completion reports
            if (!finished || player->_shut || token != player->_seekToken)
                return;
            [player send:YOZORA_MEDIA_SEEKED value:CMTimeGetSeconds([player->_player currentTime]) extra:0];
        });
    }];
}

// ios 7 has volume and muted on the player, earlier systems get the same through an audio mix on the tracks.
// set by key because the ios 5 headers do not declare them
- (void)applyVolume {
    if ([_player respondsToSelector:@selector(setMuted:)]) {
        [_player setValue:[NSNumber numberWithFloat:(float)_volume] forKey:@"volume"];
        [_player setValue:[NSNumber numberWithBool:_muted] forKey:@"muted"];
        return;
    }
    float volume = _muted ? 0 : (float)_volume;
    NSArray *tracks = [_item.asset tracksWithMediaType:AVMediaTypeAudio];
    if (![tracks count])
        return;
    NSMutableArray *parameters = [NSMutableArray array];
    for (AVAssetTrack *track in tracks) {
        AVMutableAudioMixInputParameters *input = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
        [input setVolume:volume atTime:kCMTimeZero];
        [parameters addObject:input];
    }
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = parameters;
    _item.audioMix = mix;
}

// without the playback category the silent switch mutes the sound of a video; a muted video leaves the audio of other apps alone.
// the session stays active through a pause: deactivating it on every pause and activating it on every play tore the
// audio pipeline of the player down and up again under the resumed sound (crackle, a dropped start, silence until the
// next pause). it is let go when the video ends, is interrupted, is muted or closed
- (void)updateSession {
    BOOL needed = _keepSession && !_muted && _volume > 0 && !_shut;
    if (needed == _holdsSession)
        return;
    // the ios 16 sdk binds these exports to AVFAudio instead of the AVFoundation present on ios 5 and 7
    Class sessionClass = NSClassFromString(@"AVAudioSession");
    AVAudioSession *session = [sessionClass sharedInstance];
    NSString *const *category = (NSString *const *)dlsym(RTLD_DEFAULT, "AVAudioSessionCategoryPlayback");
    if (!session || (needed && (!category || !*category))) {
        NSLog(@"yozora: playback audio session is unavailable");
        return;
    }
    NSError *error = nil;
    if (needed) {
        // a player that failed to take the session does not hold it, so the next play asks again
        if (![self activateSession:session category:*category])
            return;
        _holdsSession = YES;
        ++YZSessionHolders;
    } else {
        _holdsSession = NO;
        if (--YZSessionHolders == 0 && ![session setActive:NO error:&error] && error)
            NSLog(@"yozora: audio session release: %@", error);
    }
}

// another app or a call can leave the session on a category that is silent for a video. the category is set only
// when it differs: setting it again on a running session is a category change for the route, which the player hears
- (BOOL)activateSession:(AVAudioSession *)session category:(NSString *)category {
    NSError *error = nil;
    if ((![[session category] isEqualToString:category] && ![session setCategory:category error:&error]) || ![session setActive:YES error:&error]) {
        NSLog(@"yozora: audio session: %@", error);
        return NO;
    }
    return YES;
}

// the system deactivates the session while the app is away or after a call, a player that holds it asks for it again
- (void)appBecameActive:(NSNotification *)notification {
    (void)notification;
    if (_shut || !_holdsSession)
        return;
    Class sessionClass = NSClassFromString(@"AVAudioSession");
    NSString *const *category = (NSString *const *)dlsym(RTLD_DEFAULT, "AVAudioSessionCategoryPlayback");
    if ([sessionClass sharedInstance] && category && *category)
        [self activateSession:[sessionClass sharedInstance] category:*category];
}

- (void)sessionInterrupted:(NSNotification *)notification {
    if (_shut || ![[[notification userInfo] objectForKey:YZInterruptionTypeKey] intValue])
        return;
    // a call or an alarm took the audio: the page is told that the player paused, it plays again only when asked
    if (_wantPlaying) {
        _wantPlaying = NO;
        [_player pause];
        [self send:YOZORA_MEDIA_PAUSED value:0 extra:0];
    }
    _keepSession = NO;
    [self updateSession];
}

#pragma mark state

- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &YZStatusContext && context != &YZRateContext && context != &YZBufferContext && context != &YZSizeContext && context != &YZDisplayContext) {
        [super observeValueForKeyPath:path ofObject:object change:change context:context];
        return;
    }
    // key value observers may run on the thread that changed the value
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self observeValueForKeyPath:path ofObject:object change:change context:context]; });
        return;
    }
    if (_shut)
        return;
    if (context == &YZStatusContext) {
        if (_item.status == AVPlayerItemStatusFailed) {
            [self failWithError:_item.error];
            return;
        }
        if (_item.status == AVPlayerItemStatusReadyToPlay)
            [self reportItem];
    } else if (context == &YZBufferContext) {
        [self reportBuffer];
    } else if (context == &YZSizeContext) {
        [self reportSize];
    } else if (context == &YZDisplayContext) {
        if ([[_layer valueForKey:@"readyForDisplay"] boolValue] && !_sentFrame) {
            _sentFrame = YES;
            [self send:YOZORA_MEDIA_FRAME value:0 extra:0];
        }
    } else {
        [self reportRate];
    }
}

// the length, the size and the first words on buffering, once the item knows what it is
- (void)reportItem {
    CMTime length = _item.duration;
    double seconds = CMTIME_IS_NUMERIC(length) ? CMTimeGetSeconds(length) : 0;
    [self send:YOZORA_MEDIA_DURATION value:(isfinite(seconds) && seconds > 0) ? seconds : 0 extra:0];
    [self reportSize];
    [self applyVolume];
    [self reportBuffer];
}

- (void)reportSize {
    if (_item.status != AVPlayerItemStatusReadyToPlay)
        return;
    CGSize size = _item.presentationSize;
    if (size.width < 1 || size.height < 1) {
        NSArray *tracks = [_item.asset tracksWithMediaType:AVMediaTypeVideo];
        if ([tracks count])
            size = [[tracks objectAtIndex:0] naturalSize];
    }
    BOOL known = size.width >= 1 && size.height >= 1;
    // a video that is still at 0 by 0 is told again when the size arrives, sound has no size at all
    if (_layer && !known)
        return;
    if (_sentSize && !_layer)
        return;
    _sentSize = YES;
    [self send:YOZORA_MEDIA_SIZE value:known ? size.width : 0 extra:known ? size.height : 0];
    if (known && !_displayEvents && !_sentFrame) {
        _sentFrame = YES;
        [self send:YOZORA_MEDIA_FRAME value:0 extra:0];
    }
}

- (void)reportBuffer {
    if (_item.status != AVPlayerItemStatusReadyToPlay)
        return;
    double position = CMTimeGetSeconds([_player currentTime]);
    for (NSValue *value in _item.loadedTimeRanges) {
        CMTimeRange range = [value CMTimeRangeValue];
        double start = CMTimeGetSeconds(range.start);
        double end = start + CMTimeGetSeconds(range.duration);
        if (isfinite(start) && isfinite(end) && position + 0.5 >= start && position <= end + 0.5) {
            [self send:YOZORA_MEDIA_BUFFERED value:start extra:end];
            break;
        }
    }
    if (_item.playbackBufferEmpty && _wantPlaying) {
        [self send:YOZORA_MEDIA_READY value:0 extra:0];
    } else if (_item.playbackLikelyToKeepUp || _item.playbackBufferFull) {
        [self send:YOZORA_MEDIA_READY value:1 extra:0];
        // before ios 10 a player that ran dry stays stopped when data comes back
        if (_wantPlaying && _player.rate == 0 && !_ended)
            _player.rate = (float)_rate;
    }
}

- (void)reportRate {
    if (_player.rate > 0) {
        _ended = NO;
        [self send:YOZORA_MEDIA_PLAYING value:0 extra:0];
        return;
    }
    // a stop that nobody asked for is the player running dry; the user's pause and the end of the stream are reported on their own
    if (_wantPlaying && !_ended)
        [self send:YOZORA_MEDIA_READY value:0 extra:0];
    else if (!_ended)
        [self send:YOZORA_MEDIA_PAUSED value:0 extra:0];
}

- (void)tick:(double)seconds {
    if (_shut || !isfinite(seconds) || seconds < 0)
        return;
    [self send:YOZORA_MEDIA_TIME value:seconds extra:0];
}

- (void)itemEnded:(NSNotification *)notification {
    (void)notification;
    if (_shut)
        return;
    _ended = YES;
    _wantPlaying = NO;
    _keepSession = NO;
    [self send:YOZORA_MEDIA_ENDED value:0 extra:0];
    [self updateSession];
}

- (void)itemFailed:(NSNotification *)notification {
    [self failWithError:[[notification userInfo] objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey]];
}

// 2 for the network, 4 for a stream the system does not open, 3 for the rest
- (void)failWithError:(NSError *)error {
    if (_shut)
        return;
    _failed = YES;
    NSLog(@"yozora: media %u: %@", _mediaID, error);
    int code = 3;
    if ([[error domain] isEqualToString:NSURLErrorDomain])
        code = 2;
    else if ([error code] == -11828 || [error code] == -11829 || [error code] == -11800)
        code = 4;
    [self send:YOZORA_MEDIA_ERROR value:code extra:0];
    [self shutDown];
}

- (void)shutDown {
    if (_shut)
        return;
    _shut = YES;
    _wantPlaying = NO;
    [self updateSession];
    if (_streamID) {
        [[YZStreamProxy shared] releaseStream:_streamID generation:_streamGeneration];
        _streamID = 0;
    }
    if (_observing) {
        [_item removeObserver:self forKeyPath:@"status" context:&YZStatusContext];
        [_item removeObserver:self forKeyPath:@"loadedTimeRanges" context:&YZBufferContext];
        [_item removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:&YZBufferContext];
        [_item removeObserver:self forKeyPath:@"playbackBufferEmpty" context:&YZBufferContext];
        [_item removeObserver:self forKeyPath:@"presentationSize" context:&YZSizeContext];
        [_player removeObserver:self forKeyPath:@"rate" context:&YZRateContext];
        _observing = NO;
    }
    if (_layerObserving) {
        [_layer removeObserver:self forKeyPath:@"readyForDisplay" context:&YZDisplayContext];
        _layerObserving = NO;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_timeToken) {
        [_player removeTimeObserver:_timeToken];
        [_timeToken release];
        _timeToken = nil;
    }
    [_player pause];
    [_layer removeFromSuperlayer];
    _layer.player = nil;
    [_item release];
    _item = nil;
    [_player release];
    _player = nil;
}

@end
