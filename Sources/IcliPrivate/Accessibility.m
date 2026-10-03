#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <unistd.h>

// AXRuntime numeric attributes: verified on the rootless TestHost and compared
// with witchan/ios-mcp (8f46b68). String AX attributes are absent on this runtime.
typedef CFTypeRef AXElement;
static AXElement (*createApp)(pid_t);
static int (*copyAttribute)(AXElement, CFStringRef, CFTypeRef *);
static int (*setTimeout)(AXElement, float);
static Boolean (*getAXValue)(CFTypeRef, int, void *);
static int (*hitTest)(AXElement, AXElement *, float, float);
static Boolean (*applicationEnabled)(void);
static void (*setApplicationEnabled)(Boolean);
static Boolean (*automationEnabled)(void);
static void (*setAutomationEnabled)(Boolean);

// Both switches are system-wide and persist: every app launched while they are on
// loads the accessibility bundles and reports automation. A query needs them, so
// they go on before the first one and back to their old values when icli exits.
// Per-process rather than per-query, because `ui wait` polls in a loop and
// flipping a system-wide switch on every poll churns every app on the device.
static BOOL turnedOnApplication;
static BOOL turnedOnAutomation;

static void restoreSwitches(void) {
    if (turnedOnAutomation) setAutomationEnabled(false);
    if (turnedOnApplication) setApplicationEnabled(false);
    turnedOnAutomation = turnedOnApplication = NO;
}

// Answers YES when this call turned a switch on, so the caller knows the target
// app is only now being told to load its accessibility bundles. A switch whose
// current value cannot be read is left alone: turning one off at exit that the
// device's owner had turned on, for VoiceOver say, would be worse than not
// reading the tree.
static BOOL enableSwitches(void) {
    if (turnedOnApplication || turnedOnAutomation) return NO;
    BOOL application = applicationEnabled && setApplicationEnabled && !applicationEnabled();
    BOOL automation = automationEnabled && setAutomationEnabled && !automationEnabled();
    if (!application && !automation) return NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ atexit(restoreSwitches); });
    if (application) { setApplicationEnabled(true); turnedOnApplication = YES; }
    if (automation) { setAutomationEnabled(true); turnedOnAutomation = YES; }
    return YES;
}

static BOOL prepareAX(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *ax = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        void *accessibility = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        if (accessibility) {
            applicationEnabled = dlsym(accessibility, "_AXSApplicationAccessibilityEnabled");
            setApplicationEnabled = dlsym(accessibility, "_AXSApplicationAccessibilitySetEnabled");
            automationEnabled = dlsym(accessibility, "_AXSAutomationEnabled");
            setAutomationEnabled = dlsym(accessibility, "_AXSSetAutomationEnabled");
        }
        if (!ax) return;
        void (*client)(uint32_t) = dlsym(ax, "__AXSetRequestingClient");
        if (client) client(2);
        uint64_t (*override)(uint64_t) = dlsym(ax, "_AXOverrideRequestingClientType");
        if (override) override(2);
        createApp = dlsym(ax, "_AXUIElementCreateAppElementWithPid");
        copyAttribute = dlsym(ax, "AXUIElementCopyAttributeValue");
        setTimeout = dlsym(ax, "AXUIElementSetMessagingTimeout");
        getAXValue = dlsym(ax, "AXValueGetValue");
        hitTest = dlsym(ax, "AXUIElementCopyElementAtPosition");
    });
    return createApp && copyAttribute && getAXValue;
}

static id attribute(AXElement element, uint32_t key) {
    CFTypeRef value = NULL;
    int error = copyAttribute(element, (CFStringRef)(uintptr_t)key, &value);
    if (error) { if (value) CFRelease(value); return nil; }
    return CFBridgingRelease(value);
}

// SpringBoard reports frames in the fixed (portrait) space; apps report them
// in the upright interface, which is what taps and screenshots use.
static BOOL framesInFixedSpace(pid_t pid) {
    int (*pidPath)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
    char path[4096] = {0};
    if (!pidPath || pidPath(pid, path, sizeof(path)) <= 0) return NO;
    return strcmp(path, "/System/Library/CoreServices/SpringBoard.app/SpringBoard") == 0;
}

static CGRect interfaceRect(CGRect fixed) {
    double x1, y1, x2, y2;
    icli_screen_fixed_to_point(CGRectGetMinX(fixed), CGRectGetMinY(fixed), &x1, &y1);
    icli_screen_fixed_to_point(CGRectGetMaxX(fixed), CGRectGetMaxY(fixed), &x2, &y2);
    return CGRectStandardize(CGRectMake(x1, y1, x2 - x1, y2 - y1));
}

