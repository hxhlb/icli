#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Host-side regression for the paths launchd reads from a plist and RootHide
# launchctl's rewrite of them: compiles the pure LaunchdPlistPaths.swift on
# its own, so it needs nothing from the device or the package build.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -swift-version 6 -module-cache-path "$work/modules" \
  Tests/LaunchdPlistPaths/main.swift Sources/IcliSystem/LaunchdPlistPaths.swift \
  -o "$work/launchd-plist-paths-tests"
"$work/launchd-plist-paths-tests"
