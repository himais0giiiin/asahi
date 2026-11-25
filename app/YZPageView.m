#import "YZPageView.h"
#import "YZSceneView.h"
#import "YZMediaPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import "YZTheme.h"
#import "YZStrings.h"
#import <QuartzCore/QuartzCore.h>
#include "yozora_zoom.h"

// the same decay as the system scroll view, 0.998 per millisecond
static const float YZFlingDecayPerMillisecond = 0.998f;
static const float YZFlingMinimumVelocity = 15.0f;
static const float YZFlingStartVelocity = 60.0f;

// the knob of a selection end: the stem lies along the line of text, the knob is on the outer side of it
@interface YZSelectionHandle : UIView {
    BOOL _isEnd;
    CGFloat _caretHeight;
}
@property(nonatomic, assign) BOOL isEnd;
@property(nonatomic, assign) CGFloat caretHeight;
@end

@implementation YZSelectionHandle
@synthesize isEnd = _isEnd;
@synthesize caretHeight = _caretHeight;

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef context = UIGraphicsGetCurrentContext();
    [[YZTheme accentColor] setFill];
    CGFloat centre = self.bounds.size.width / 2;
    CGFloat stemTop = _isEnd ? 0 : 14;
    CGContextFillRect(context, CGRectMake(centre - 1, stemTop, 2, _caretHeight));
    CGFloat knobY = _isEnd ? _caretHeight + 7 : 7;
    CGContextFillEllipseInRect(context, CGRectMake(centre - 7, knobY - 7, 14, 14));
}
@end

// the responder that the menu of a selection acts on, it has no keyboard unlike the page view that takes typed text
@interface YZSelectionMenuTarget : UIView {
    YZPageView *_page;
}
@property(nonatomic, assign) YZPageView *page;
@end

@implementation YZSelectionMenuTarget
@synthesize page = _page;
- (BOOL)canBecomeFirstResponder {
    return YES;
}
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    (void)sender;
    return action == @selector(copy:) || action == @selector(selectAll:) || action == @selector(shareSelection:);
}
- (void)shareSelection:(id)sender {
    (void)sender;
    [_page shareSelection];
}
- (void)copy:(id)sender {
    (void)sender;
    [_page copySelection];
}
- (void)selectAll:(id)sender {
    (void)sender;
    [_page selectEverything];
}
@end

// the keyboard talks about the text it edits through positions and ranges. the page is not mirrored here: the only text this view
// knows is what is being composed, so a position is an offset into that and nothing else
@interface YZTextPosition : UITextPosition {
@public
    NSInteger offset;
}
+ (YZTextPosition *)positionAt:(NSInteger)offset;
@end
@implementation YZTextPosition
+ (YZTextPosition *)positionAt:(NSInteger)offset {
    YZTextPosition *position = [[[YZTextPosition alloc] init] autorelease];
    position->offset = MAX((NSInteger)0, offset);
    return position;
}
@end

@interface YZTextRange : UITextRange {
    YZTextPosition *_start;
    YZTextPosition *_end;
}
+ (YZTextRange *)rangeFrom:(NSInteger)start to:(NSInteger)end;
@end
@implementation YZTextRange
+ (YZTextRange *)rangeFrom:(NSInteger)start to:(NSInteger)end {
    YZTextRange *range = [[[YZTextRange alloc] init] autorelease];
    range->_start = [[YZTextPosition positionAt:MIN(start, end)] retain];
    range->_end = [[YZTextPosition positionAt:MAX(start, end)] retain];
    return range;
}
- (void)dealloc {
    [_start release];
    [_end release];
    [super dealloc];
}
- (UITextPosition *)start { return _start; }
- (UITextPosition *)end { return _end; }
- (BOOL)isEmpty { return _start->offset == _end->offset; }
@end

static NSInteger YZOffsetOf(UITextPosition *position) {
    return [position isKindOfClass:[YZTextPosition class]] ? ((YZTextPosition *)position)->offset : 0;
}

typedef struct {
    CALayer *host;
    int x, y, width, height, scroll;
    uint64_t layer;
    CGRect frame;
} YZVideoPlace;

@implementation YZPageView
@synthesize selectionHidden = _selectionHidden;
@synthesize core = _core;
@synthesize delegate = _delegate;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.backgroundColor = [UIColor whiteColor];
    // tiles reach past the view above and below
    self.clipsToBounds = YES;
    self.opaque = YES;
    self.clearsContextBeforeDrawing = NO;
    yozora_view_zoom_reset(&_zoom);
    _appliedRasterFactor = 1.0f;
    // the tiles and the video layers sit in one host that the pinch scales, the handles of a selection stay outside it at their own size
    _zoomHost = [[UIView alloc] initWithFrame:self.bounds];
    _zoomHost.userInteractionEnabled = NO;
    _zoomHost.backgroundColor = [UIColor clearColor];
    [self addSubview:_zoomHost];
    _sceneView = [[YZSceneView alloc] initWithFrame:_zoomHost.bounds];
    [_zoomHost addSubview:_sceneView];
    _zoomBoundsSize = self.bounds.size;
    // the tiles are handed to layers as they are, so no drawRect copy sits on the scroll path
    self.contentScaleFactor = [[UIScreen mainScreen] scale];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    // two fingers belong to the pinch
    pan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:pan];
    [pan release];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
    [self addGestureRecognizer:pinch];
    [pinch release];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
    [self addGestureRecognizer:tap];
    [tap release];
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    press.minimumPressDuration = 0.5;
    [self addGestureRecognizer:press];
    [press release];
    return self;
}

