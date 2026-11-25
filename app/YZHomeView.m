#import "YZHomeView.h"
#import "YZClassic.h"
#import "YZCompat.h"
#import "YZBackground.h"
#import "YZFavicons.h"
#import "YZMotion.h"
#import "YZStrings.h"
#import <QuartzCore/QuartzCore.h>
#import "YZStore.h"
#import "YZTheme.h"
#include "yozora_address.h"

static const NSUInteger YZTilesPerSection = 8;
static const CGFloat YZTileSize = 60;
static const CGFloat YZTileLabelHeight = 32;
// the caption takes the cell minus a gap, so a title wraps at words and not inside one
static const CGFloat YZTileCell = 84;
static const CGFloat YZTileSide = 16;

@interface YZTileButton : UIButton {
@public
    // the square under the letter or the icon: the classic design lights it, the label under it stays on the page
    UIView *square;
    UILabel *letter;
    UIImageView *icon;
    UILabel *caption;
@private
    NSString *_target;
}
@property(nonatomic, copy) NSString *target;
@end
@implementation YZTileButton
@synthesize target = _target;
- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    square = [[UIView alloc] initWithFrame:CGRectMake(0, 0, YZTileSize, YZTileSize)];
    square.userInteractionEnabled = NO;
    [self addSubview:square];
    letter = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, YZTileSize, YZTileSize)];
    letter.textAlignment = YZTextAlignmentCenter;
    letter.font = [YZTheme boldSystemFontOfSize:28];
    letter.textColor = [UIColor whiteColor];
    letter.layer.cornerRadius = [YZTheme tileRadius];
    // a label fills its whole rectangle with its background, so the white icon tile showed square corners
    // outside the rounded edge
    letter.layer.masksToBounds = YES;
    letter.userInteractionEnabled = NO;
    [self addSubview:letter];
    // the icon of the site stands on a white tile, the way the shortcuts of Firefox do
    icon = [[UIImageView alloc] initWithFrame:CGRectMake(10, 10, YZTileSize - 20, YZTileSize - 20)];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    // a picture of 128 pixels is shown at 40 points with the best filter the system has
    icon.layer.minificationFilter = kCAFilterTrilinear;
    icon.userInteractionEnabled = NO;
    [self addSubview:icon];
    caption = [[UILabel alloc] initWithFrame:CGRectMake((YZTileSize - (YZTileCell - 6)) / 2, YZTileSize + 4, YZTileCell - 6, YZTileLabelHeight - 4)];
    caption.numberOfLines = 2;
    caption.lineBreakMode = YZLineBreakTailTruncation;
    caption.textAlignment = YZTextAlignmentCenter;
    caption.font = [YZTheme systemFontOfSize:11];
    caption.backgroundColor = [UIColor clearColor];
    caption.userInteractionEnabled = NO;
    [self addSubview:caption];
    return self;
}
- (void)setHighlighted:(BOOL)highlighted {
    BOOL pressed = highlighted && !self.highlighted;
    [super setHighlighted:highlighted];
    if (pressed)
        [YZTheme animateFeedbackOfView:self];
}
- (void)dealloc {
    [square release];
    [letter release];
    [icon release];
    [caption release];
    [_target release];
    [super dealloc];
}
@end

@implementation YZHomeView
@synthesize homeDelegate = _homeDelegate;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.backgroundColor = [YZTheme isClassic] ? [YZTheme linenColor] : [YZTheme surfaceColor];
    _contentDirty = YES;
    self.alwaysBounceVertical = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(iconLoaded:) name:YZFaviconDidLoadNotification object:nil];
    _siteTiles = [[NSMutableArray alloc] init];
    _bookmarkTiles = [[NSMutableArray alloc] init];
    _sitesHeading = [[UILabel alloc] initWithFrame:CGRectZero];
    _bookmarksHeading = [[UILabel alloc] initWithFrame:CGRectZero];
    for (UILabel *heading in [NSArray arrayWithObjects:_sitesHeading, _bookmarksHeading, nil]) {
        heading.font = [YZTheme boldSystemFontOfSize:15];
        heading.backgroundColor = [UIColor clearColor];
        [self addSubview:heading];
    }
    return self;
}

// the tiles are filled again, the one that waited for its icon takes it
- (void)iconLoaded:(NSNotification *)note {
    (void)note;
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
}

// the lettering follows the photo: gray on a light one is hard to read. the photo is judged as shown (blurred), light above this lightness
static const CGFloat YZLightPhoto = 0.55f;

