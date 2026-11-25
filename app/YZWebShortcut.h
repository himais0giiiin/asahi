#import <UIKit/UIKit.h>

/* a shortcut of a site on the home screen. ios lets an app put no icon there, only a configuration profile with a
   web clip does, and the system installs a profile that Safari downloads. the profile is made here and served on
   the loopback address by the stream proxy, the clip opens yozora-app://open?url=..., which the app shows without
   its bars (see openWebAppURL: of the browser) */
@interface YZWebShortcut : NSObject
/* the address a clip opens for a page, nil when the page has no http or https address */
+ (NSURL *)launchURLForAddress:(NSString *)address;
/* the page address inside a launch address, nil when the address is not one of ours or the page is not http or https */
+ (NSString *)addressFromLaunchURL:(NSURL *)url;
/* makes the profile of the page and opens it in Safari. the reason is set when it fails before Safari is asked */
+ (BOOL)installForAddress:(NSString *)address title:(NSString *)title reason:(NSString **)reason;
@end
