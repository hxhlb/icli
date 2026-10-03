#import "IcliPrivate.h"
#import "ArchiveInternal.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#include <libarchive/archive.h>
#include <libarchive/archive_entry.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// A .deb is an ar(1) archive holding debian-binary, control.tar.* and
// data.tar.* (gzip, xz, zstd, bzip2, lzma or none). The small members are
// read into memory (capped); data.tar is streamed through a second reader
// fed from the first, so a large package never sits in memory whole.
static const int64_t kDebMemberLimit = 512LL * 1024 * 1024;

/// An entry name as a string, or nil when its bytes are not UTF-8. Callers
/// treat nil as a failure: `@(raw)` would be nil too, and a nil name thrown
/// into a literal or a string method raises instead of failing.
static NSString *entryName(const char *raw) {
    return raw ? [NSString stringWithUTF8String:raw] : @"";
}

/// The current member of an ar reader, as the source of a nested reader.
typedef struct {
    struct archive *outer;
    char buffer[65536];
} NestedMember;

static la_ssize_t readNestedMember(struct archive *reader, void *context, const void **out) {
    NestedMember *member = context;
    *out = member->buffer;
    la_ssize_t bytes = archive_read_data(member->outer, member->buffer, sizeof(member->buffer));
    if (bytes < 0)
        archive_set_error(reader, EIO, "%s", archive_error_string(member->outer) ?: "deb member could not be read");
    return bytes;
}

/// A tar reader over the ar reader's current member. Free the reader before
/// `member`, and do not advance `outer` while the reader is in use.
static struct archive *nestedTarReader(struct archive *outer, NestedMember **member, NSString **failure) {
    *member = calloc(1, sizeof(NestedMember));
    struct archive *reader = *member ? archive_read_new() : NULL;
    if (!reader) {
        free(*member);
        *member = NULL;
        *failure = @"archive allocation failed";
        return NULL;
    }
    (*member)->outer = outer;
    archive_read_support_format_tar(reader);
    archive_read_support_filter_all(reader);
    if (archive_read_open(reader, *member, NULL, readNestedMember, NULL) != ARCHIVE_OK) {
        *failure = @(archive_error_string(reader) ?: "invalid tar member");
        archive_read_free(reader);
        free(*member);
        *member = NULL;
        return NULL;
    }
    return reader;
}

static NSData *readMember(struct archive *reader, struct archive_entry *entry, NSString **failure) {
    int64_t size = archive_entry_size(entry);
    if (size < 0 || size > kDebMemberLimit) { *failure = @"deb member exceeds 512 MiB"; return nil; }
    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)size];
    char buffer[65536];
    la_ssize_t bytes;
    while ((bytes = archive_read_data(reader, buffer, sizeof(buffer))) > 0)
        [data appendBytes:buffer length:(NSUInteger)bytes];
    if (bytes < 0) { *failure = @(archive_error_string(reader) ?: "deb member could not be read"); return nil; }
    return data;
}

static struct archive *tarReader(NSData *data, NSString **failure) {
    struct archive *reader = archive_read_new();
    if (!reader) { *failure = @"archive allocation failed"; return NULL; }
    archive_read_support_format_tar(reader);
    archive_read_support_filter_all(reader);
    if (archive_read_open_memory(reader, data.bytes, data.length) != ARCHIVE_OK) {
        *failure = @(archive_error_string(reader) ?: "invalid tar member");
        archive_read_free(reader);
        return NULL;
    }
    return reader;
}

/// Control fields, multi-line values joined with newlines; `order` receives the field names as written.
static NSDictionary *parseControl(NSString *text, NSMutableArray *order) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    NSString *current = nil;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) { if (fields.count) break; continue; }
        if ([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) {
            if (current)
                fields[current] = [fields[current] stringByAppendingFormat:@"\n%@", [line substringFromIndex:1]];
            continue;
        }
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        current = [line substringToIndex:colon.location];
        fields[current] = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        [order addObject:current];
    }
    return fields;
}

