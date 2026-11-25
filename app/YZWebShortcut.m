#import "YZWebShortcut.h"
#import "YZFavicons.h"
#import "YZStreamProxy.h"
#import "YZCompat.h"
#import "YZStrings.h"
#import "YZTheme.h"
#include <string.h>

static NSString *const YZShortcutScheme = @"yozora-app";
// the longest address a clip carries, the system keeps the URL of a clip whole but a profile of megabytes helps nobody
static const NSUInteger YZShortcutAddressLimit = 2048;
// the icon of a clip is 180 points, the largest size of a home screen icon
static const CGFloat YZShortcutIconSide = 180;
// seconds the app keeps the loopback address alive while Safari fetches the profile
static const NSTimeInterval YZShortcutServeSeconds = 120;

static NSString *YZEscaped(NSString *text) {
    NSString *encoded = (NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)text, NULL, CFSTR("!*'();:@&=+$,/?#[]%"), kCFStringEncodingUTF8);
    return [encoded autorelease];
}

static NSString *YZNewUUID(void) {
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    NSString *text = (NSString *)CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return [text autorelease];
}

static BOOL YZIsWebAddress(NSString *address) {
    NSURL *url = [NSURL URLWithString:address];
    NSString *scheme = [[url scheme] lowercaseString];
    return [[url host] length] && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
}