- (void)dealloc {
    [_startHandle release];
    [_endHandle release];
    [_menuTarget release];
    [_shareItem release];
    [_sceneView release];
    [_marked release];
    [(id)_tokenizer release];
    [_zoomHost release];
    [_mediaLayers release];
    [_videoPlaces release];
    [super dealloc];
}

- (void)setCore:(yozora_core *)core {
    _core = core;
    yozora_view_zoom_reset(&_zoom);
    _zoomScrollRemainder = 0;
    [self applyZoom];
    // the core of another tab keeps the scale it was painted at, the zoom of this view starts again at 1
    if (_core)
        [self notifyRasterFactor];
    [self hideSelection];
    _inputKind = YOZORA_INPUT_NONE;
    // a tap in another tab must not raise the keyboard of this page
    _tapTime = 0;
    if ([self isFirstResponder])
        [self resignFirstResponder];
}

- (BOOL)flinging {
    return _flingVelocity != 0 || _flingVelocityX != 0;
}

- (BOOL)active {
    return _panning || _pinching || [self flinging];
}

- (void)showScene:(yozora_scene *)scene {
    [_sceneView showScene:scene];
    // the layers stand where this scene put them, before the scroll of the moment moves them
    [self measureVideos:YES];
    // where a tile is not there yet the page color shows, not white, a dark page flashed white when scrolled
    // faster than it was painted
    if (scene && !*yozora_scene_error(scene)) {
        const yozora_scene_layer *layers = yozora_scene_layers(scene);
        unsigned count = yozora_scene_layer_count(scene);
        for (unsigned i = 0; i < count; ++i) {
            if (layers[i].parent || (layers[i].background >> 24) != 0xff)
                continue;
            uint32_t color = layers[i].background;
            UIColor *ground = [UIColor colorWithRed:((color >> 16) & 255) / 255.0f green:((color >> 8) & 255) / 255.0f blue:(color & 255) / 255.0f alpha:1];
            if (![self.backgroundColor isEqual:ground])
                self.backgroundColor = ground;
            break;
        }
    }
    [self syncScrollOffset];
}

- (void)syncScrollOffset {
    if (_core)
        [_sceneView scrollWithCore:_core];
}

// where a video stands in the layer that holds it, fixed when the scene of its layout arrives. the layer follows its
// scroll node, a fixed or sticky player included, so the place needs no scroll position after that. the old place was
// worked out from the scroll of every frame and slid off a fixed player (YouTube pins its player) while the page scrolled
- (void)measureVideos:(BOOL)force {
    if (!_core)
        return;
    if (!_videoPlaces)
        _videoPlaces = [[NSMutableDictionary alloc] init];
    yozora_video videos[YOZORA_MAX_VIDEOS];
    int count = yozora_core_videos(_core, videos, YOZORA_MAX_VIDEOS);
    int scroll = yozora_core_scroll_y(_core);
    NSMutableSet *present = [NSMutableSet set];
    for (int i = 0; i < count; ++i) {
        NSNumber *key = [NSNumber numberWithUnsignedInt:videos[i].id];
        [present addObject:key];
        CALayer *host = [_sceneView contentsLayerForLayerID:videos[i].layer];
        NSValue *saved = [_videoPlaces objectForKey:key];
        if (saved && !force) {
            YZVideoPlace old;
            [saved getValue:&old];
            if (old.host == host && old.x == videos[i].x && old.y == videos[i].y && old.width == videos[i].width
                && old.height == videos[i].height && old.layer == videos[i].layer)
                continue;
        }
        YZVideoPlace place;
        memset(&place, 0, sizeof(place));
        place.host = host;
        place.x = videos[i].x;
        place.y = videos[i].y;
        place.width = videos[i].width;
        place.height = videos[i].height;
        place.layer = videos[i].layer;
        place.scroll = scroll;
        CGRect box = CGRectMake(videos[i].x, videos[i].y, videos[i].width, videos[i].height);
        place.frame = host ? [host convertRect:box fromLayer:_zoomHost.layer] : box;
        [_videoPlaces setObject:[NSValue valueWithBytes:&place objCType:@encode(YZVideoPlace)] forKey:key];
    }
    for (NSNumber *key in [_videoPlaces allKeys]) {
        if (![present containsObject:key])
            [_videoPlaces removeObjectForKey:key];
    }
}

