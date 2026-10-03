#pragma once
#import <Foundation/Foundation.h>
#include <string.h>

/// A malloc'd JSON string for this module's `*_json` functions, or NULL when
/// the value cannot be serialized. The validity check comes first because
/// NSJSONSerialization throws, rather than failing, on a NaN or infinite
/// number, and a host such as a Swift daemon cannot catch that exception.
static inline char *icli_system_json(id value) {
    if (![NSJSONSerialization isValidJSONObject:value]) return NULL;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

/// A C string from the kernel or another process, decoded as UTF-8 and, when
/// the bytes are not UTF-8 (a name the kernel cut mid-character, say), as
/// Latin-1, which accepts any bytes. Never nil, so it is safe in a literal.
static inline NSString *icli_system_string(const char *bytes, size_t limit) {
    if (!bytes) return @"";
    size_t length = strnlen(bytes, limit);
    return [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding]
        ?: @"";
}

/// A number JSON can carry: a non-finite double becomes its description.
static inline id icli_system_double(double value) {
    return isfinite(value) ? @(value) : [NSString stringWithFormat:@"%f", value];
}