// the favicon on its tile when the site has one, else the first letter of the host on the accent. drawn at a size the
// system scales down, a favicon of 32 points is enlarged to about half of the side
static UIImage *YZShortcutIcon(NSString *address, NSString *title) {
    UIImage *favicon = [YZFavicons iconForURL:address];
    NSString *host = [YZFavicons hostOfURL:address];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(YZShortcutIconSide, YZShortcutIconSide), YES, 1);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect all = CGRectMake(0, 0, YZShortcutIconSide, YZShortcutIconSide);
    UIColor *tile = favicon ? [YZFavicons tileColorForIcon:favicon] : [YZTheme accentColor];
    CGContextSetFillColorWithColor(context, tile.CGColor);
    CGContextFillRect(context, all);
    if (favicon) {
        CGFloat side = 104;
        [favicon drawInRect:CGRectMake((YZShortcutIconSide - side) / 2, (YZShortcutIconSide - side) / 2, side, side)];
    } else {
        NSString *source = [title length] ? title : host;
        NSString *letter = [source length] ? [[source substringToIndex:1] uppercaseString] : @"?";
        UIFont *font = [YZTheme boldSystemFontOfSize:96];
        CGSize size = YZTextSize(letter, font);
        YZDrawText(letter, CGPointMake((YZShortcutIconSide - size.width) / 2, (YZShortcutIconSide - size.height) / 2), font, [UIColor whiteColor]);
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

// the files of the last profile: a new shortcut replaces them, so at most one profile is on disk and one address served
static unsigned YZServedStream;
static unsigned YZServedGeneration;
static NSString *YZServedPath;
static NSUInteger YZServeToken;
static UIBackgroundTaskIdentifier YZServeTask;
static BOOL YZServeTaskOn;

static void YZStopServing(void) {
    if (YZServedStream) {
        [[YZStreamProxy shared] releaseStream:YZServedStream generation:YZServedGeneration];
        YZServedStream = 0;
    }
    if (YZServedPath) {
        [[NSFileManager defaultManager] removeItemAtPath:YZServedPath error:NULL];
        [YZServedPath release];
        YZServedPath = nil;
    }
    if (YZServeTaskOn) {
        YZServeTaskOn = NO;
        [[UIApplication sharedApplication] endBackgroundTask:YZServeTask];
    }
}

@implementation YZWebShortcut

+ (NSURL *)launchURLForAddress:(NSString *)address {
    if (!YZIsWebAddress(address) || [address length] > YZShortcutAddressLimit)
        return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://open?url=%@", YZShortcutScheme, YZEscaped(address)]];
}

+ (NSString *)addressFromLaunchURL:(NSURL *)url {
    if (![[[url scheme] lowercaseString] isEqualToString:YZShortcutScheme])
        return nil;
    for (NSString *pair in [[url query] componentsSeparatedByString:@"&"]) {
        if (![pair hasPrefix:@"url="])
            continue;
        NSString *address = [[pair substringFromIndex:4] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        return [address length] <= YZShortcutAddressLimit && YZIsWebAddress(address) ? address : nil;
    }
    return nil;
}

+ (BOOL)installForAddress:(NSString *)address title:(NSString *)title reason:(NSString **)reason {
    NSURL *launch = [self launchURLForAddress:address];
    if (!launch) {
        if (reason)
            *reason = YZT(@"У этой страницы нет адреса, который можно сохранить");
        return NO;
    }
    NSString *host = [YZFavicons hostOfURL:address];
    NSString *label = [title length] ? title : host;
    if ([label length] > 40)
        label = [label substringToIndex:40];
    NSData *icon = UIImagePNGRepresentation(YZShortcutIcon(address, label));
    NSString *clipID = YZNewUUID();
    NSDictionary *clip = [NSDictionary dictionaryWithObjectsAndKeys:
        @"com.apple.webClip.managed", @"PayloadType",
        [NSNumber numberWithInt:1], @"PayloadVersion",
        [@"com.sqmrak.yozora.webclip." stringByAppendingString:clipID], @"PayloadIdentifier",
        clipID, @"PayloadUUID",
        label, @"PayloadDisplayName",
        label, @"Label",
        [launch absoluteString], @"URL",
        [NSNumber numberWithBool:YES], @"FullScreen",
        [NSNumber numberWithBool:YES], @"IsRemovable",
        [NSNumber numberWithBool:YES], @"Precomposed",
        icon, @"Icon", nil];
    NSString *profileID = YZNewUUID();
    NSDictionary *profile = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSArray arrayWithObject:clip], @"PayloadContent",
        @"Configuration", @"PayloadType",
        [NSNumber numberWithInt:1], @"PayloadVersion",
        [@"com.sqmrak.yozora.shortcut." stringByAppendingString:profileID], @"PayloadIdentifier",
        profileID, @"PayloadUUID",
        label, @"PayloadDisplayName",
        @"Yozora", @"PayloadOrganization",
        host ? host : @"", @"PayloadDescription", nil];
    NSError *error = nil;
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:profile format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (![xml length]) {
        NSLog(@"yozora: shortcut profile was not made: %@", error);
        if (reason)
            *reason = YZT(@"Не удалось подготовить ярлык");
        return NO;
    }
    YZStopServing();
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Shortcuts"];
    NSString *name = [clipID stringByAppendingString:@".mobileconfig"];
    NSString *path = [directory stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]
        || ![xml writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"yozora: shortcut profile was not written: %@", error);
        if (reason)
            *reason = YZT(@"Не удалось подготовить ярлык");
        return NO;
    }
    NSURL *base = [[YZStreamProxy shared] localURLForFiles:[NSDictionary dictionaryWithObject:path forKey:name] stream:&YZServedStream generation:&YZServedGeneration];
    if (!base) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        if (reason)
            *reason = YZT(@"Не удалось подготовить ярлык");
        return NO;
    }
    YZServedPath = [path retain];
    // safari fetches the profile while this app is in the background, the socket needs the time of a background task
    YZServeTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{ YZStopServing(); }];
    YZServeTaskOn = YES;
    NSUInteger token = ++YZServeToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(YZShortcutServeSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // a newer shortcut owns the files now
        if (token == YZServeToken)
            YZStopServing();
    });
    if (![[UIApplication sharedApplication] openURL:[NSURL URLWithString:[[base absoluteString] stringByAppendingString:name]]]) {
        YZStopServing();
        if (reason)
            *reason = YZT(@"Система не открыла Safari");
        return NO;
    }
    return YES;
}

@end