- (void)showMediaPlayers:(NSArray *)players excluding:(unsigned)fullscreenID {
    if (!_mediaLayers)
        _mediaLayers = [[NSMutableDictionary alloc] init];
    // a list that changed without a new scene (the first picture came) is measured here
    [self measureVideos:NO];
    int scroll = yozora_core_scroll_y(_core);
    NSMutableSet *present = [NSMutableSet set];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (YZMediaPlayer *player in players) {
        CALayer *layer = player.videoLayer;
        if (!layer || player.mediaID == fullscreenID)
            continue;
        NSNumber *key = [NSNumber numberWithUnsignedInt:player.mediaID];
        NSValue *saved = [_videoPlaces objectForKey:key];
        if (!saved)
            continue;
        YZVideoPlace place;
        [saved getValue:&place];
        [present addObject:key];
        // the full screen player puts the picture whole on the screen, on the page it is stretched over the rectangle
        // the page gave it, which has the proportions of the video
        if ([layer isKindOfClass:[AVPlayerLayer class]] && ![((AVPlayerLayer *)layer).videoGravity isEqualToString:AVLayerVideoGravityResize])
            ((AVPlayerLayer *)layer).videoGravity = AVLayerVideoGravityResize;
        // the picture goes into the layer that holds the video, over its tiles and under the layers
        // above, so a black background a player page paints under the video (YouTube) does not hide it
        // and the controls stay over it. an unknown layer puts it under the whole page
        if (place.host) {
            // the tiles that come later are added over it, so it is put last again whenever it is not
            if (layer.superlayer != place.host || [place.host.sublayers lastObject] != layer)
                [place.host addSublayer:layer];
            if (!CGRectEqualToRect(layer.frame, place.frame))
                layer.frame = place.frame;
        } else {
            if (layer.superlayer != _zoomHost.layer)
                [_zoomHost.layer insertSublayer:layer below:_sceneView.layer];
            CGRect frame = place.frame;
            frame.origin.y += place.scroll - scroll;
            layer.frame = frame;
        }
        [_mediaLayers setObject:layer forKey:key];
    }
    for (NSNumber *key in [_mediaLayers allKeys]) {
        if (![present containsObject:key]) {
            CALayer *layer = [_mediaLayers objectForKey:key];
            // the layer of the player on the full screen belongs to that player's view since it was presented, which put the layer in its
            // stage when it loaded: taking it off its superlayer here pulled the picture out of the full screen the frame after it came up.
            // the page only forgets it, and takes it back through the loop above when the full screen is left
            if (fullscreenID == 0 || [key unsignedIntValue] != fullscreenID)
                [layer removeFromSuperlayer];
            [_mediaLayers removeObjectForKey:key];
        }
    }
    [CATransaction commit];
}

- (void)clearFrame {
    [_sceneView clearScene];
    for (CALayer *layer in [_mediaLayers allValues]) {
        if (layer.superlayer == _zoomHost.layer)
            [layer removeFromSuperlayer];
    }
    [_mediaLayers removeAllObjects];
    [_videoPlaces removeAllObjects];
}

- (void)stopFling {
    _flingVelocity = 0;
    _flingRemainder = 0;
    _flingVelocityX = 0;
    _flingRemainderX = 0;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self stopFling];
    [super touchesBegan:touches withEvent:event];
}

// moves what is under the finger: a block that scrolls on its own takes what it can, the page the rest.
// returns how much of each direction was used so a drag against an end answers at once. an enlarged view
// moves over the viewport first
- (void)scrollByX:(int)x y:(int)y usedX:(int *)usedX usedY:(int *)usedY {
    float scale = _zoom.scale;
    CGPoint point = _gesturePoint;
    if (scale > 1.0f) {
        float px, py;
        yozora_view_zoom_to_viewport(&_zoom, point.x, point.y, &px, &py);
        point = CGPointMake(px, py);
    }
    // the block gets whole points of the page: a drag of 3 screen points at scale 3 is one
    int blockX = (int)lroundf(x / scale), blockY = (int)lroundf(y / scale);
    int restX = blockX, restY = blockY;
    if (blockX || blockY)
        yozora_core_scroll_inner(_core, (int)lroundf(point.x), (int)lroundf(point.y), blockX, blockY, &restX, &restY);
    if (scale <= 1.0f) {
        int moved = restY ? yozora_core_scroll(_core, restY) : 0;
        *usedX = x - restX;
        *usedY = (y - restY) + moved;
        return;
    }
    float screenX = x - (blockX - restX) * scale;
    float screenY = y - (blockY - restY) * scale;
    CGSize size = self.bounds.size;
    float pageX = 0, pageY = 0;
    yozora_view_zoom_pan(&_zoom, screenX, screenY, size.width, size.height, &pageX, &pageY);
    [self applyZoom];
    // the page scrolls in whole points, the part of a point that is left waits for the next move
    float wanted = pageY + _zoomScrollRemainder;
    int step = (int)wanted;
    int moved = step ? yozora_core_scroll(_core, step) : 0;
    float unusedY = 0;
    if (moved == step)
        _zoomScrollRemainder = wanted - step;
    else {
        _zoomScrollRemainder = 0;
        unusedY = wanted - moved;
    }
    *usedX = x - (int)lroundf(pageX * scale);
    *usedY = y - (int)lroundf(unusedY * scale);
}

