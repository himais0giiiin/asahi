#import <UIKit/UIKit.h>
#include "yozora_core.h"
#include "yozora_zoom.h"

@protocol YZPageViewDelegate;
@class YZSceneView;

@interface YZPageView : UIView <UITextInput> {
    yozora_core *_core;
    id<YZPageViewDelegate> _delegate;
    float _flingVelocity;
    float _flingRemainder;
    float _flingVelocityX;
    float _flingRemainderX;
    CFTimeInterval _flingTime;
    // where the finger went down, the block of the page under it takes the drag and the fling that follows
    CGPoint _gesturePoint;
    CGFloat _panLast;
    CGFloat _panLastX;
    BOOL _panning;
    // the zoom of the view over the page: the layout stays as it is, the host of the tiles is scaled on screen
    yozora_view_zoom _zoom;
    yozora_view_zoom _pinchStart;
    CGPoint _pinchStartFocal;
    int _pinchScrolled;
    float _zoomScrollRemainder;
    float _appliedRasterFactor;
    CGSize _zoomBoundsSize;
    BOOL _pinching;
    UIView *_zoomHost;
    yozora_input_kind _inputKind;
    YZSceneView *_sceneView;
    NSMutableDictionary *_mediaLayers;
    NSMutableDictionary *_videoPlaces;
    CFTimeInterval _tapTime;
    // the text the user selected: two handles at its ends and the menu with the copy action, which needs a responder that is no keyboard
    UIView *_startHandle;
    UIView *_endHandle;
    UIView *_menuTarget;
    BOOL _selectionActive;
    BOOL _selectionMenuWanted;
    CGPoint _selectionAnchor;
    char _selectionText[2048];
    BOOL _selectionHidden;
    // where the menu of the selection stands, which is where the share sheet of an ipad points
    CGRect _selectionTarget;
    UIMenuItem *_shareItem;
    // the text an input method is composing (the kana of Japanese before they turn into kanji) and where its caret is inside it
    NSString *_marked;
    NSInteger _markedCaretStart;
    NSInteger _markedCaretEnd;
    id<UITextInputDelegate> _inputDelegate;
    id<UITextInputTokenizer> _tokenizer;
}
@property(nonatomic, assign) yozora_core *core;
@property(nonatomic, assign) id<YZPageViewDelegate> delegate;
/* the selection of the core is the current match of find in page: it is painted by the page and has no handles or menu */
@property(nonatomic, assign) BOOL selectionHidden;
@property(nonatomic, readonly) BOOL flinging;
/* a drag, fling or pinch is moving the page */
@property(nonatomic, readonly) BOOL active;
- (void)showScene:(yozora_scene *)scene;
- (void)showMediaPlayers:(NSArray *)players excluding:(unsigned)fullscreenID;
- (void)clearFrame;
/* the factor the core paints tiles at on top of the screen scale, so an enlarged page is not a blurred one */
@property(nonatomic, readonly) float rasterFactor;
/* takes the enlargement away, a new page starts at scale 1 */
- (void)resetZoom;
/* a point of the page area of the core (the viewport) as it stands on the screen of this view */
- (CGPoint)screenPointForViewportPoint:(CGPoint)point;
/* puts every tile at its place for the scroll position asked last, so scrolling follows the finger while the
   core still paints the tiles ahead */
- (void)syncScrollOffset;
/* moves the page by the fling that is still running, call once per display frame */
- (void)advanceFlingAtTime:(CFTimeInterval)time;
- (void)stopFling;
/* puts the handles at the ends of the selected text and takes them away when nothing is selected, once per
   display frame */
- (void)updateSelection;
- (void)clearSelection;
/* for the menu of the selection */
- (void)copySelection;
- (void)shareSelection;
- (void)selectEverything;
/* shows the keyboard while a field of the page has focus, once per display frame. a field that got focus
   without a tap in the last second does not raise it, so a page cannot steal the keyboard */
- (void)updateInput;
@end

@protocol YZPageViewDelegate <NSObject>
- (void)pageView:(YZPageView *)view tappedAtPoint:(CGPoint)point;
- (void)pageViewDidScroll:(YZPageView *)view;
/* the zoom settled at a step that wants tiles at another scale: resize the core with the screen scale times the rasterFactor */
- (void)pageViewDidChangeRasterFactor:(YZPageView *)view;
/* the user asked to share the selected text, from a place of the page view */
- (void)pageView:(YZPageView *)view shareText:(NSString *)text fromRect:(CGRect)rect;
@end
