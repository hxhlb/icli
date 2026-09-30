#pragma once
#include <zlib.h>
#include <locale.h>
#include <xlocale.h>
#include <langinfo.h>
#include <stdlib.h>

// Linked against the real Sources/IcliPrivate/Archive.m and Deb.m.
char *icli_extract_ipa_json(const char *source, const char *destination);
char *icli_deb_read_json(const char *path, const char *destination);
char *icli_deb_unpack_json(const char *path, const char *prefix, const char **skip, int skip_count);
char *icli_tar_entry_text(const char *path, const char *entry_name);
char *icli_archive_with_utf8_names(char *(^body)(void));