/// Lists a tar member; when `destination` is set the entries are extracted
/// there too. `texts` receives the top-level regular files of up to 1 MiB.
static NSString *walkTarReader(
    struct archive *reader,
    NSString *destination,
    NSMutableArray *entries,
    NSMutableDictionary *texts,
    bool absoluteLinks
) {
    NSString *failure = nil;
    if (destination) {
        NSUInteger count = 0;
        uint64_t total = 0;
        failure = icli_archive_extract(reader, destination, absoluteLinks, false, entries, &count, &total);
    } else {
        struct archive_entry *entry;
        int status;
        while ((status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
            NSString *path = entryName(archive_entry_pathname(entry));
            if (!path) { failure = @"deb contains an entry name that is not UTF-8"; break; }
            mode_t type = archive_entry_filetype(entry);
            [entries addObject:icli_archive_entry_info(entry, path)];
            // Control files sit at the top level. A nested file must not
            // stand in for one, and "list" is the installed-file list icli
            // writes itself, so a member by that name is never taken.
            NSString *name = path.lastPathComponent;
            NSString *top = [path hasPrefix:@"./"] ? [path substringFromIndex:2] : path;
            BOOL topLevel = [top isEqualToString:name] && ![name isEqualToString:@"list"];
            if (texts && topLevel && type == AE_IFREG && archive_entry_size(entry) <= 1024 * 1024) {
                NSData *body = readMember(reader, entry, &failure);
                if (failure) break;
                texts[name] = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]
                    ?: [body base64EncodedStringWithOptions:0];
            }
        }
        if (!failure && status != ARCHIVE_EOF) failure = @(archive_error_string(reader) ?: "invalid tar member");
    }
    return failure;
}

static NSString *walkTar(
    NSData *data,
    NSString *destination,
    NSMutableArray *entries,
    NSMutableDictionary *texts,
    bool absoluteLinks
) {
    NSString *failure = nil;
    struct archive *reader = tarReader(data, &failure);
    if (!reader) return failure;
    failure = walkTarReader(reader, destination, entries, texts, absoluteLinks);
    archive_read_free(reader);
    return failure;
}