// the drag reaches the page as touch events too, a zoomed view maps the finger back to the viewport point
- (void)deliverTouchForPan:(UIPanGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self];
    if (_zoom.scale > 1.0f) {
        float px, py;
        yozora_view_zoom_to_viewport(&_zoom, point.x, point.y, &px, &py);
        point = CGPointMake(px, py);
    }
    switch (gesture.state) {
    case UIGestureRecognizerStateBegan: {
        CGPoint origin = _gesturePoint;
        if (_zoom.scale > 1.0f) {
            float px, py;
            yozora_view_zoom_to_viewport(&_zoom, origin.x, origin.y, &px, &py);
            origin = CGPointMake(px, py);
        }
        yozora_core_touch(_core, 0, (int)lroundf(origin.x), (int)lroundf(origin.y));
        yozora_core_touch(_core, 1, (int)lroundf(point.x), (int)lroundf(point.y));
        break;
    }
    case UIGestureRecognizerStateChanged:
        yozora_core_touch(_core, 1, (int)lroundf(point.x), (int)lroundf(point.y));
        break;
    case UIGestureRecognizerStateEnded:
        yozora_core_touch(_core, 2, (int)lroundf(point.x), (int)lroundf(point.y));
        break;
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        yozora_core_touch(_core, 3, (int)lroundf(point.x), (int)lroundf(point.y));
        break;
    default:
        break;
    }
}

- (void)pan:(UIPanGestureRecognizer *)gesture {
    if (!_core)
        return;
    CGPoint translation = [gesture translationInView:self];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self stopFling];
        _panLast = 0;
        _panLastX = 0;
        _zoomScrollRemainder = 0;
        _panning = YES;
        // the recognizer starts after the finger moved a little, the touch itself began where the gesture says
        _gesturePoint = [gesture locationInView:self];
        _gesturePoint.x -= translation.x;
        _gesturePoint.y -= translation.y;
    }
    [self deliverTouchForPan:gesture];
    // a page that called preventDefault on its touch events moves what is under the finger itself, such as the feed of Shorts
    if ((gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) && yozora_core_touch_claimed(_core)) {
        _panLastX = translation.x;
        _panLast = translation.y;
    } else if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        int wantedX = (int)lroundf(_panLastX - translation.x);
        int wantedY = (int)lroundf(_panLast - translation.y);
        int usedX = 0, usedY = 0;
        [self scrollByX:wantedX y:wantedY usedX:&usedX usedY:&usedY];
        // the rounding remainder carries over, a move cut short at an end is dropped
        _panLastX = usedX == wantedX ? _panLastX - usedX : translation.x;
        _panLast = usedY == wantedY ? _panLast - usedY : translation.y;
        if (usedX || usedY) {
            [self syncScrollOffset];
            [_delegate pageViewDidScroll:self];
        }
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        _panning = NO;
        CGPoint velocity = [gesture velocityInView:self];
        float vy = -velocity.y;
        float vx = -velocity.x;
        // a page that moved with the finger gets no fling on top of its own motion
        if (yozora_core_touch_claimed(_core))
            vy = vx = 0;
        if (fabsf(vy) >= YZFlingStartVelocity || fabsf(vx) >= YZFlingStartVelocity) {
            _flingVelocity = fabsf(vy) >= YZFlingStartVelocity ? vy : 0;
            _flingVelocityX = fabsf(vx) >= YZFlingStartVelocity ? vx : 0;
            _flingRemainder = 0;
            _flingRemainderX = 0;
            _flingTime = 0;
        }
    } else {
        _panning = NO;
    }
}

- (void)advanceFlingAtTime:(CFTimeInterval)time {
    if (!_core || ![self flinging])
        return;
    if (_flingTime == 0) {
        _flingTime = time;
        return;
    }
    float elapsed = (float)(time - _flingTime);
    _flingTime = time;
    if (elapsed <= 0 || elapsed > 0.25f)
        elapsed = 1.0f / 60.0f;
    _flingRemainder += _flingVelocity * elapsed;
    _flingRemainderX += _flingVelocityX * elapsed;
    int stepX = (int)_flingRemainderX;
    int stepY = (int)_flingRemainder;
    if (stepX || stepY) {
        _flingRemainderX -= stepX;
        _flingRemainder -= stepY;
        int usedX = 0, usedY = 0;
        [self scrollByX:stepX y:stepY usedX:&usedX usedY:&usedY];
        // an axis that met its end stops, the other goes on
        if (stepY && usedY == 0) {
            _flingVelocity = 0;
            _flingRemainder = 0;
        }
        if (stepX && usedX == 0) {
            _flingVelocityX = 0;
            _flingRemainderX = 0;
        }
        if (usedX || usedY) {
            [self syncScrollOffset];
            [_delegate pageViewDidScroll:self];
        }
        if (![self flinging])
            return;
    }
    float decay = powf(YZFlingDecayPerMillisecond, elapsed * 1000.0f);
    _flingVelocity *= decay;
    _flingVelocityX *= decay;
    if (fabsf(_flingVelocity) < YZFlingMinimumVelocity)
        _flingVelocity = 0;
    if (fabsf(_flingVelocityX) < YZFlingMinimumVelocity)
        _flingVelocityX = 0;
    if (![self flinging])
        [self stopFling];
}

#pragma mark zoom