- (UIColor *)headingInk {
    if (_photoInk == 1)
        return [UIColor colorWithWhite:0.08f alpha:1];
    return _photoInk == 2 ? [UIColor colorWithWhite:0.98f alpha:1] : [YZTheme textColor];
}

- (UIColor *)captionInk {
    if (_photoInk == 1)
        return [UIColor colorWithWhite:0.2f alpha:1];
    return _photoInk == 2 ? [UIColor colorWithWhite:0.9f alpha:1] : [YZTheme subtleTextColor];
}

// the tiles and headings take their colors again when the kind of photo changes
- (void)adaptInkToPicture:(UIImage *)picture {
    int ink = picture ? ([YZBackground lightnessOfImage:picture] > YZLightPhoto ? 1 : 2) : 0;
    if (ink == _photoInk)
        return;
    _photoInk = ink;
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
}

// the private session keeps the plain surface: its note is set for it
- (void)applyBackdrop {
    if (_previewing)
        return;
    UIImage *picture = [YZTheme isIncognito] ? nil : [YZBackground image];
    if (!picture) {
        _backdrop.hidden = YES;
        _backdrop.image = nil;
        [self adaptInkToPicture:nil];
        return;
    }
    if (!_backdrop) {
        _backdrop = [[UIImageView alloc] initWithFrame:self.bounds];
        _backdrop.contentMode = UIViewContentModeScaleAspectFill;
        _backdrop.clipsToBounds = YES;
        _backdrop.userInteractionEnabled = NO;
        [self insertSubview:_backdrop atIndex:0];
    }
    _backdrop.hidden = NO;
    UIImage *shown = [YZBackground imageBlurredBy:[YZSettings homeBackgroundBlur]];
    _backdrop.image = shown;
    [self adaptInkToPicture:shown];
    _backdrop.alpha = 1;
    _backdrop.frame = self.bounds;
}

- (void)showModelWithPicture:(UIImage *)picture dissolve:(BOOL)dissolve {
    BOOL changed = !_previewing;
    _previewing = YES;
    self.userInteractionEnabled = NO;
    self.showsVerticalScrollIndicator = NO;
    if (changed) {
        // the private note and the tiles are told apart by the session, a model shows the tiles
        _contentDirty = YES;
        _builtWidth = 0;
        [self setNeedsLayout];
    }
    if (!picture) {
        _backdrop.hidden = YES;
        _backdrop.image = nil;
        [self adaptInkToPicture:nil];
        return;
    }
    if (!_backdrop) {
        _backdrop = [[UIImageView alloc] initWithFrame:self.bounds];
        _backdrop.contentMode = UIViewContentModeScaleAspectFill;
        _backdrop.clipsToBounds = YES;
        _backdrop.userInteractionEnabled = NO;
        [self insertSubview:_backdrop atIndex:0];
    }
    _backdrop.hidden = NO;
    [self adaptInkToPicture:picture];
    if (_backdrop.image != picture) {
        if (dissolve && self.window) {
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = 0.35;
            [_backdrop.layer addAnimation:fade forKey:@"yz.photo"];
        }
        _backdrop.image = picture;
    }
    _backdrop.alpha = 1;
    _backdrop.frame = self.bounds;
}

- (void)applyTheme {
    self.backgroundColor = [YZTheme isClassic] ? [YZTheme linenColor] : [YZTheme surfaceColor];
    [self applyBackdrop];
    // the mascot is a setting like the theme, and the picture is only made when the brand is first laid out
    _brandImage.image = [YZTheme mascotImage:@"hero"];
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
}

- (void)showSites:(NSArray *)sites bookmarks:(NSArray *)bookmarks {
    [sites retain];
    [_sites release];
    _sites = sites;
    [bookmarks retain];
    [_bookmarks release];
    _bookmarks = bookmarks;
    _contentDirty = YES;
    _builtWidth = 0;
    [self setNeedsLayout];
}

