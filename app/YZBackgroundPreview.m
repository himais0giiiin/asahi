#import "YZBackgroundPreview.h"
#import "YZClassic.h"
#import "YZCompat.h"
#import "YZHomeView.h"
#import "YZStrings.h"
#import "YZTheme.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat YZBackKeyWidth = 44;

// the height of the bars of the browser (`barHeight` in YZBrowserController) for this size of screen
static CGFloat YZPreviewBarHeight(CGSize size) {
    BOOL landscape = size.width > size.height;
    if ([YZTheme isFlat])
        return (landscape && ![YZTheme isPad]) ? 36 : 44;
    if (size.width >= 700)
        return 52;
    return (landscape && ![YZTheme isPad]) ? 40 : 56;
}

static CGFloat YZPreviewFieldHeight(CGFloat bar) {
    return [YZTheme isFlat] ? MIN(bar - 14, (CGFloat)30) : bar - 16;
}

@implementation YZBackgroundPreview
@synthesize tapped = _tapped;
@synthesize insets = _insets;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.clipsToBounds = YES;
    _insets = UIEdgeInsetsMake(20, 0, 0, 0);
    _home = [[YZHomeView alloc] initWithFrame:CGRectZero];
    [self addSubview:_home];
    [_home showModelWithPicture:nil dissolve:NO];
    _topBar = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_topBar];
    _strip = [[UIView alloc] initWithFrame:CGRectZero];
    [_topBar addSubview:_strip];
    _field = [[UIView alloc] initWithFrame:CGRectZero];
    [_topBar addSubview:_field];
    _lock = [[UIImageView alloc] initWithFrame:CGRectZero];
    _lock.contentMode = UIViewContentModeCenter;
    [_field addSubview:_lock];
    _address = [[UILabel alloc] initWithFrame:CGRectZero];
    _address.backgroundColor = [UIColor clearColor];
    _address.textAlignment = YZTextAlignmentCenter;
    [_field addSubview:_address];
    _topLine = [[UIView alloc] initWithFrame:CGRectZero];
    [_topBar addSubview:_topLine];
    _bottomBar = [[UIView alloc] initWithFrame:CGRectZero];
    [self addSubview:_bottomBar];
    _bottomLine = [[UIView alloc] initWithFrame:CGRectZero];
    [_bottomBar addSubview:_bottomLine];
    _toolIcons = [[NSMutableArray alloc] init];
    for (int i = 0; i < 5; ++i) {
        UIImageView *icon = [[[UIImageView alloc] initWithFrame:CGRectZero] autorelease];
        icon.contentMode = UIViewContentModeCenter;
        [_bottomBar addSubview:icon];
        [_toolIcons addObject:icon];
    }
    // without a photo a pill over the page says where one comes from
    _hint = [[UIView alloc] initWithFrame:CGRectZero];
    _hint.layer.cornerRadius = 22;
    [self addSubview:_hint];
    _hintIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _hintIcon.contentMode = UIViewContentModeCenter;
    [_hint addSubview:_hintIcon];
    _hintText = [[UILabel alloc] initWithFrame:CGRectZero];
    _hintText.backgroundColor = [UIColor clearColor];
    [_hint addSubview:_hintText];
    UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(touched)] autorelease];
    [self addGestureRecognizer:tap];
    return self;
}

- (void)dealloc {
    [_home release];
    [_topBar release];
    [_strip release];
    [_topLine release];
    [_field release];
    [_lock release];
    [_address release];
    [_bottomBar release];
    [_bottomLine release];
    [_toolIcons release];
    [_hint release];
    [_hintIcon release];
    [_hintText release];
    [_tapped release];
    [super dealloc];
}

- (void)setInsets:(UIEdgeInsets)insets {
    if (UIEdgeInsetsEqualToEdgeInsets(insets, _insets))
        return;
    _insets = insets;
    [self setNeedsLayout];
}

- (void)touched {
    if (_hasPicture || !_tapped)
        return;
    _tapped();
}

- (void)showSites:(NSArray *)sites bookmarks:(NSArray *)bookmarks {
    [_home showSites:sites bookmarks:bookmarks];
}

