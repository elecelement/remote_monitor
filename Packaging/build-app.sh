#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --force-resolved-versions --product GPUWorkbench
bin_dir=$(swift build -c release --show-bin-path)
mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
name='GPU 工作台.app'
app="$stage/$name"
res="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$res" "$stage/AppIcon.iconset"
install -m 755 "$bin_dir/GPUWorkbench" "$app/Contents/MacOS/GPUWorkbench"
install -m 644 Packaging/Info.plist "$app/Contents/Info.plist"
install -m 644 "$bin_dir/GPUWorkbench_WorkbenchCore.bundle/remote.py" "$res/remote.py"
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$res/SwiftTerm-LICENSE.txt"
ditto "$bin_dir/SwiftTerm_SwiftTerm.bundle" "$res/SwiftTerm_SwiftTerm.bundle"
swift Packaging/AppIcon.swift "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$res/AppIcon.icns"
codesign --force --sign - --options runtime --timestamp=none "$app"
codesign --verify --deep --strict "$app"
# Both directories live on the same filesystem. Swap the verified product into place.
python3 - "$app" "$PWD/dist/$name" <<'PY'
import ctypes
import os
import sys

source, destination = map(os.fsencode, sys.argv[1:])
if os.path.exists(destination):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renameatx_np(-2, source, -2, destination, 0x00000002):
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))
else:
    os.rename(source, destination)
PY
printf '%s\n' "$PWD/dist/$name"
