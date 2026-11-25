#import <Foundation/Foundation.h>

/* own record of what went wrong, written to Library/Caches/yozora-crash.log whatever the system does. a block of the
   record is one event: a crash (signal or uncaught exception), a hang (the main thread or the core thread does not
   answer) or the end of a run that left no trace of its own (the system killed it, see +install). every block names what
   happened, in which thread, on which screen, with memory, the last notes, the registers and the stack of every thread.
   the system sends no report for an app that jumps into nothing, and for a kill it sends nothing the app can read */
@interface YZCrash : NSObject
/* installs the handlers and the watchdog, once, at the start of the app. reads the marker of the run before and writes a
   block when that run ended without a clean exit and without a crash block of its own */
+ (void)install;
/* the run before ended in a crash block of its own (a signal or an uncaught exception), read from its marker by +install.
   a kill, a hang and a clean end are not crashes. valid after +install */
+ (BOOL)previousRunCrashed;
/* the app state, so a quiet watchdog in the background is not read as a hang and a kill in the foreground is told from a
   normal end of a suspended app. called from the app delegate */
+ (void)applicationDidEnterBackground;
+ (void)applicationWillEnterForeground;
+ (void)applicationWillTerminate;
/* a note of what the app does, a ring of the last forty eight, written with every block so "somewhere in UIKit" still
   says what was on screen. any thread, two writers may mix a line */
+ (void)note:(NSString *)text;
/* a note of "event Class 0xaddress" for a screen or a view coming or going, so the record says which objects were alive */
+ (void)noteLifecycle:(NSString *)event object:(id)object;
/* keeps freed objects as zombies for the rest of the run: a message to one is logged with the class and the address and
   stops the app there, instead of a crash somewhere later in a pool. needs more memory. returns NO when this system
   has no way to do it */
+ (BOOL)enableZombies;
/* the path of the record */
+ (NSString *)path;
/* what the previous runs wrote, nil when nothing was written */
+ (NSString *)report;
+ (void)clearReport;
@end
