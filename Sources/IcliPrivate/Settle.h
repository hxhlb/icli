#pragma once
#import <CoreFoundation/CoreFoundation.h>
#include <unistd.h>

/// Waits `seconds` for an asynchronous system change to land. The current run
/// loop runs meanwhile, so a host's main thread keeps serving its sources;
/// on a thread whose run loop has none, such as a GCD worker in a daemon,
/// CFRunLoopRunInMode returns at once, so the rest of the time is slept.
static inline void icli_settle(CFTimeInterval seconds) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
    for (;;) {
        CFTimeInterval left = deadline - CFAbsoluteTimeGetCurrent();
        if (left <= 0) return;
        if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, left, false) == kCFRunLoopRunFinished) {
            usleep((useconds_t)(left * 1000000));
            return;
        }
    }
}
