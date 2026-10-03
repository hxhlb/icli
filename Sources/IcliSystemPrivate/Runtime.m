#import "IcliSystemPrivate.h"
#import "SystemJSON.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/mount.h>
#import <sys/sysctl.h>
#import <os/lock.h>

// This process uses physical paths. Bootstrap tools may use vroot paths.
// Resolve APIs at runtime so both package layouts contain the same Mach-O.
// The answer is kept, but a long-running host may have started before the
// bootstrap was installed, or outlive its removal, so a missing bootstrap is
// looked for again (see icli_bootstrap_json). The lock guards all five.
static os_unfair_lock bootstrapLock = OS_UNFAIR_LOCK_INIT;
static NSString *bootstrapPrefix;
static NSString *rootfsPrefix;
static NSString *bootstrapSource;
static char *(*convertJB)(const char *, char *);
static char *(*convertRoot)(const char *, char *);

/// Call with bootstrapLock held.
static void resolveBootstrapLocked(void) {
    if (bootstrapPrefix) return;
    NSArray *libraries = @[
        @"@executable_path/../lib/libroot.dylib",
        @"@executable_path/.jbroot/usr/lib/libroot.dylib",
        @"/var/jb/usr/lib/libroot.dylib",
        @"/usr/lib/libroot.dylib"
    ];
    for (NSString *path in libraries) {
        void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
        if (!handle) continue;
        const char *(*getJB)(void) = dlsym(handle, "libroot_get_jbroot_prefix");
        const char *(*getRoot)(void) = dlsym(handle, "libroot_get_root_prefix");
        const char *prefix = getJB ? getJB() : NULL;
        if (!prefix) { dlclose(handle); continue; }
        bootstrapPrefix = prefix[0] ? @(prefix) : @"/";
        const char *root = getRoot ? getRoot() : NULL;
        rootfsPrefix = root && root[0] ? @(root) : @"/";
        convertJB = dlsym(handle, "libroot_jbrootpath");
        convertRoot = dlsym(handle, "libroot_rootfspath");
        bootstrapSource = @"libroot";
        break; // Keep the library loaded for the conversion functions.
    }
    if (!bootstrapPrefix) {
        for (NSString *path in @[@"@executable_path/.jbroot/usr/lib/libroothide.dylib", @"@executable_path/../lib/libroothide.dylib"]) {
            void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
            if (!handle) continue;
            const char *(*getJB)(const char *) = dlsym(handle, "jbroot");
            const char *prefix = getJB ? getJB("/") : NULL;
            if (prefix && prefix[0] == '/') {
                bootstrapPrefix = @(prefix);
                rootfsPrefix = @"/rootfs";
                bootstrapSource = @"libroothide";
            }
            dlclose(handle);
            if (bootstrapPrefix) break;
        }
    }
    if (!bootstrapPrefix) {
        char executable[PATH_MAX];
        uint32_t size = sizeof(executable);
        if (_NSGetExecutablePath(executable, &size) == 0) {
            NSString *link =
                [[@(executable) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".jbroot"];
            char resolved[PATH_MAX];
            if (realpath(link.fileSystemRepresentation, resolved)) {
                bootstrapPrefix = @(resolved);
                rootfsPrefix = @"/rootfs";
                bootstrapSource = @"executable .jbroot";
            }
        }
    }
    if (!bootstrapPrefix) {
        void *hook = dlopen("systemhook.dylib", RTLD_NOLOAD);
        if (hook) {
            const char *(*getJB)(void) = dlsym(hook, "get_jbroot");
            const char *prefix = getJB ? getJB() : NULL;
            BOOL isDirectory = NO;
            if (prefix && prefix[0] == '/' && strcmp(prefix, "/") != 0 &&
                [NSFileManager.defaultManager fileExistsAtPath:@(prefix) isDirectory:&isDirectory] && isDirectory) {
                bootstrapPrefix = @(prefix);
                rootfsPrefix = @"/rootfs";
                bootstrapSource = @"systemhook";
            }
            dlclose(hook);
        }
    }
    if (!bootstrapPrefix) {
        bootstrapPrefix = access("/var/jb", F_OK) == 0 ? @"/var/jb" : @"/";
        rootfsPrefix = @"/";
        bootstrapSource = @"filesystem fallback";
    }
    while (bootstrapPrefix.length > 1 && [bootstrapPrefix hasSuffix:@"/"]) bootstrapPrefix = [bootstrapPrefix substringToIndex:bootstrapPrefix.length - 1];
}

/// Call with bootstrapLock held; nil when no bootstrap was found.
static NSString *bootstrapLayoutLocked(void) {
    struct statfs rootMount;
    BOOL rootWritable = statfs("/", &rootMount) == 0 && !(rootMount.f_flags & MNT_RDONLY);
    return [rootfsPrefix isEqual:@"/rootfs"] || [bootstrapPrefix containsString:@".jbroot-"]
        ? @"roothide"
        : ([bootstrapPrefix isEqual:@"/"] ? (rootWritable ? @"rootful" : nil) : @"rootless");
}

/// Resolves the bootstrap, or resolves it again when the last answer found
/// none or names a directory that is gone.
char *icli_bootstrap_json(void) {
    os_unfair_lock_lock(&bootstrapLock);
    if (bootstrapPrefix && (!bootstrapLayoutLocked() || access(bootstrapPrefix.fileSystemRepresentation, F_OK) != 0)) {
        bootstrapPrefix = rootfsPrefix = bootstrapSource = nil;
        convertJB = convertRoot = NULL;
    }
    resolveBootstrapLocked();
    NSString *layout = bootstrapLayoutLocked();
    NSDictionary *info = @{
        @"jbroot": layout ? bootstrapPrefix : NSNull.null,
        @"rootfs": rootfsPrefix,
        @"layout": layout ?: NSNull.null,
        @"source": bootstrapSource
    };
    os_unfair_lock_unlock(&bootstrapLock);
    return icli_system_json(info);
}

char *icli_jbroot_path(const char *path) {
    if (!path) return NULL;
    if (path[0] != '/') return strdup(path);
    os_unfair_lock_lock(&bootstrapLock);
    resolveBootstrapLocked();
    char *(*convert)(const char *, char *) = convertJB;
    NSString *prefix = bootstrapPrefix;
    os_unfair_lock_unlock(&bootstrapLock);
    if (convert) return convert(path, NULL);
    NSString *input = @(path);
    if (!input || [prefix isEqual:@"/"] || [input isEqual:prefix] || [input hasPrefix:[prefix stringByAppendingString:@"/"]]) return strdup(path);
    return strdup([prefix stringByAppendingPathComponent:input].fileSystemRepresentation);
}

char *icli_rootfs_path(const char *path) {
    if (!path) return NULL;
    if (path[0] != '/') return strdup(path);
    os_unfair_lock_lock(&bootstrapLock);
    resolveBootstrapLocked();
    char *(*convert)(const char *, char *) = convertRoot;
    NSString *jb = bootstrapPrefix, *rootfs = rootfsPrefix;
    os_unfair_lock_unlock(&bootstrapLock);
    if (convert) return convert(path, NULL);
    NSString *input = @(path);
    if (!input) return strdup(path);
    if (![jb isEqual:@"/"] && [input hasPrefix:[jb stringByAppendingString:@"/"]]) return strdup([input substringFromIndex:jb.length].UTF8String);
    if ([rootfs isEqual:@"/"] || [input hasPrefix:[rootfs stringByAppendingString:@"/"]]) return strdup(path);
    return strdup([rootfs stringByAppendingPathComponent:input].fileSystemRepresentation);
}

char *icli_processes_json(void) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0)) return icli_system_json(@{@"error": @(strerror(errno))});
    length += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = calloc(1, length);
    if (!processes) return icli_system_json(@{@"error": @"process allocation failed"});
    if (sysctl(mib, 3, processes, &length, NULL, 0)) {
        int error = errno; free(processes); return icli_system_json(@{@"error": @(strerror(error))});
    }
    int (*pidPath)(int, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath");
    NSMutableArray *rows = [NSMutableArray array];
    for (size_t i = 0; i < length / sizeof(struct kinfo_proc); i++) {
        pid_t pid = processes[i].kp_proc.p_pid;
        char path[4096] = {0};
        if (pidPath) pidPath(pid, path, sizeof(path));
        NSString *name = icli_system_string(processes[i].kp_proc.p_comm, sizeof(processes[i].kp_proc.p_comm));
        [rows addObject:@{@"pid": @(pid), @"name": name, @"executable": icli_system_string(path, sizeof(path))}];
    }
    free(processes);
    return icli_system_json(@{@"processes": rows});
}