- (void)animateContents {
    [self layoutIfNeeded];
    NSUInteger animated = 0;
    for (UIView *tile in self.subviews) {
        if (![tile isKindOfClass:[YZTileButton class]] || tile.hidden || !CGRectIntersectsRect(tile.frame, self.bounds))
            continue;
        // the tiles settle on the wobble curve, passing their place a little
        YZMotionAnimateEnter(tile, CGAffineTransformConcat(CGAffineTransformMakeScale(0.8f, 0.8f), CGAffineTransformMakeTranslation(0, 14)), 0,
                             YOZORA_MOTION_WOBBLE, MIN((NSTimeInterval)0.16, animated * 0.025));
        if (++animated == 8)
            break;
    }
    if (!_brandImage.hidden && _brandImage) {
        YZMotionAnimateEnter(_brandImage, CGAffineTransformMakeScale(0.6f, 0.6f), 0, YOZORA_MOTION_WOBBLE, 0);
        YZMotionAnimateEnter(_brandGlow, CGAffineTransformMakeScale(0.6f, 0.6f), 0, YOZORA_MOTION_WOBBLE, 0);
        [YZTheme animateEntranceOfView:_brandName offset:CGPointMake(0, 10) delay:0.05];
    }
    if (!_heroDisc.hidden) {
        YZMotionAnimateEnter(_heroDisc, CGAffineTransformMakeScale(0.5f, 0.5f), 0, YOZORA_MOTION_WOBBLE, 0);
        YZMotionAnimateEnter(_heroIcon, CGAffineTransformMakeScale(0.4f, 0.4f), 0, YOZORA_MOTION_WOBBLE, 0.06);
        [YZTheme animateEntranceOfView:_heroTitle offset:CGPointMake(0, 16) delay:0.04];
        [YZTheme animateEntranceOfView:_heroText offset:CGPointMake(0, 16) delay:0.08];
    }
}

- (void)tilePressed:(YZTileButton *)button {
    if (button.target)
        [_homeDelegate homeView:self didSelectURL:button.target];
}

- (void)updateTile:(YZTileButton *)tile record:(YZRecord *)record {
    char host[256];
    NSString *name = record.url;
    if (yozora_address_host([record.url UTF8String], host, sizeof host))
        name = [NSString stringWithUTF8String:host];
    tile.target = record.url;
    UIImage *icon = [YZFavicons iconForURL:record.url];
    tile->icon.image = icon;
    tile->icon.hidden = !icon;
    tile->letter.text = icon ? nil : [[name substringToIndex:MIN((NSUInteger)1, [name length])] uppercaseString];
    UIColor *tileColor = icon ? [YZFavicons tileColorForIcon:icon] : [YZTheme tileColorForHost:name];
    BOOL classic = [YZTheme isClassic];
    tile->letter.layer.cornerRadius = [YZTheme tileRadius];
    if (classic) {
        // the tile is lit like an icon of the old home screen: a toolbar of the system tinted with the color lies under the letter or the icon
        tile->letter.backgroundColor = [UIColor clearColor];
        tile->letter.layer.borderWidth = 0;
        [YZClassic lightView:tile->square color:tileColor radius:[YZTheme tileRadius]];
        tile->square.layer.borderWidth = 1;
        tile->square.layer.borderColor = [[UIColor colorWithWhite:0 alpha:0.4f] CGColor];
        tile->square.layer.cornerRadius = [YZTheme tileRadius];
    } else {
        [YZClassic unlightView:tile->square];
        tile->square.layer.borderWidth = 0;
        tile->letter.backgroundColor = tileColor;
        tile->letter.layer.borderWidth = icon ? 1 : 0;
        tile->letter.layer.borderColor = [[YZTheme separatorColor] CGColor];
    }
    tile->caption.text = [record.title length] ? record.title : name;
    tile->caption.textColor = [self captionInk];
}