// the host is scaled about its centre, the transform puts the viewport point (x, y) of the zoom at the corner of the view
- (void)applyZoom {
    CGSize size = self.bounds.size;
    float scale = _zoom.scale;
    CGAffineTransform transform = CGAffineTransformIdentity;
    if (scale > 1.0f)
        transform = CGAffineTransformMake(scale, 0, 0, scale, -_zoom.x * scale - size.width / 2 * (1 - scale), -_zoom.y * scale - size.height / 2 * (1 - scale));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _zoomHost.transform = transform;
    [CATransaction commit];
}

- (float)rasterFactor {
    static float limit;
    if (limit < 1.0f) {
        // a phone with 512 MB has no room for tiles at twice the pixels, it enlarges the tiles it has. the core takes a scale of 4 at most
        yozora_device device;
        yozora_device_info(&device);
        float screen = (float)[[UIScreen mainScreen] scale];
        limit = MAX(1.0f, MIN(device.memory_mb >= 900 ? 2.0f : 1.0f, 4.0f / screen));
    }
    return yozora_view_zoom_raster_factor(_zoom.scale, limit);
}

- (void)notifyRasterFactor {
    float factor = [self rasterFactor];
    if (factor == _appliedRasterFactor)
        return;
    _appliedRasterFactor = factor;
    [_delegate pageViewDidChangeRasterFactor:self];
}

- (void)resetZoom {
    _pinching = NO;
    yozora_view_zoom_reset(&_zoom);
    _zoomScrollRemainder = 0;
    [self applyZoom];
    [self notifyRasterFactor];
}

- (CGPoint)screenPointForViewportPoint:(CGPoint)point {
    float x, y;
    yozora_view_zoom_to_screen(&_zoom, point.x, point.y, &x, &y);
    return CGPointMake(x, y);
}

- (CGPoint)viewportPointForScreenPoint:(CGPoint)point {
    float x, y;
    yozora_view_zoom_to_viewport(&_zoom, point.x, point.y, &x, &y);
    return CGPointMake(x, y);
}

// the window changed: a keyboard shortens it and a rotation swaps its sides. the view keeps its scale where
// the viewport has room for it
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (CGSizeEqualToSize(size, _zoomBoundsSize))
        return;
    BOOL turned = fabs(size.width - _zoomBoundsSize.width) >= 1;
    _zoomBoundsSize = size;
    _zoomHost.transform = CGAffineTransformIdentity;
    _zoomHost.frame = self.bounds;
    if (turned) {
        yozora_view_zoom_reset(&_zoom);
        _zoomScrollRemainder = 0;
    } else {
        yozora_view_zoom_pan(&_zoom, 0, 0, size.width, size.height, NULL, NULL);
    }
    [self applyZoom];
}

// the fingers spread the picture about the point between them, the layout is not touched so a pinch only
// changes what is shown
- (void)pinch:(UIPinchGestureRecognizer *)gesture {
    if (!_core)
        return;
    CGPoint focal = [gesture locationInView:self];
    switch (gesture.state) {
    case UIGestureRecognizerStateBegan:
        [self stopFling];
        [self hideSelection];
        _pinching = YES;
        _pinchStart = _zoom;
        _pinchStartFocal = focal;
        _pinchScrolled = 0;
        _zoomScrollRemainder = 0;
        // fall through: the first change is part of the same gesture
    case UIGestureRecognizerStateChanged: {
        CGSize size = self.bounds.size;
        float scrollY = 0;
        yozora_view_zoom_pinch(&_pinchStart, _pinchStartFocal.x, _pinchStartFocal.y, (float)gesture.scale, focal.x, focal.y, size.width, size.height, &_zoom, &scrollY);
        [self applyZoom];
        // zooming out of a view that sat low in the viewport asks the page to scroll, the rows under the fingers stay under them
        int target = (int)lroundf(scrollY);
        if (target != _pinchScrolled) {
            _pinchScrolled += yozora_core_scroll(_core, target - _pinchScrolled);
            [self syncScrollOffset];
            [_delegate pageViewDidScroll:self];
        }
        break;
    }
    case UIGestureRecognizerStateEnded:
        _pinching = NO;
        // a picture that is hardly enlarged is the page itself, the tiles are not painted again for a few percent
        if (_zoom.scale < 1.03f)
            yozora_view_zoom_reset(&_zoom);
        [self applyZoom];
        [self notifyRasterFactor];
        break;
    default:
        _pinching = NO;
        yozora_view_zoom_reset(&_zoom);
        [self applyZoom];
        [self notifyRasterFactor];
        break;
    }
}

- (void)tap:(UITapGestureRecognizer *)gesture {
    // a tap takes the selection away, it does not follow a link under it
    if (_selectionActive) {
        [self clearSelection];
        return;
    }
    [_delegate pageView:self tappedAtPoint:[self viewportPointForScreenPoint:[gesture locationInView:self]]];
    _tapTime = CACurrentMediaTime();
    [self updateInput];
}

- (void)updateInput {
    yozora_input_kind kind = _core ? yozora_core_input_kind(_core) : YOZORA_INPUT_NONE;
    BOOL editing = [self isFirstResponder];
    if (kind == YOZORA_INPUT_NONE) {
        _inputKind = kind;
        [self endComposition];
        if (editing)
            [self resignFirstResponder];
        return;
    }
    if (!editing && CACurrentMediaTime() - _tapTime > 1.0)
        return;
    BOOL changed = kind != _inputKind;
    _inputKind = kind;
    if (!editing)
        [self becomeFirstResponder];
    else if (changed)
        [self reloadInputViews];
}