/// Kernel boot facts for proving a reboot happened: kern.boottime and the
/// per-boot session UUID that launchd regenerates on a userspace reboot.
char *icli_boot_info_json(void) {
    struct timeval boot = {0};
    size_t size = sizeof(boot);
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (sysctlbyname("kern.boottime", &boot, &size, NULL, 0) == 0) {
        info[@"boot_time"] = @((double)boot.tv_sec + boot.tv_usec / 1e6);
        info[@"uptime_seconds"] = @(NSProcessInfo.processInfo.systemUptime);
    }
    char session[64] = {0};
    size = sizeof(session) - 1;
    if (sysctlbyname("kern.bootsessionuuid", session, &size, NULL, 0) == 0) info[@"boot_session_uuid"] = icli_system_string(session, sizeof(session));
    return icli_system_json(info);
}

/// Read in chunks: CC_MD5 takes a 32-bit length, so one call over a mapped
/// file of 4 GiB or more would hash only the length modulo 2^32.
char *icli_file_md5(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    static const size_t chunk = 1 << 20;
    void *buffer = malloc(chunk);
    if (!buffer) { close(fd); return NULL; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5_CTX context; // dpkg's md5sums and Conffiles fields are MD5 by definition.
    CC_MD5_Init(&context);
    ssize_t count;
    while ((count = read(fd, buffer, chunk)) != 0) {
        if (count < 0) {
            if (errno == EINTR) continue;
            break;
        }
        CC_MD5_Update(&context, buffer, (CC_LONG)count);
    }
    CC_MD5_Final(digest, &context);
#pragma clang diagnostic pop
    free(buffer);
    close(fd);
    if (count < 0) return NULL;
    char hex[CC_MD5_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return strdup(hex);
}