- (CGFloat)layoutSection:(NSString *)heading records:(NSArray *)records tiles:(NSMutableArray *)tiles
                  title:(UILabel *)title top:(CGFloat)top {
    NSUInteger shown = MIN([records count], YZTilesPerSection);
    while ([tiles count] > shown) {
        [[tiles lastObject] removeFromSuperview];
        [tiles removeLastObject];
    }
    title.hidden = !shown;
    if (!shown)
        return top;
    CGFloat width = self.bounds.size.width;
    // rows stand as one block in the middle, as the shortcuts of Firefox do, the heading starts at the
    // block's left edge
    NSUInteger perRow = MAX((NSUInteger)3, (NSUInteger)((width - 2 * YZTileSide) / YZTileCell));
    NSUInteger columns = MIN(perRow, shown);
    CGFloat block = columns * YZTileCell;
    CGFloat left = floor((width - block) / 2);
    // the heading runs to the side margin, not to the end of the tile block: a section of one tile is one
    // tile wide and cut "Избранное" to "Избра..."
    CGFloat headingLeft = left + (YZTileCell - YZTileSize) / 2;
    title.frame = CGRectMake(headingLeft, top, MAX((CGFloat)0, width - YZTileSide - headingLeft), 22);
    if (_contentDirty) {
        title.text = heading;
        title.textColor = [self headingInk];
    }
    top += 32;
    for (NSUInteger i = 0; i < shown; ++i) {
        YZTileButton *tile;
        if (i < [tiles count]) {
            tile = [tiles objectAtIndex:i];
        } else {
            tile = [[[YZTileButton alloc] initWithFrame:CGRectZero] autorelease];
            [tile addTarget:self action:@selector(tilePressed:) forControlEvents:UIControlEventTouchUpInside];
            [tiles addObject:tile];
            [self addSubview:tile];
        }
        tile.hidden = NO;
        if (_contentDirty)
            [self updateTile:tile record:[records objectAtIndex:i]];
        tile.frame = CGRectMake(left + (i % columns) * YZTileCell + (YZTileCell - YZTileSize) / 2,
                                top + (i / columns) * (YZTileSize + YZTileLabelHeight + 8),
                                YZTileSize, YZTileSize + YZTileLabelHeight);
    }
    NSUInteger rows = (shown + columns - 1) / columns;
    return top + rows * (YZTileSize + YZTileLabelHeight + 8) + 12;
}

// the app picture and name stand at the top middle, as the logo of Firefox does. returns where the tiles
// begin
- (CGFloat)layoutBrandFromTop:(CGFloat)top {
    if (!_brandImage) {
        _brandImage = [[UIImageView alloc] initWithImage:[YZTheme mascotImage:@"hero"]];
        _brandImage.contentMode = UIViewContentModeScaleAspectFit;
        _brandGlow = [[UIImageView alloc] initWithFrame:CGRectZero];
        _brandGlow.userInteractionEnabled = NO;
        [self addSubview:_brandGlow];
        [self addSubview:_brandImage];
        // the name is a label of the system, no drawn wordmark
        _brandName = [[UILabel alloc] initWithFrame:CGRectZero];
        _brandName.text = @"Yozora";
        _brandName.font = [UIFont boldSystemFontOfSize:30];
        _brandName.textAlignment = YZTextAlignmentCenter;
        _brandName.backgroundColor = [UIColor clearColor];
        [self addSubview:_brandName];
    }
    _brandImage.hidden = NO;
    _brandGlow.hidden = ![YZSettings mascotGlow];
    _brandName.hidden = NO;
    _brandName.textColor = [self headingInk];
    // a soft glow of the accent around the mascot: a finished picture behind it, not a shadow cast by its contour
    _brandGlow.image = [YZTheme glowImageWithColor:[YZTheme accentColor]];
    CGFloat width = self.bounds.size.width;
    // a phone on its side has little height, the picture shrinks before the tiles are pushed off the screen
    CGFloat side = MAX((CGFloat)80, MIN((CGFloat)150, self.bounds.size.height * 0.3f));
    top += 12;
    _brandImage.bounds = CGRectMake(0, 0, side, side);
    _brandImage.center = CGPointMake(width / 2, top + side / 2);
    _brandGlow.bounds = CGRectMake(0, 0, side * 1.7f, side * 1.7f);
    _brandGlow.center = _brandImage.center;
    top += side + 10;
    _brandName.bounds = CGRectMake(0, 0, MIN(width - 32, (CGFloat)320), 36);
    _brandName.center = CGPointMake(width / 2, top + 18);
    return top + 36 + 24;
}