#pragma mark selection

- (void)longPress:(UILongPressGestureRecognizer *)gesture {
    if (!_core)
        return;
    CGPoint point = [self viewportPointForScreenPoint:[gesture locationInView:self]];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self stopFling];
        _selectionAnchor = point;
        _selectionMenuWanted = NO;
        [[UIMenuController sharedMenuController] setMenuVisible:NO animated:NO];
        // a link or an image under the finger opens its own sheet, other text is selected by the core
        yozora_core_long_press(_core, (int)lroundf(point.x), (int)lroundf(point.y));
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        // the finger keeps going: the selection runs from the word it started on to the word under it
        yozora_core_select_range(_core, (int)lroundf(_selectionAnchor.x), (int)lroundf(_selectionAnchor.y), (int)lroundf(point.x), (int)lroundf(point.y));
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        _selectionMenuWanted = YES;
        // a finger held on a checkbox or a button is a slow tap: nothing was selected, so the release clicks it, as Safari does
        yozora_core_long_press_release(_core, (int)lroundf(_selectionAnchor.x), (int)lroundf(_selectionAnchor.y));
    }
}

- (YZSelectionHandle *)makeHandleIsEnd:(BOOL)isEnd {
    YZSelectionHandle *handle = [[[YZSelectionHandle alloc] initWithFrame:CGRectMake(0, 0, 44, 60)] autorelease];
    handle.isEnd = isEnd;
    handle.backgroundColor = [UIColor clearColor];
    handle.opaque = NO;
    // the tiles are layers added later, the handles stay above them
    handle.layer.zPosition = 100;
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragHandle:)];
    [handle addGestureRecognizer:drag];
    [drag release];
    [self addSubview:handle];
    return handle;
}

- (void)dragHandle:(UIPanGestureRecognizer *)gesture {
    if (!_core || !_selectionActive)
        return;
    YZSelectionHandle *handle = (YZSelectionHandle *)gesture.view;
    yozora_selection selection;
    if (!yozora_core_selection(_core, &selection))
        return;
    if (gesture.state == UIGestureRecognizerStateBegan)
        [[UIMenuController sharedMenuController] setMenuVisible:NO animated:NO];
    CGFloat scroll = (CGFloat)yozora_core_scroll_y(_core);
    CGPoint finger = [gesture locationInView:self];
    // the dragged end aims a knob's height above or below the finger on the screen, then everything goes to the viewport
    CGFloat aimOffset = 22;
    CGPoint fingerPage = [self viewportPointForScreenPoint:finger];
    CGPoint aimPage = [self viewportPointForScreenPoint:CGPointMake(finger.x, finger.y + (handle.isEnd ? -aimOffset : aimOffset))];
    // the end that stays: the middle of the line at the other end, and the dragged end aims at the line above or below the knob
    CGPoint fixed = handle.isEnd ? CGPointMake(selection.start_x + 1, selection.start_y + selection.start_height / 2.0f - scroll)
                                 : CGPointMake(selection.end_x - 1, selection.end_y + selection.end_height / 2.0f - scroll);
    yozora_core_select_range(_core, (int)lroundf(fixed.x), (int)lroundf(fixed.y), (int)lroundf(fingerPage.x), (int)lroundf(aimPage.y));
    if (gesture.state == UIGestureRecognizerStateEnded)
        _selectionMenuWanted = YES;
}

- (void)hideSelection {
    _selectionActive = NO;
    _selectionMenuWanted = NO;
    _startHandle.hidden = YES;
    _endHandle.hidden = YES;
    [[UIMenuController sharedMenuController] setMenuVisible:NO animated:NO];
}

- (void)clearSelection {
    [self hideSelection];
    if (_core)
        yozora_core_select_clear(_core);
}

- (void)copySelection {
    if (_selectionText[0])
        [UIPasteboard generalPasteboard].string = [NSString stringWithUTF8String:_selectionText];
    [self clearSelection];
}

// the page of the share sheet is the controller's, the text and the place of the selection are all it needs
- (void)shareSelection {
    if (!_selectionText[0])
        return;
    NSString *text = [NSString stringWithUTF8String:_selectionText];
    CGRect place = CGRectMake(_selectionTarget.origin.x, _selectionTarget.origin.y, MAX((CGFloat)1, _selectionTarget.size.width), MAX((CGFloat)1, _selectionTarget.size.height));
    [self clearSelection];
    if (text)
        [_delegate pageView:self shareText:text fromRect:place];
}

- (void)selectEverything {
    if (_core)
        yozora_core_select_all(_core);
    _selectionMenuWanted = YES;
}

