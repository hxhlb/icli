#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Host-side regression for archive names in the C locale, deb safety checks
# and the JSON guards: compiles the real Archive.m and Deb.m against the macOS
# slice of the pinned libarchive.
[ -d .build/swiftpm/artifacts ] || swift package --scratch-path .build/swiftpm resolve
framework="$(find .build/swiftpm/artifacts -path '*macos-arm64_x86_64/libarchive.framework' -type d | head -n 1)"
[ -n "$framework" ] || { echo 'libarchive macOS slice not found; run make resolve' >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/include/libarchive"
cp "$framework/Headers/archive.h" "$framework/Headers/archive_entry.h" "$work/include/libarchive/"

# A deb whose data member is PAX with a UTF-8 path, like dpkg-deb builds.
name='What’s New 中文.txt'
mkdir -p "$work/deb/control" "$work/deb/data/var/jb/usr/share/icli-locale-test"
printf 'Package: dev.owngoal.icli.localetest\nVersion: 1.0\nArchitecture: iphoneos-arm64\n' > "$work/deb/control/control"
printf 'unicode deb\n' > "$work/deb/data/var/jb/usr/share/icli-locale-test/$name"
printf '2.0\n' > "$work/deb/debian-binary"
(cd "$work/deb/control" && LC_ALL=en_US.UTF-8 bsdtar --format pax -czf ../control.tar.gz ./control)
(cd "$work/deb/data" && LC_ALL=en_US.UTF-8 bsdtar --format pax -czf ../data.tar.gz ./var)
(cd "$work/deb" && ar -rcS test.deb debian-binary control.tar.gz data.tar.gz)

# A deb with a hard link in data.tar, and control members that must not be
# taken as control files: "list" (icli's own file list) and a nested postinst.
mkdir -p "$work/links/control/sub" "$work/links/data/var/jb/usr/bin"
printf 'Package: dev.owngoal.icli.linktest\nVersion: 1.0\nArchitecture: iphoneos-arm64\n' > "$work/links/control/control"
printf '/etc/passwd\n' > "$work/links/control/list"
printf '#!/bin/sh\n' > "$work/links/control/sub/postinst"
printf 'linked tool\n' > "$work/links/data/var/jb/usr/bin/tool"
ln "$work/links/data/var/jb/usr/bin/tool" "$work/links/data/var/jb/usr/bin/alias"
(cd "$work/links/control" && bsdtar -czf ../control.tar.gz ./control ./list ./sub)
(cd "$work/links/data" && bsdtar -czf ../data.tar.gz ./var)
cp "$work/deb/debian-binary" "$work/links/"
(cd "$work/links" && ar -rcS links.deb debian-binary control.tar.gz data.tar.gz)

# A deb whose data.tar plants an absolute symlink and then writes through it.
mkdir -p "$work/escape/link" "$work/escape/file/a/x/y" "$work/outside"
ln -s "$work/outside" "$work/escape/link/a"
printf 'escaped\n' > "$work/escape/file/a/x/y/file"
(cd "$work/escape/link" && bsdtar -cf ../link.tar ./a)
(cd "$work/escape/file" && bsdtar -cf ../file.tar ./a/x/y/file)
(cd "$work/escape" && bsdtar -czf data.tar.gz @link.tar @file.tar)
cp "$work/deb/control.tar.gz" "$work/deb/debian-binary" "$work/escape/"
(cd "$work/escape" && ar -rcS escape.deb debian-binary control.tar.gz data.tar.gz)

for source in Archive Deb; do
  xcrun clang -fobjc-arc -fblocks -Wall -Wextra -I"$work/include" \
    -ISources/IcliPrivate/include -ISources/IcliSystemPrivate/include -ISources/IcliLaunchPrivate/include \
    -c "Sources/IcliPrivate/$source.m" -o "$work/$source.o"
done
xcrun swiftc -swift-version 6 -module-cache-path "$work/modules" \
  -import-objc-header Tests/ArchiveLocale/Bridge.h Tests/ArchiveLocale/main.swift Sources/IcliSystem/JSONSafe.swift \
  "$work/Archive.o" "$work/Deb.o" "$framework/Versions/A/libarchive" \
  -framework Foundation -lz -lbz2 -liconv -lxml2 -o "$work/archive-locale-tests"
"$work/archive-locale-tests" "$work/deb/test.deb" "$work/links/links.deb" "$work/escape/escape.deb" "$work/outside"
