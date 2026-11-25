#import "YZMenuView.h"
#import "YZControls.h"
#import "YZStrings.h"
#import "YZSystemSheet.h"
#import "YZMotion.h"
#import "YZTheme.h"
#import <QuartzCore/QuartzCore.h>

// rows with a 26 point glyph, when they do not fit above the bar the list scrolls and the settings row stays
// in sight
static const CGFloat YZMenuRowHeight = 52;
static const CGFloat YZMenuGlyph = 26;
static const CGFloat YZMenuPadding = 8;

@interface YZMenuButton : YZStateButton {
    YZMenuItem _item;
}
@property(nonatomic, assign) YZMenuItem item;
@end
@implementation YZMenuButton
@synthesize item = _item;
- (void)setHighlighted:(BOOL)highlighted {
    BOOL pressed = highlighted && !self.highlighted;
    [super setHighlighted:highlighted];
    if (pressed)
        [YZTheme animateFeedbackOfView:self.imageView];
}
@end

@implementation YZMenuView
@synthesize delegate = _delegate;
@synthesize bottomInset = _bottomInset;
@synthesize rightInset = _rightInset;
@synthesize anchorsTop = _anchorsTop;
@synthesize topInset = _topInset;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    // a light scrim: the page stays readable behind a small card
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18f];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIButton *dismiss = [UIButton buttonWithType:UIButtonTypeCustom];
    dismiss.frame = self.bounds;
    dismiss.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dismiss addTarget:self action:@selector(dismissPressed) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:dismiss];
    return self;
}

- (void)dismissPressed { [_delegate menuViewDidDismiss:self]; }

- (void)itemPressed:(YZMenuButton *)button { [_delegate menuView:self didSelectItem:button.item]; }

- (void)showItems:(NSArray *)items titles:(NSArray *)titles icons:(NSArray *)icons {
    [_items release];
    _items = [items copy];
    [_titles release];
    _titles = [titles copy];
    [_panel removeFromSuperview];
    [_panel release];
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    CGFloat panelWidth = MIN(width - 24, (CGFloat)300);
    // the settings row is pinned under the list and the rest scrolls when room is short. a phone on its side
    // has little room, so the card keeps a margin to the top
    CGFloat room = _anchorsTop ? height - _topInset - 24 : height - _bottomInset - 56;
    CGFloat rowHeight = YZMenuRowHeight;
    BOOL pinLast = [items count] > 1 && [[items lastObject] intValue] == YZMenuSettings;
    NSUInteger scrolled = [items count] - (pinLast ? 1 : 0);
    CGFloat footerHeight = pinLast ? rowHeight + YZMenuPadding : 0;
    CGFloat listContent = YZMenuPadding + rowHeight * scrolled + (pinLast ? 4 : YZMenuPadding);
    CGFloat fullHeight = listContent + footerHeight;
    CGFloat panelHeight = MIN(fullHeight, MAX(footerHeight + rowHeight * 3, room));
    CGFloat listHeight = panelHeight - footerHeight;
    CGRect frame = CGRectMake(width - _rightInset - panelWidth, _anchorsTop ? _topInset : height - _bottomInset - panelHeight, panelWidth, panelHeight);
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelWidth, panelHeight)];
    // the card grows from the corner where the menu button is
    _panel.layer.anchorPoint = CGPointMake(1, _anchorsTop ? 0 : 1);
    _panel.center = CGPointMake(CGRectGetMaxX(frame), _anchorsTop ? CGRectGetMinY(frame) : CGRectGetMaxY(frame));
    _panel.autoresizingMask = (_anchorsTop ? UIViewAutoresizingFlexibleBottomMargin : UIViewAutoresizingFlexibleTopMargin) | UIViewAutoresizingFlexibleLeftMargin;
    // the shadow lies on the panel and the corners are cut on the view inside it, a view that clips has no shadow
    _panel.layer.shadowColor = [[UIColor blackColor] CGColor];
    _panel.layer.shadowOpacity = 0.3f;
    _panel.layer.shadowRadius = 14;
    _panel.layer.shadowOffset = CGSizeMake(0, 5);
    _panel.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_panel.bounds cornerRadius:[YZTheme cardRadius]].CGPath;
    UIView *card = [[[UIView alloc] initWithFrame:_panel.bounds] autorelease];
    card.backgroundColor = [YZTheme cardColor];
    card.layer.cornerRadius = [YZTheme cardRadius];
    card.layer.masksToBounds = YES;
    [_panel addSubview:card];
    UIScrollView *list = [[[YZScrollView alloc] initWithFrame:CGRectMake(0, 0, panelWidth, listHeight)] autorelease];
    list.tag = 9;
    list.contentSize = CGSizeMake(panelWidth, listContent);
    list.showsHorizontalScrollIndicator = NO;
    list.alwaysBounceVertical = NO;
    // a touch on a row must not wait for the scroll view to decide it is no drag, and a drag that starts on a
    // row still scrolls (YZScrollView)
    list.delaysContentTouches = NO;
    list.alwaysBounceVertical = NO;
    list.scrollEnabled = YES;
    [card addSubview:list];
    UIView *footer = nil;
    if (pinLast) {
        footer = [[[UIView alloc] initWithFrame:CGRectMake(0, listHeight, panelWidth, footerHeight)] autorelease];
        footer.tag = 10;
        UIView *line = [[[UIView alloc] initWithFrame:CGRectMake(16, 0, panelWidth - 32, 1)] autorelease];
        line.backgroundColor = [YZTheme separatorColor];
        [footer addSubview:line];
        [card addSubview:footer];
    }
    for (NSUInteger i = 0; i < [items count]; ++i) {
        BOOL pinned = pinLast && i + 1 == [items count];
        YZMenuButton *row = [YZMenuButton buttonWithType:UIButtonTypeCustom];
        row.frame = pinned ? CGRectMake(0, 2, panelWidth, rowHeight) : CGRectMake(0, YZMenuPadding + i * rowHeight, panelWidth, rowHeight);
        row.pillInsets = UIEdgeInsetsMake(2, 8, 2, 8);
        row.item = (YZMenuItem)[[items objectAtIndex:i] intValue];
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        row.contentEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 16);
        row.titleEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 0);
        [row setImage:[YZTheme icon:(YZIcon)[[icons objectAtIndex:i] intValue] size:YZMenuGlyph color:[YZTheme accentColor]] forState:UIControlStateNormal];
        [row setTitle:[titles objectAtIndex:i] forState:UIControlStateNormal];
        [row setTitleColor:[YZTheme textColor] forState:UIControlStateNormal];
        row.titleLabel.font = [YZTheme systemFontOfSize:16];
        // a long title (the blocker row) wraps to a second line, one line cut it to "Включить б...ик". 0 is word wrap in both
        // UILineBreakModeWordWrap and NSLineBreakByWordWrapping
        row.titleLabel.numberOfLines = 2;
        row.titleLabel.lineBreakMode = (NSLineBreakMode)0;
        [row addTarget:self action:@selector(itemPressed:) forControlEvents:UIControlEventTouchUpInside];
        [pinned ? footer : list addSubview:row];
    }
    [self addSubview:_panel];
}