// the private session shows its note in place of the tiles. returns whether it did
- (BOOL)layoutHero {
    BOOL incognito = !_previewing && [YZTheme isIncognito];
    _heroDisc.hidden = !incognito;
    _heroTitle.hidden = !incognito;
    _heroText.hidden = !incognito;
    _brandImage.hidden = incognito;
    _brandGlow.hidden = incognito || ![YZSettings mascotGlow];
    _brandName.hidden = incognito;
    if (!incognito)
        return NO;
    if (!_heroDisc) {
        _heroDisc = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 96, 96)];
        _heroDisc.layer.cornerRadius = 48;
        [self addSubview:_heroDisc];
        _heroIcon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 96, 96)];
        _heroIcon.contentMode = UIViewContentModeCenter;
        [_heroDisc addSubview:_heroIcon];
        _heroTitle = [[UILabel alloc] initWithFrame:CGRectZero];
        _heroTitle.font = [YZTheme boldSystemFontOfSize:22];
        _heroTitle.textAlignment = YZTextAlignmentCenter;
        _heroTitle.backgroundColor = [UIColor clearColor];
        [self addSubview:_heroTitle];
        _heroText = [[UILabel alloc] initWithFrame:CGRectZero];
        _heroText.font = [YZTheme systemFontOfSize:15];
        _heroText.numberOfLines = 0;
        _heroText.textAlignment = YZTextAlignmentCenter;
        _heroText.backgroundColor = [UIColor clearColor];
        [self addSubview:_heroText];
    }
    _heroDisc.hidden = NO;
    _heroTitle.hidden = NO;
    _heroText.hidden = NO;
    _heroDisc.backgroundColor = [YZTheme stateColor];
    _heroIcon.image = [YZTheme icon:YZIconIncognito size:48 color:[YZTheme accentColor]];
    _heroTitle.text = YZT(@"Приватный просмотр");
    _heroTitle.textColor = [YZTheme textColor];
    _heroText.text = [NSString stringWithFormat:@"%@\n\n%@", YZT(@"Страницы не попадают в историю. Cookie и данные сайтов удаляются, когда закрыта последняя приватная вкладка."),
                      YZT(@"Загруженные файлы и избранное сохраняются.")];
    _heroText.textColor = [YZTheme subtleTextColor];
    for (UIView *tile in self.subviews) {
        if ([tile isKindOfClass:[YZTileButton class]])
            tile.hidden = YES;
    }
    _sitesHeading.hidden = YES;
    _bookmarksHeading.hidden = YES;
    CGFloat width = self.bounds.size.width, textWidth = MIN(width - 48, (CGFloat)360);
    CGFloat top = 40;
    _heroDisc.bounds = CGRectMake(0, 0, 96, 96);
    _heroDisc.center = CGPointMake(width / 2, top + 48);
    top += 96 + 24;
    _heroTitle.frame = CGRectMake((width - textWidth) / 2, top, textWidth, 28);
    top += 28 + 12;
    CGSize fit = [_heroText sizeThatFits:CGSizeMake(textWidth, 10000)];
    _heroText.frame = CGRectMake((width - textWidth) / 2, top, textWidth, fit.height);
    self.contentSize = CGSizeMake(width, top + fit.height + 32);
    _contentDirty = NO;
    return YES;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // the bounds origin is the scroll offset: the photo stays where the screen is
    if (_backdrop && !_backdrop.hidden && !CGRectEqualToRect(_backdrop.frame, self.bounds))
        _backdrop.frame = self.bounds;
    // scrolling does not change tile geometry or content
    if (self.bounds.size.width < 1 || _builtWidth == self.bounds.size.width)
        return;
    _builtWidth = self.bounds.size.width;
    if ([self layoutHero])
        return;
    CGFloat top = [self layoutBrandFromTop:16];
    NSArray *sites = _sites;
    if (![sites count] && ![_bookmarks count]) {
        // a first run has no history, so a few neutral starting points are shown
        NSMutableArray *defaults = [NSMutableArray array];
        NSArray *pairs = [NSArray arrayWithObjects:@"https://ru.wikipedia.org/", YZT(@"Википедия"), @"https://duckduckgo.com/", @"DuckDuckGo", nil];
        for (NSUInteger i = 0; i + 1 < [pairs count]; i += 2) {
            YZRecord *record = [[[YZRecord alloc] init] autorelease];
            record.url = [pairs objectAtIndex:i];
            record.title = [pairs objectAtIndex:i + 1];
            [defaults addObject:record];
        }
        sites = defaults;
    }
    top = [self layoutSection:YZT(@"Недавние вкладки") records:sites tiles:_siteTiles title:_sitesHeading top:top];
    top = [self layoutSection:YZT(@"Избранное") records:_bookmarks tiles:_bookmarkTiles title:_bookmarksHeading top:top];
    self.contentSize = CGSizeMake(self.bounds.size.width, top + 16);
    _contentDirty = NO;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_siteTiles release];
    [_bookmarkTiles release];
    [_sitesHeading release];
    [_bookmarksHeading release];
    [_backdrop release];
    [_brandGlow release];
    [_brandImage release];
    [_brandName release];
    [_heroDisc release];
    [_heroIcon release];
    [_heroTitle release];
    [_heroText release];
    [_sites release];
    [_bookmarks release];
    [super dealloc];
}
@end
