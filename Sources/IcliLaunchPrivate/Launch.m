#import "IcliLaunchPrivate.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>

@interface NSObject (IcliLaunchLS)
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

static mach_port_t (*pSBSSpringBoardServerPort)(void);
static void (*pSBGetScreenLockStatus)(mach_port_t, BOOL *, BOOL *);
// The Copy rule: the identifier comes back retained.
static NSString *(*pSBSCopyFrontmostApplicationDisplayIdentifier)(void) NS_RETURNS_RETAINED;
static int (*pSBSLaunchApplicationWithIdentifierAndLaunchOptions)(NSString *, NSDictionary *, NSDictionary *, BOOL);

static void icli_launch_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sbs = dlopen(
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            RTLD_NOW
        );
        if (!sbs) return;
#define SYM(p, name) p = (typeof(p))dlsym(sbs, name)
        SYM(pSBSSpringBoardServerPort, "SBSSpringBoardServerPort");
        SYM(pSBGetScreenLockStatus, "SBGetScreenLockStatus");
        SYM(pSBSCopyFrontmostApplicationDisplayIdentifier, "SBSCopyFrontmostApplicationDisplayIdentifier");
        SYM(pSBSLaunchApplicationWithIdentifierAndLaunchOptions, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
#undef SYM
    });
}

static char *launchJSON(NSDictionary *value) {
    if (![NSJSONSerialization isValidJSONObject:value]) return strdup("{}");
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : strdup("{}");
}

static bool notifyFlag(const char *name) {
    int token = 0;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
        return false;
    }
    uint64_t state = 0;
    notify_get_state(token, &state);
    notify_cancel(token);
    return state != 0;
}

// SBSGetScreenLockStatus reads unlocked on a locked iOS 26 device, and
// MobileKeyBag answers nothing useful without a passcode, so the lock comes
// from SpringBoard's notification and SBGetScreenLockStatus together.
IcliLockStatus icli_lock_status(void) {
    icli_launch_init();
    IcliLockStatus st = {false, false, false};
    st.locked = notifyFlag("com.apple.springboard.lockstate");
    st.screen_off = notifyFlag("com.apple.springboard.hasBlankedScreen");
    if (pSBSSpringBoardServerPort && pSBGetScreenLockStatus) {
        BOOL locked = NO;
        BOOL passcode = NO;
        pSBGetScreenLockStatus(pSBSSpringBoardServerPort(), &locked, &passcode);
        st.locked = st.locked || locked;
        st.passcode_enabled = passcode;
    }
    return st;
}

// SpringBoardServices launches for a caller with
// com.apple.springboard.launchapplications. Any other caller falls back to
// LaunchServices, which needs no entitlement and answers NO while the device
// is locked; that answer is the result, not something to wait out.
IcliLaunchResult icli_launch_app(const char *bundle_id) {
    icli_launch_init();
    if (!bundle_id) {
        return IcliLaunchRefused;
    }
    @autoreleasepool {
        NSString *bid = [NSString stringWithUTF8String:bundle_id];
        if (pSBSLaunchApplicationWithIdentifierAndLaunchOptions &&
            pSBSLaunchApplicationWithIdentifierAndLaunchOptions(bid, nil, nil, NO) == 0) {
            return IcliLaunchAccepted;
        }
        id ws = icli_ls_workspace();
        if (ws && [ws respondsToSelector:@selector(openApplicationWithBundleID:)] &&
            [ws openApplicationWithBundleID:bid]) {
            return IcliLaunchAccepted;
        }
    }
    IcliLockStatus lock = icli_lock_status();
    return lock.locked || lock.screen_off ? IcliLaunchLocked : IcliLaunchRefused;
}