// the keys of the bottom bar in the order of the browser: the flat design has the share key where the others have the star
- (void)restyle {
    BOOL flat = [YZTheme isFlat], classic = [YZTheme isClassic];
    _topBar.backgroundColor = [YZTheme toolbarColor];
    _bottomBar.backgroundColor = [YZTheme toolbarColor];
    _strip.backgroundColor = [YZTheme statusStripColor];
    _topLine.hidden = !flat;
    _bottomLine.hidden = !flat;
    _topLine.backgroundColor = [YZTheme separatorColor];
    _bottomLine.backgroundColor = [YZTheme separatorColor];
    _field.backgroundColor = [YZTheme fieldColor];
    _lock.image = [YZTheme chromeIcon:YZIconSearch size:flat ? 16 : 20 color:[YZTheme fieldHintColor]];
    _address.font = [YZTheme systemFontOfSize:15];
    _address.textColor = [YZTheme fieldHintColor];
    // the address field of the browser shows the host of the page, the start page has none: the field is as it is on a blank tab
    _address.text = YZT(@"Поиск или адрес");
    int keys[5] = { YZIconBack, YZIconForward, YZIconShare, YZIconTabs, YZIconMenu };
    for (int i = 0; i < 5; ++i) {
        UIImage *glyph = keys[i] == YZIconTabs ? [YZTheme barTabsIconWithCount:1 size:24] : [YZTheme barIcon:(YZIcon)keys[i] size:24 disabled:NO];
        [[_toolIcons objectAtIndex:(NSUInteger)i] setImage:glyph];
    }
    (void)classic;
    _hint.backgroundColor = [YZTheme accentColor];
    _hintIcon.image = [YZTheme icon:YZIconImage size:20 color:[YZTheme surfaceColor]];
    _hintText.font = [YZTheme boldSystemFontOfSize:15];
    _hintText.textColor = [YZTheme surfaceColor];
    _hintText.text = YZT(@"Выбрать фото");
    self.backgroundColor = classic ? [YZTheme linenColor] : [YZTheme surfaceColor];
    [_home applyTheme];
    [self setNeedsLayout];
}

- (void)showPicture:(UIImage *)picture dissolve:(BOOL)dissolve {
    _hasPicture = picture != nil;
    [_home showModelWithPicture:picture dissolve:dissolve];
    _hint.hidden = _hasPicture;
}

- (CGFloat)pageTop { return _insets.top + YZPreviewBarHeight(self.bounds.size); }
- (CGFloat)pageBottom { return self.bounds.size.height - YZPreviewBarHeight(self.bounds.size) - _insets.bottom; }

- (CGRect)backKeyFrame {
    CGFloat bar = YZPreviewBarHeight(self.bounds.size);
    return CGRectMake(_insets.left + 2, _insets.top, YZBackKeyWidth, bar);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w < 1 || h < 1)
        return;
    CGFloat bar = YZPreviewBarHeight(self.bounds.size), line = 1.0f / [[UIScreen mainScreen] scale];
    CGFloat top = _insets.top + bar, bottomBarTop = h - bar - _insets.bottom;
    _home.frame = CGRectMake(0, top, w, MAX((CGFloat)0, bottomBarTop - top));
    _topBar.frame = CGRectMake(0, 0, w, top);
    _strip.frame = CGRectMake(0, 0, w, _insets.top);
    _topLine.frame = CGRectMake(0, top - line, w, line);
    CGFloat fieldHeight = YZPreviewFieldHeight(bar);
    CGFloat left = _insets.left + 2 + YZBackKeyWidth;
    _field.frame = CGRectMake(left, _insets.top + floor((bar - fieldHeight) / 2), MAX((CGFloat)0, w - left - _insets.right - 12), fieldHeight);
    _field.layer.cornerRadius = [YZTheme isClassic] ? 0 : ([YZTheme isFlat] ? 8 : fieldHeight / 2);
    _lock.frame = CGRectMake(8, 0, 20, fieldHeight);
    _address.frame = CGRectMake(32, 0, MAX((CGFloat)0, _field.bounds.size.width - 64), fieldHeight);
    _bottomBar.frame = CGRectMake(0, bottomBarTop, w, h - bottomBarTop);
    _bottomLine.frame = CGRectMake(0, 0, w, line);
    CGFloat inner = w - _insets.left - _insets.right;
    for (NSUInteger i = 0; i < [_toolIcons count]; ++i)
        [[_toolIcons objectAtIndex:i] setFrame:CGRectMake(_insets.left + inner / 5 * i, 0, inner / 5, bar)];
    CGFloat hintWidth = MIN(w - 48, (CGFloat)230);
    _hint.frame = CGRectMake(floor((w - hintWidth) / 2), top + floor((bottomBarTop - top - 44) / 2), hintWidth, 44);
    _hintIcon.frame = CGRectMake(14, 0, 28, 44);
    _hintText.frame = CGRectMake(46, 0, hintWidth - 58, 44);
}

@end