static char *readDeb(const char *path, const char *destination) {
    struct archive *reader = archive_read_new();
    if (!reader) return icli_json(@{@"error": @"archive allocation failed"});
    archive_read_support_format_ar(reader);
    NSString *failure = nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableArray *dataEntries = [NSMutableArray array];
    NSMutableArray *controlEntries = [NSMutableArray array];
    NSMutableDictionary *controlTexts = [NSMutableDictionary dictionary];
    NSString *root = destination ? @(destination) : nil;
    if (archive_read_open_filename(reader, path, 65536) != ARCHIVE_OK)
        failure = @(archive_error_string(reader) ?: "could not open deb");
    struct archive_entry *entry;
    int status = ARCHIVE_OK;
    while (!failure && (status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        NSString *name = entryName(archive_entry_pathname(entry));
        if (!name) {
            failure = @"deb contains a member name that is not UTF-8";
        } else if ([name hasPrefix:@"debian-binary"]) {
            NSData *body = readMember(reader, entry, &failure);
            NSString *version = [[[NSString alloc] initWithData:body ?: NSData.data encoding:NSUTF8StringEncoding]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!failure && ![version isEqualToString:@"2.0"])
                failure = [@"unsupported deb format version: " stringByAppendingString:version ?: @""];
            result[@"format"] = version ?: @"";
        } else if ([name hasPrefix:@"control.tar"]) {
            result[@"control_member"] = name;
            NSData *body = readMember(reader, entry, &failure);
            if (!failure) failure = walkTar(body, nil, controlEntries, controlTexts, false);
            if (!failure && root) {
                NSString *debian = [root stringByAppendingPathComponent:@"DEBIAN"];
                NSError *error = nil;
                if (![NSFileManager.defaultManager createDirectoryAtPath:debian withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:&error]) failure = error.localizedDescription;
                else failure = walkTar(body, debian, nil, nil, false);
            }
        } else if ([name hasPrefix:@"data.tar"]) {
            result[@"data_member"] = name;
            NestedMember *member = NULL;
            struct archive *tar = nestedTarReader(reader, &member, &failure);
            if (tar) {
                failure = walkTarReader(tar, root, dataEntries, nil, true);
                archive_read_free(tar);
                free(member);
            }
        } else {
            failure = [@"unexpected deb member: " stringByAppendingString:name];
        }
    }
    if (!failure && status != ARCHIVE_EOF) failure = @(archive_error_string(reader) ?: "invalid deb archive");
    archive_read_free(reader);
    if (!failure && !controlTexts[@"control"]) failure = @"deb has no control file";
    if (!failure && !result[@"data_member"]) failure = @"deb has no data member";
    if (failure) return icli_json(@{@"error": failure});
    NSMutableArray *order = [NSMutableArray array];
    NSDictionary *fields = parseControl(controlTexts[@"control"], order);
    if (!fields[@"Package"] || !fields[@"Version"])
        return icli_json(@{@"error": @"deb control lacks Package or Version"});
    result[@"control"] = fields;
    result[@"control_order"] = order;
    result[@"control_files"] = controlEntries;
    result[@"control_texts"] = controlTexts;
    result[@"scripts"] = [controlTexts.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF IN %@", @[@"preinst", @"postinst", @"prerm", @"postrm"]]];
    result[@"files"] = dataEntries;
    result[@"extracted"] = root ? @YES : @NO;
    if (root) result[@"destination"] = root;
    return icli_json(result);
}

char *icli_deb_read_json(const char *path, const char *destination) {
    return icli_archive_with_utf8_names(^{ return readDeb(path, destination); });
}

/// Archive path as dpkg records it in info/*.list: "./usr/bin/x" and
/// "usr/bin/x" both become "/usr/bin/x"; the root entry is "/.".
static NSString *recordedPath(const char *raw) {
    NSString *path = entryName(raw);
    if (!path) return nil;
    if ([path hasPrefix:@"./"]) path = [path substringFromIndex:1];
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    path = path.stringByStandardizingPath;
    return path.length > 1 ? path : @"/.";
}

static NSString *applyEntryMetadata(NSString *destination, struct archive_entry *entry) {
    mode_t mode = archive_entry_perm(entry) & 07777;
    if (archive_entry_filetype(entry) != AE_IFLNK && chmod(destination.fileSystemRepresentation, mode ?: 0644) != 0)
        return @(strerror(errno));
    if (geteuid() == 0 && lchown(destination.fileSystemRepresentation, (uid_t)archive_entry_uid(entry), (gid_t)archive_entry_gid(entry)) != 0) return @(strerror(errno));
    return nil;
}

/// Unpacks data.tar members onto the filesystem the way dpkg does: every
/// regular file and symlink is written as `<dest>.dpkg-new` and renamed over
/// the destination. Paths are prefixed with `prefix` (empty on rootless,
/// where archives already carry /var/jb). Paths in `skip` are recorded but
/// not written (existing conffiles).
static char *unpackDeb(const char *path, const char *prefix, const char **skip, int skip_count) {
    NSMutableSet *skipped = [NSMutableSet set];
    for (int i = 0; i < skip_count; i++) if (skip[i]) [skipped addObject:@(skip[i])];
    NSMutableArray *installed = [NSMutableArray array], *kept = [NSMutableArray array];
    NSString *failure = nil;
    NSString *root = prefix && *prefix ? @(prefix) : @"";
    struct archive *ar = archive_read_new();
    if (!ar) return icli_json(@{@"error": @"archive allocation failed"});
    archive_read_support_format_ar(ar);
    if (archive_read_open_filename(ar, path, 65536) != ARCHIVE_OK)
        failure = @(archive_error_string(ar) ?: "could not open deb");
    struct archive_entry *member;
    struct archive *tar = NULL;
    NestedMember *source = NULL;
    while (!failure && !tar && archive_read_next_header(ar, &member) == ARCHIVE_OK) {
        const char *raw = archive_entry_pathname(member);
        if (raw && strncmp(raw, "data.tar", 8) == 0) tar = nestedTarReader(ar, &source, &failure);
    }
    if (!failure && !tar) failure = @"deb has no data member";
    struct archive_entry *entry;
    int status = ARCHIVE_OK;
    while (!failure && tar && (status = archive_read_next_header(tar, &entry)) == ARCHIVE_OK) {
        NSString *relative = recordedPath(archive_entry_pathname(entry));
        if (!relative) { failure = @"deb contains an entry name that is not UTF-8"; break; }
        if ([relative.pathComponents containsObject:@".."]) { failure = @"deb contains an unsafe path"; break; }
        [installed addObject:relative];
        if ([relative isEqualToString:@"/."]) continue;
        NSString *destination = [root stringByAppendingString:relative];
        mode_t type = archive_entry_filetype(entry);
        if ([skipped containsObject:relative]) { [kept addObject:relative]; continue; }
        struct stat existing;
        BOOL exists = lstat(destination.fileSystemRepresentation, &existing) == 0;
        NSError *error = nil;
        if (type == AE_IFDIR) {
            // /var and friends are symlinks to directories on iOS; dpkg accepts those too.
            struct stat resolved;
            if (stat(destination.fileSystemRepresentation, &resolved) == 0 && S_ISDIR(resolved.st_mode)) continue;
            if (exists) {
                failure = [NSString stringWithFormat:@"%@ exists and is not a directory", destination];
                break;
            }
            if (![NSFileManager.defaultManager createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(archive_entry_perm(entry) & 07777 ?: 0755)} error:&error]) { failure = error.localizedDescription; break; }
            failure = applyEntryMetadata(destination, entry);
            continue;
        }
        if (exists && S_ISDIR(existing.st_mode)) {
            failure = [NSString stringWithFormat:@"%@ is a directory but the package ships a file", destination];
            break;
        }
        if (![NSFileManager.defaultManager createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:&error]) { failure = error.localizedDescription; break; }
        NSString *staging = [destination stringByAppendingString:@".dpkg-new"];
        unlink(staging.fileSystemRepresentation);
        const char *hardlink = archive_entry_hardlink(entry);
        if (hardlink) {
            // A tar hard link reads as an empty regular file; link it to the
            // file an earlier entry installed, as dpkg does.
            NSString *linked = recordedPath(hardlink);
            if (!linked || [linked.pathComponents containsObject:@".."] || [linked isEqualToString:@"/."]) {
                failure = [NSString stringWithFormat:@"%@: unsafe hard link", relative];
                break;
            }
            NSString *original = [root stringByAppendingString:linked];
            if (link(original.fileSystemRepresentation, staging.fileSystemRepresentation) != 0) {
                failure = [NSString stringWithFormat:@"hard link %@: %s", destination, strerror(errno)];
                break;
            }
        } else if (type == AE_IFLNK) {
            const char *target = archive_entry_symlink(entry);
            if (!target || !*target || symlink(target, staging.fileSystemRepresentation) != 0) {
                failure = [NSString stringWithFormat:@"symlink %@: %s", destination, strerror(errno)];
                break;
            }
        } else if (type == AE_IFREG) {
            int fd = open(staging.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (fd < 0) { failure = [NSString stringWithFormat:@"%@: %s", destination, strerror(errno)]; break; }
            char buffer[65536];
            la_ssize_t bytes;
            while ((bytes = archive_read_data(tar, buffer, sizeof(buffer))) > 0) {
                if (write(fd, buffer, (size_t)bytes) != bytes) {
                    failure = [NSString stringWithFormat:@"%@: %s", destination, strerror(errno)];
                    break;
                }
            }
            if (bytes < 0 && !failure) failure = @(archive_error_string(tar) ?: "deb data could not be read");
            if (!failure && fsync(fd) != 0) failure = @(strerror(errno));
            close(fd);
            if (failure) { unlink(staging.fileSystemRepresentation); break; }
        } else {
            failure = [NSString stringWithFormat:@"%@: unsupported file type", relative];
            break;
        }
        failure = applyEntryMetadata(staging, entry);
        if (!failure && rename(staging.fileSystemRepresentation, destination.fileSystemRepresentation) != 0)
            failure = [NSString stringWithFormat:@"%@: %s", destination, strerror(errno)];
        if (failure) unlink(staging.fileSystemRepresentation);
    }
    if (!failure && tar && status != ARCHIVE_EOF) failure = @(archive_error_string(tar) ?: "invalid data member");
    if (tar) archive_read_free(tar);
    free(source);
    archive_read_free(ar);
    if (failure) return icli_json(@{@"error": failure, @"installed": installed});
    return icli_json(@{@"installed": installed, @"kept": kept});
}

char *icli_deb_unpack_json(const char *path, const char *prefix, const char **skip, int skip_count) {
    return icli_archive_with_utf8_names(^{ return unpackDeb(path, prefix, skip, skip_count); });
}

/// Reads one small entry from a tar file (optionally compressed), for
/// comparing a bundled BaseBin's `basebin/.version` without extracting it.
static char *tarEntryText(const char *path, const char *entry_name) {
    struct archive *reader = archive_read_new();
    if (!reader) return NULL;
    archive_read_support_format_tar(reader);
    archive_read_support_filter_all(reader);
    char *text = NULL;
    if (archive_read_open_filename(reader, path, 65536) == ARCHIVE_OK) {
        struct archive_entry *entry;
        while (archive_read_next_header(reader, &entry) == ARCHIVE_OK) {
            NSString *name = entryName(archive_entry_pathname(entry)).stringByStandardizingPath;
            if (!name) continue;
            if ([name hasPrefix:@"./"]) name = [name substringFromIndex:2];
            if (![name isEqualToString:[NSString stringWithUTF8String:entry_name]] || archive_entry_size(entry) > 65536) continue;
            NSString *failure = nil;
            NSData *body = readMember(reader, entry, &failure);
            if (body) text = strndup(body.bytes, body.length);
            break;
        }
    }
    archive_read_free(reader);
    return text;
}

char *icli_tar_entry_text(const char *path, const char *entry_name) {
    return icli_archive_with_utf8_names(^{ return tarEntryText(path, entry_name); });
}