// The FrontBoard focal assertion identifies the app receiving input. The
// older SpringBoard query may be stale even while another app is on screen.
// Setup Assistant drops its launch assertion and never takes a workspace focal
// one, yet RunningBoard keeps its role at UserInteractiveFocal, so the role
// decides when no assertion does.
static NSString *runningBoardFocalApplication(void) {
    void *framework = dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
    if (!framework) return nil;
    NSString *(*roleName)(uint8_t) = dlsym(framework, "NSStringFromRBSRole");
    SEL roleSelector = NSSelectorFromString(@"cpuRole");
    Class handleClass = NSClassFromString(@"RBSProcessHandle");
    Class identifierClass = NSClassFromString(@"RBSProcessIdentifier");
    SEL identifierSelector = NSSelectorFromString(@"identifierWithPid:");
    SEL handleSelector = NSSelectorFromString(@"handleForIdentifier:error:");
    if (![identifierClass respondsToSelector:identifierSelector] || ![handleClass respondsToSelector:handleSelector]) {
        return nil;
    }
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0) {
        return nil;
    }
    length += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = calloc(1, length);
    if (!processes || sysctl(mib, 3, processes, &length, NULL, 0) != 0) {
        free(processes);
        return nil;
    }
    void *libproc = dlopen("/usr/lib/libproc.dylib", RTLD_NOW);
    int (*pidPath)(int, void *, uint32_t) = libproc ? dlsym(libproc, "proc_pidpath") : NULL;
    NSMutableSet<NSString *> *focalIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *focalRoleIDs = [NSMutableSet set];
    for (size_t i = 0; i < length / sizeof(struct kinfo_proc) && focalIDs.count < 2; i++) {
        pid_t pid = processes[i].kp_proc.p_pid;
        char path[4096] = {0};
        // Only app bundles can be the frontmost application.
        if (pid <= 0 || !pidPath || pidPath(pid, path, sizeof(path)) <= 0) {
            continue;
        }
        char *app = strstr(path, ".app/");
        if (!app || strchr(app + 5, '/')) continue;
        // Callers poll this, launchApp ten times a second, and a host thread
        // may have no pool of its own to drain the RunningBoard objects.
        @autoreleasepool {
        @try {
            id identifier = ((id (*)(id, SEL, int))objc_msgSend)(identifierClass, identifierSelector, pid);
            id handle = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(handleClass, handleSelector, identifier, NULL);
            NSString *bundleID = [[handle valueForKey:@"identity"] valueForKey:@"embeddedApplicationIdentifier"];
            if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length ||
                [bundleID containsString:@"WidgetRenderer"] || strstr(path, "WidgetRenderer")) {
                continue;
            }
            id state = [handle valueForKey:@"currentState"];
            if (roleName && [state respondsToSelector:roleSelector]) {
                uint8_t role = ((uint8_t (*)(id, SEL))objc_msgSend)(state, roleSelector);
                if ([roleName(role) isEqualToString:@"UserInteractiveFocal"]) [focalRoleIDs addObject:bundleID];
            }
            for (id assertion in [state valueForKey:@"assertions"]) {
                NSString *domain = [assertion valueForKey:@"domain"];
                if ([domain isKindOfClass:[NSString class]] &&
                    ([domain containsString:@"Workspace-ForegroundFocal"] ||
                     [domain containsString:@"com.apple.frontboard:SuspendableRole-UIFocal"])) {
                    [focalIDs addObject:bundleID];
                    break;
                }
            }
        } @catch (NSException *ex) {
            (void)ex;
        }
        }
    }
    free(processes);
    if (libproc) dlclose(libproc);
    if (focalIDs.count == 1) return focalIDs.anyObject;
    return focalIDs.count == 0 && focalRoleIDs.count == 1 ? focalRoleIDs.anyObject : nil;
}

char *icli_frontmost_app_json(void) {
    icli_launch_init();
    NSString *bid = runningBoardFocalApplication();
    if (bid.length) return launchJSON(@{@"bundle_id": bid, @"verified": @YES, @"source": @"runningboard"});
    if (pSBSCopyFrontmostApplicationDisplayIdentifier)
        bid = pSBSCopyFrontmostApplicationDisplayIdentifier();
    return launchJSON(@{
        @"bundle_id": bid.length ? bid : @"com.apple.springboard",
        @"verified": @NO,
        @"source": bid.length ? @"springboard_query" : @"unavailable",
    });
}