static NSDictionary *serializeElement(AXElement element, BOOL fixedSpace) {
    if (setTimeout) setTimeout(element, 0.25f);
    id value = attribute(element, 2003);
    CGRect frame = CGRectZero;
    if (!value || !getAXValue((__bridge CFTypeRef)value, 3, &frame) || !isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) || !isfinite(frame.size.height)) return nil;
    id label = attribute(element, 2001);
    id text = attribute(element, 2006);
    id identifier = attribute(element, 5019);
    id traitsValue = attribute(element, 2004);
    uint64_t traits = [traitsValue respondsToSelector:@selector(unsignedLongLongValue)]
        ? [traitsValue unsignedLongLongValue]
        : 0;
    BOOL enabled = (traits & UIAccessibilityTraitNotEnabled) == 0;
    BOOL clickable = enabled
        && frame.size.width > 0
        && frame.size.height > 0
        && ((traits & (UIAccessibilityTraitButton | UIAccessibilityTraitLink | UIAccessibilityTraitAdjustable)) != 0
            || (traits & UIAccessibilityTraitStaticText) == 0);
    NSString *role = (traits & UIAccessibilityTraitButton)
        ? @"button"
        : ((traits & UIAccessibilityTraitStaticText) ? @"text" : @"element");
    IcliScreenMetrics metrics = icli_screen_metrics();
    CGRect screen = CGRectMake(0, 0, metrics.width, metrics.height);
    CGPoint point = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    // An element can report a NaN activation point; NSJSONSerialization throws on
    // one, which takes down a host such as vphoned. Keep the frame's centre then.
    id pointValue = attribute(element, 2007);
    CGPoint activation;
    if (pointValue && getAXValue((__bridge CFTypeRef)pointValue, 1, &activation)
        && isfinite(activation.x) && isfinite(activation.y)) point = activation;
    if (fixedSpace) {
        frame = interfaceRect(frame);
        double x, y;
        icli_screen_fixed_to_point(point.x, point.y, &x, &y);
        point = CGPointMake(x, y);
    }
    return @{
        @"label": [label isKindOfClass:NSString.class] ? label : @"",
        @"identifier": [identifier isKindOfClass:NSString.class] ? identifier : @"",
        @"value": [text isKindOfClass:NSString.class]
            || ([text isKindOfClass:NSNumber.class] && isfinite([text doubleValue])) ? text : @"",
        @"role": role,
        @"traits": @(traits),
        @"enabled": @(enabled),
        @"clickable": @(clickable),
        @"visible": @(!CGRectIsEmpty(CGRectIntersection(frame, screen))),
        @"frame": @{
            @"x": @(frame.origin.x),
            @"y": @(frame.origin.y),
            @"width": @(frame.size.width),
            @"height": @(frame.size.height)
        },
        @"x": @(point.x),
        @"y": @(point.y)
    };
}

static NSDictionary *elementsResult(int pid, int max_elements) {
    AXElement root = createApp(pid);
    if (!root) return @{@"error": @"AX application unavailable"};
    if (setTimeout) setTimeout(root, 0.5f);
    CFTypeRef value = NULL;
    int error = copyAttribute(root, (CFStringRef)(uintptr_t)3015, &value);
    CFRelease(root);
    if (error || !value || CFGetTypeID(value) != CFArrayGetTypeID()) {
        if (value) CFRelease(value);
        return @{
            @"error": [NSString stringWithFormat:@"AX element query failed (%d)", error],
            @"pid": @(pid)
        };
    }
    NSArray *elements = CFBridgingRelease(value);
    NSMutableArray *rows = [NSMutableArray array];
    BOOL fixedSpace = framesInFixedSpace(pid);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    BOOL truncated = NO;
    for (id element in elements) {
        if (rows.count >= (NSUInteger)max_elements || NSProcessInfo.processInfo.systemUptime >= deadline) {
            truncated = YES;
            break;
        }
        NSDictionary *node = serializeElement((__bridge AXElement)element, fixedSpace);
        if (node) [rows addObject:node];
    }
    return @{
        @"source": @"ax",
        @"pid": @(pid),
        @"elements": rows,
        @"count": @(rows.count),
        @"truncated": @(truncated)
    };
}

static NSDictionary *elementAtResult(int pid, double x, double y) {
    AXElement root = createApp(pid), hit = NULL;
    if (!root) return @{@"error": @"AX application unavailable"};
    if (setTimeout) setTimeout(root, 0.5f);
    double fx = x, fy = y;
    icli_screen_point_to_fixed(x, y, &fx, &fy);
    int error = hitTest(root, &hit, (float)fx, (float)fy);
    CFRelease(root);
    if (error) {
        if (hit) CFRelease(hit);
        return @{@"error": [NSString stringWithFormat:@"AX hit testing failed (%d)", error]};
    }
    NSDictionary *node = hit ? serializeElement(hit, framesInFixedSpace(pid)) : nil;
    if (hit) CFRelease(hit);
    return @{@"source": @"ax", @"element": node ?: @{}, @"x": @(x), @"y": @(y)};
}

// An app running while the switches were off loads its accessibility bundles only
// once they turn on, so the query that turned them on can arrive before the app
// answers. Only that first query waits and asks again.
static const useconds_t kBundleLoadWait = 400000;

char *icli_ax_elements_json(int pid, int max_elements) {
    if (pid <= 0 || max_elements < 1 || max_elements > 2000) return icli_json(@{@"error": @"invalid AX query"});
    if (!prepareAX()) return icli_json(@{@"error": @"AX runtime unavailable"});
    BOOL enabled = enableSwitches();
    NSDictionary *result = elementsResult(pid, max_elements);
    if (enabled && [result[@"count"] unsignedIntegerValue] == 0) {
        usleep(kBundleLoadWait);
        result = elementsResult(pid, max_elements);
    }
    return icli_json(result);
}

char *icli_ax_element_at_json(int pid, double x, double y) {
    if (pid <= 0 || !prepareAX() || !hitTest) return icli_json(@{@"error": @"AX hit testing unavailable"});
    BOOL enabled = enableSwitches();
    NSDictionary *result = elementAtResult(pid, x, y);
    if (enabled && ((NSDictionary *)result[@"element"]).count == 0) {
        usleep(kBundleLoadWait);
        result = elementAtResult(pid, x, y);
    }
    return icli_json(result);
}