// the sheet of the system answers with the index of a button, the last one is its cancel button
- (void)actionSheet:(id)sheet clickedButtonAtIndex:(NSInteger)index {
    (void)sheet;
    id shown = _sheet;
    _sheet = nil;
    [shown release];
    if (index < 0 || index >= (NSInteger)[_items count])
        [_delegate menuViewDidDismiss:self];
    else
        [_delegate menuView:self didSelectItem:(YZMenuItem)[[_items objectAtIndex:(NSUInteger)index] intValue]];
}

- (void)presentSystemSheet {
    _sheet = YZSystemSheetMake(_titles, YZT(@"Отмена"), self);
    if (!_sheet) {
        [_delegate menuViewDidDismiss:self];
        return;
    }
    // no scrim and no card: the sheet dims the screen itself
    self.backgroundColor = [UIColor clearColor];
    _panel.hidden = YES;
    CGSize size = self.bounds.size;
    CGRect from = CGRectMake(size.width - _rightInset - 1, _anchorsTop ? _topInset : size.height - _bottomInset, 1, 1);
    YZSystemSheetShow(_sheet, self, from);
}

- (void)present {
    if ([YZTheme isClassic]) {
        [self presentSystemSheet];
        return;
    }
    UIColor *scrim = [self.backgroundColor retain];
    self.backgroundColor = [UIColor clearColor];
    [UIView animateWithDuration:[YZTheme animationsEnabled] ? 0.25 : 0 animations:^{ self.backgroundColor = scrim; } completion:^(BOOL finished) {
        (void)finished;
        [scrim release];
    }];
    _panel.alpha = 0;
    // the flat design opens a menu the way ios 7 does, from just under its size, where the modern one grows from a point
    CGFloat opening = [YZTheme isFlat] ? 0.95f : 0.4f;
    _panel.transform = CGAffineTransformMakeScale(opening, opening);
    YZMotionAnimateView(_panel, CGAffineTransformIdentity, 1, YOZORA_MOTION_WOBBLE, 0, nil);
    // the glyphs wobble in one after the other while the card opens, the flat design keeps them still
    if ([YZTheme isFlat])
        return;
    NSUInteger animated = 0;
    for (UIView *card in _panel.subviews) {
        for (UIView *row in [card viewWithTag:9].subviews) {
            if (![row isKindOfClass:[YZMenuButton class]])
                continue;
            YZMotionAnimateEnter([(UIButton *)row imageView], CGAffineTransformMakeScale(0.5f, 0.5f), 0, YOZORA_MOTION_WOBBLE, 0.08 + animated * 0.025);
            if (++animated == 8)
                return;
        }
    }
}

- (void)dismissWithCompletion:(void (^)(void))completion {
    if (_sheet) {
        id shown = _sheet;
        _sheet = nil;
        YZSystemSheetDismiss(shown);
        [shown release];
    }
    if ([YZTheme isClassic]) {
        if (completion)
            completion();
        return;
    }
    self.userInteractionEnabled = NO;
    [UIView animateWithDuration:[YZTheme animationsEnabled] ? 0.18 : 0 animations:^{ self.backgroundColor = [UIColor clearColor]; } completion:nil];
    YZMotionAnimateView(_panel, CGAffineTransformMakeScale([YZTheme isFlat] ? 0.96f : 0.7f, [YZTheme isFlat] ? 0.96f : 0.7f), 0, YOZORA_MOTION_DISMISS, 0, ^(BOOL finished) {
        (void)finished;
        if (completion)
            completion();
    });
}

- (void)dealloc {
    if (_sheet) {
        YZSystemSheetDismiss(_sheet);
        [_sheet release];
    }
    [_items release];
    [_titles release];
    [_panel release];
    [super dealloc];
}
@end
