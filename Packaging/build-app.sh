#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --force-resolved-versions --product GPUWorkbench
bin_dir=$(swift build -c release --show-bin-path)
mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
name='GPU Workbench.app'
app="$stage/$name"
res="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$res" "$stage/AppIcon.iconset"
install -m 755 "$bin_dir/GPUWorkbench" "$app/Contents/MacOS/GPUWorkbench"
install -m 644 Packaging/Info.plist "$app/Contents/Info.plist"
for locale in en zh-Hans; do
    mkdir -p "$res/$locale.lproj"
    install -m 644 "Packaging/$locale.lproj/InfoPlist.strings" "$res/$locale.lproj/"
done
install -m 644 "$bin_dir/GPUWorkbench_WorkbenchCore.bundle/remote.py" "$res/remote.py"
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$res/SwiftTerm-LICENSE.txt"
ditto "$bin_dir/SwiftTerm_SwiftTerm.bundle" "$res/SwiftTerm_SwiftTerm.bundle"
swift Packaging/AppIcon.swift "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$res/AppIcon.icns"
codesign --force --sign - --options runtime --timestamp=none "$app"
codesign --verify --deep --strict "$app"
# Migrate the previous release in dist, then atomically replace it with the verified app.
python3 - "$app" "$PWD/dist/$name" <<'PY'
import ctypes
import os
import plistlib
import sys
from pathlib import Path

source, destination = map(os.fsencode, sys.argv[1:])
legacy = Path(sys.argv[2]).with_name("GPU 工作台.app")
if not os.path.lexists(destination) and legacy.is_dir() and not legacy.is_symlink():
    try:
        with (legacy / "Contents/Info.plist").open("rb") as file:
            info = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException):
        info = {}
    if isinstance(info, dict) and info.get("CFBundleIdentifier") == "local.gpuworkbench.desktop":
        os.rename(legacy, destination)
if os.path.exists(destination):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renameatx_np(-2, source, -2, destination, 0x00000002):
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))
else:
    os.rename(source, destination)
PY
printf '%s\n' "$PWD/dist/$name"
