#pragma once
#import <Foundation/Foundation.h>
#include <libarchive/archive.h>

/// libarchive converts entry names into the calling thread's codeset. A
/// launchd daemon runs in the C locale, where a UTF-8 name such as
/// "What’s New.html" fails the header read, so every archive reader runs
/// inside this: `body` sees a UTF-8 LC_CTYPE on this thread only, and the
/// thread's previous locale is restored before it returns.
char *icli_archive_with_utf8_names(char *(^body)(void));

/// The listing row for one entry: its path, type name, size and permission bits.
NSDictionary *icli_archive_entry_info(struct archive_entry *entry, NSString *path);

/// Extracts every entry of an opened reader below `destination`, rejecting
/// paths, symlinks, and hard links that would leave it. Returns a failure
/// message or nil; `entries` (optional) receives one dictionary per entry.
/// `skip_mac_metadata` leaves out what a Mac adds when it zips a folder:
/// the top-level __MACOSX tree and AppleDouble "._name" regular files.
NSString *icli_archive_extract(
    struct archive *reader,
    NSString *destination,
    bool allow_absolute_symlinks,
    bool skip_mac_metadata,
    NSMutableArray *entries,
    NSUInteger *count,
    uint64_t *total
);
