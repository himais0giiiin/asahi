#import "YZBackground.h"
#import "YZSettings.h"
#import "YZStore.h"
#import "yozora_blur.h"
#import <CoreGraphics/CoreGraphics.h>

static UIImage *YZCachedPicture;
static NSInteger YZCachedStamp = -1;

static NSString *YZBackgroundPath(void) {
    return [[YZStore profileDirectory] stringByAppendingPathComponent:@"home-background.jpg"];
}

@implementation YZBackground

+ (UIImage *)image {
    NSInteger stamp = [YZSettings homeBackgroundStamp];
    if (!stamp)
        return nil;
    if (stamp != YZCachedStamp) {
        [YZCachedPicture release];
        YZCachedPicture = [[UIImage imageWithContentsOfFile:YZBackgroundPath()] retain];
        YZCachedStamp = stamp;
    }
    return YZCachedPicture;
}

static UIImage *YZCachedBlur;
static NSInteger YZCachedBlurStamp = -1;
static NSInteger YZCachedBlurPercent = -1;

// the picture is shrunk first so the box of a pass stays small, the layer scales the smooth result back up. a low blur keeps the full size
+ (UIImage *)imageBlurredBy:(NSInteger)percent {
    UIImage *picture = [self image];
    if (!picture || percent <= 0 || !picture.CGImage)
        return picture;
    NSInteger stamp = [YZSettings homeBackgroundStamp];
    if (YZCachedBlur && YZCachedBlurStamp == stamp && YZCachedBlurPercent == percent)
        return YZCachedBlur;
    size_t sourceWidth = CGImageGetWidth(picture.CGImage), sourceHeight = CGImageGetHeight(picture.CGImage);
    uint32_t radius = yozora_blur_radius((int)percent, (uint32_t)MAX(sourceWidth, sourceHeight));
    uint32_t shrink = yozora_blur_shrink(radius);
    size_t width = MAX((size_t)1, (sourceWidth + shrink - 1) / shrink), height = MAX((size_t)1, (sourceHeight + shrink - 1) / shrink);
    size_t stride = width * 4;
    size_t scratchSize = yozora_blur_scratch_size((uint32_t)width, (uint32_t)height);
    uint8_t *pixels = calloc(height, stride);
    uint8_t *scratch = malloc(scratchSize);
    UIImage *result = nil;
    if (pixels && scratch) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, stride, space, kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(space);
        if (context) {
            CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), picture.CGImage);
            yozora_blur_status status = yozora_blur_rgba(pixels, (uint32_t)width, (uint32_t)height, stride, yozora_blur_work_radius(radius, shrink), scratch, scratchSize);
            if (status == YOZORA_BLUR_OK) {
                CGImageRef blurred = CGBitmapContextCreateImage(context);
                if (blurred) {
                    result = [UIImage imageWithCGImage:blurred];
                    CGImageRelease(blurred);
                }
            } else {
                NSLog(@"yozora: the background was not blurred, status %d", (int)status);
            }
            CGContextRelease(context);
        } else {
            NSLog(@"yozora: the background was not blurred, no bitmap of %lux%lu", (unsigned long)width, (unsigned long)height);
        }
    } else {
        NSLog(@"yozora: the background was not blurred, no memory for %lux%lu", (unsigned long)width, (unsigned long)height);
    }
    free(pixels);
    free(scratch);
    if (!result)
        return picture;
    [YZCachedBlur release];
    YZCachedBlur = [result retain];
    YZCachedBlurStamp = stamp;
    YZCachedBlurPercent = percent;
    return result;
}

+ (CGFloat)lightnessOfImage:(UIImage *)picture {
    enum { side = 16 };
    uint8_t pixels[side * side * 4];
    memset(pixels, 0, sizeof pixels);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = picture.CGImage ? CGBitmapContextCreate(pixels, side, side, 8, side * 4, space, kCGImageAlphaPremultipliedLast) : NULL;
    CGColorSpaceRelease(space);
    if (!context) {
        NSLog(@"yozora: the lightness of the background could not be read");
        return 0;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), picture.CGImage);
    CGContextRelease(context);
    return yozora_luma_average(pixels, side, side, side * 4) / 255.0f;
}

+ (BOOL)storePicture:(UIImage *)picture {
    CGSize size = picture.size;
    if (size.width < 1 || size.height < 1)
        return NO;
    // a photo is decoded at full size only once, here: the screen never needs more than its own long side
    CGSize screen = [[UIScreen mainScreen] bounds].size;
    CGFloat pixels = MAX(screen.width, screen.height) * [[UIScreen mainScreen] scale];
    CGFloat longSide = MAX(size.width, size.height);
    CGFloat factor = longSide > pixels ? pixels / longSide : 1;
    CGSize target = CGSizeMake(MAX((CGFloat)1, round(size.width * factor)), MAX((CGFloat)1, round(size.height * factor)));
    UIGraphicsBeginImageContextWithOptions(target, YES, 1);
    [picture drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *data = scaled ? UIImageJPEGRepresentation(scaled, 0.82f) : nil;
    if (![data length])
        return NO;
    NSString *path = YZBackgroundPath();
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error]
        || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"yozora: the background was not written: %@", error);
        return NO;
    }
    [YZSettings noteHomeBackgroundChanged:YES];
    return YES;
}

+ (void)remove {
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:YZBackgroundPath()] && ![[NSFileManager defaultManager] removeItemAtPath:YZBackgroundPath() error:&error])
        NSLog(@"yozora: the background was not deleted: %@", error);
    [YZSettings noteHomeBackgroundChanged:NO];
}

@end