- (void)updateSelection {
    yozora_selection selection;
    if (_selectionHidden) {
        if (_selectionActive)
            [self hideSelection];
        return;
    }
    if (!_core || !yozora_core_selection(_core, &selection)) {
        if (_selectionActive)
            [self hideSelection];
        return;
    }
    if (!_startHandle) {
        _startHandle = [[self makeHandleIsEnd:NO] retain];
        _endHandle = [[self makeHandleIsEnd:YES] retain];
        _menuTarget = [[YZSelectionMenuTarget alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        ((YZSelectionMenuTarget *)_menuTarget).page = self;
        _menuTarget.hidden = YES;
        [self addSubview:_menuTarget];
    }
    _selectionActive = YES;
    snprintf(_selectionText, sizeof(_selectionText), "%s", selection.text);
    CGFloat scroll = (CGFloat)yozora_core_scroll_y(_core);
    CGFloat startTop = selection.start_y - scroll;
    CGFloat endTop = selection.end_y - scroll;
    CGPoint startPoint = [self screenPointForViewportPoint:CGPointMake(selection.start_x, startTop)];
    CGPoint endPoint = [self screenPointForViewportPoint:CGPointMake(selection.end_x, endTop)];
    CGFloat startHeight = selection.start_height * _zoom.scale;
    CGFloat endHeight = selection.end_height * _zoom.scale;
    ((YZSelectionHandle *)_startHandle).caretHeight = startHeight;
    ((YZSelectionHandle *)_endHandle).caretHeight = endHeight;
    _startHandle.frame = CGRectMake(startPoint.x - 22, startPoint.y - 14, 44, startHeight + 14);
    _endHandle.frame = CGRectMake(endPoint.x - 22, endPoint.y, 44, endHeight + 14);
    [_startHandle setNeedsDisplay];
    [_endHandle setNeedsDisplay];
    _startHandle.hidden = NO;
    _endHandle.hidden = NO;
    if (_selectionMenuWanted && !_panning && ![self flinging]) {
        _selectionMenuWanted = NO;
        // the menu belongs to a view that is no keyboard responder; it sits above the first line of the selection
        [_menuTarget becomeFirstResponder];
        CGFloat top = MIN(startPoint.y, endPoint.y);
        CGRect target = CGRectMake(MIN(startPoint.x, endPoint.x), top, MAX(40, ABS(endPoint.x - startPoint.x)), 20);
        UIMenuController *menu = [UIMenuController sharedMenuController];
        _selectionTarget = target;
        // a system before ios 6 has no share sheet to hand the text to
        if (!_shareItem && NSClassFromString(@"UIActivityViewController"))
            _shareItem = [[UIMenuItem alloc] initWithTitle:YZT(@"Поделиться") action:@selector(shareSelection:)];
        menu.menuItems = _shareItem ? [NSArray arrayWithObject:_shareItem] : nil;
        [menu setTargetRect:target inView:self];
        [menu setMenuVisible:YES animated:YES];
    }
}

#pragma mark keyboard

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (BOOL)hasText {
    // backspace is only sent for a responder that claims to have text
    return YES;
}

// what the page takes of the composition ends here: the composed text is final, or the field forgets it
- (void)endComposition {
    [_marked release];
    _marked = nil;
    _markedCaretStart = 0;
    _markedCaretEnd = 0;
}

- (void)insertText:(NSString *)text {
    if (!_core || ![text length])
        return;
    // the final text of a composition replaces what was composed
    if ([_marked length]) {
        [self endComposition];
        yozora_core_confirm_composition(_core, [text UTF8String]);
        return;
    }
    yozora_core_insert_text(_core, [text UTF8String]);
}

- (void)deleteBackward {
    if (!_core)
        return;
    if ([_marked length]) {
        // the keyboard shortens its composition itself with setMarkedText; if it asks for a backspace the last composed character goes
        NSString *shorter = [_marked substringToIndex:[_marked length] - 1];
        [self setMarkedText:shorter selectedRange:NSMakeRange([shorter length], 0)];
        return;
    }
    yozora_core_delete_backward(_core);
}

#pragma mark input methods

// Japanese, Chinese and Korean keyboards compose text before it is final and need a text input to do it: with a plain key input
// the kana keys of the Japanese keyboard had nowhere to put the text and nothing could be typed
- (void)setMarkedText:(NSString *)text selectedRange:(NSRange)selected {
    if (!text)
        text = @"";
    NSString *composed = [text copy];
    [_marked release];
    _marked = composed;
    NSInteger length = (NSInteger)[composed length];
    _markedCaretStart = MIN((NSInteger)selected.location, length);
    _markedCaretEnd = MIN((NSInteger)(selected.location + selected.length), length);
    if (!length) {
        [self endComposition];
        if (_core)
            yozora_core_set_composition(_core, "", 0, 0);
        return;
    }
    if (_core)
        yozora_core_set_composition(_core, [composed UTF8String], (int)_markedCaretStart, (int)_markedCaretEnd);
}

- (void)unmarkText {
    if (![_marked length])
        return;
    [self endComposition];
    if (_core)
        yozora_core_confirm_composition(_core, NULL);
}

- (UITextRange *)markedTextRange {
    return [_marked length] ? [YZTextRange rangeFrom:0 to:(NSInteger)[_marked length]] : nil;
}

- (NSDictionary *)markedTextStyle { return nil; }
- (void)setMarkedTextStyle:(NSDictionary *)style { (void)style; }

- (UITextRange *)selectedTextRange {
    return [YZTextRange rangeFrom:_markedCaretStart to:_markedCaretEnd];
}
- (void)setSelectedTextRange:(UITextRange *)range {
    // the caret of the page is the page's: only a move inside a composition is kept
    if ([_marked length] && range) {
        _markedCaretStart = MIN(YZOffsetOf(range.start), (NSInteger)[_marked length]);
        _markedCaretEnd = MIN(YZOffsetOf(range.end), (NSInteger)[_marked length]);
    }
}

- (NSString *)textInRange:(UITextRange *)range {
    NSString *text = _marked ? _marked : @"";
    NSInteger start = MIN(YZOffsetOf(range.start), (NSInteger)[text length]);
    NSInteger end = MIN(YZOffsetOf(range.end), (NSInteger)[text length]);
    return end > start ? [text substringWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start))] : @"";
}

- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    (void)range;
    [self insertText:text];
}

- (UITextPosition *)beginningOfDocument { return [YZTextPosition positionAt:0]; }
- (UITextPosition *)endOfDocument { return [YZTextPosition positionAt:(NSInteger)[_marked length]]; }

- (UITextRange *)textRangeFromPosition:(UITextPosition *)from toPosition:(UITextPosition *)to {
    return [YZTextRange rangeFrom:YZOffsetOf(from) to:YZOffsetOf(to)];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position offset:(NSInteger)offset {
    NSInteger moved = YZOffsetOf(position) + offset;
    if (moved < 0 || moved > (NSInteger)[_marked length])
        return nil;
    return [YZTextPosition positionAt:moved];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction offset:(NSInteger)offset {
    BOOL back = direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp;
    return [self positionFromPosition:position offset:back ? -offset : offset];
}

- (NSComparisonResult)comparePosition:(UITextPosition *)position toPosition:(UITextPosition *)other {
    NSInteger a = YZOffsetOf(position), b = YZOffsetOf(other);
    return a < b ? NSOrderedAscending : (a > b ? NSOrderedDescending : NSOrderedSame);
}

- (NSInteger)offsetFromPosition:(UITextPosition *)from toPosition:(UITextPosition *)to {
    return YZOffsetOf(to) - YZOffsetOf(from);
}

- (id<UITextInputDelegate>)inputDelegate { return _inputDelegate; }
- (void)setInputDelegate:(id<UITextInputDelegate>)delegate { _inputDelegate = delegate; }

- (id<UITextInputTokenizer>)tokenizer {
    if (!_tokenizer)
        _tokenizer = [[UITextInputStringTokenizer alloc] initWithTextInput:self];
    return _tokenizer;
}

- (UITextPosition *)positionWithinRange:(UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction {
    BOOL back = direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp;
    return back ? range.start : range.end;
}

- (UITextRange *)characterRangeByExtendingPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction {
    NSInteger at = YZOffsetOf(position);
    BOOL back = direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp;
    return back ? [YZTextRange rangeFrom:0 to:at] : [YZTextRange rangeFrom:at to:(NSInteger)[_marked length]];
}

- (UITextWritingDirection)baseWritingDirectionForPosition:(UITextPosition *)position inDirection:(UITextStorageDirection)direction {
    (void)position; (void)direction;
    return UITextWritingDirectionNatural;
}
- (void)setBaseWritingDirection:(UITextWritingDirection)direction forRange:(UITextRange *)range { (void)direction; (void)range; }

// the keyboard puts its candidate list at the caret: the page does not tell where its caret is, so the middle of the view stands for it
- (CGRect)firstRectForRange:(UITextRange *)range {
    (void)range;
    return CGRectMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds), 2, 20);
}
- (CGRect)caretRectForPosition:(UITextPosition *)position {
    (void)position;
    return CGRectMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds), 2, 20);
}
- (NSArray *)selectionRectsForRange:(UITextRange *)range { (void)range; return [NSArray array]; }
- (UITextPosition *)closestPositionToPoint:(CGPoint)point { (void)point; return [self endOfDocument]; }
- (UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange *)range { (void)point; return range.end; }
- (UITextRange *)characterRangeAtPoint:(CGPoint)point { (void)point; return [YZTextRange rangeFrom:0 to:(NSInteger)[_marked length]]; }

// no spell check of the system either: it would compose English words behind the page's back
- (UITextSpellCheckingType)spellCheckingType { return UITextSpellCheckingTypeNo; }

- (UIKeyboardType)keyboardType {
    switch (_inputKind) {
    case YOZORA_INPUT_URL: return UIKeyboardTypeURL;
    case YOZORA_INPUT_EMAIL: return UIKeyboardTypeEmailAddress;
    case YOZORA_INPUT_NUMBER: return UIKeyboardTypeNumbersAndPunctuation;
    default: return UIKeyboardTypeDefault;
    }
}

- (UIReturnKeyType)returnKeyType {
    switch (_inputKind) {
    case YOZORA_INPUT_MULTILINE: return UIReturnKeyDefault;
    case YOZORA_INPUT_SEARCH: return UIReturnKeySearch;
    default: return UIReturnKeyGo;
    }
}

- (BOOL)isSecureTextEntry {
    return _inputKind == YOZORA_INPUT_PASSWORD;
}

- (UITextAutocorrectionType)autocorrectionType {
    // there is no text context to correct against, the keyboard would only guess from single letters
    return UITextAutocorrectionTypeNo;
}

- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}

@end
