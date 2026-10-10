#!/bin/bash
# Switches an SPM Package.swift from the published remote binary target to the
# locally built XCFramework, so apps consuming rive_native via Swift Package
# Manager link the symbols that were just built instead of the last release.
#
# Run ./build_xcframework.sh <platform> first: it places the framework at
# <platform>/rive_native/Frameworks/RiveNative_<platform>.xcframework.
#
# Usage: ./spm_use_local_binary.sh <ios|macos|all>
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"

use_local() {
    local platform="$1"
    local package_swift="$PACKAGE_DIR/$platform/rive_native/Package.swift"
    local framework="$PACKAGE_DIR/$platform/rive_native/Frameworks/RiveNative_${platform}.xcframework"

    if [[ ! -d "$framework" ]]; then
        echo "Error: $framework not found."
        echo "Run: ./build_xcframework.sh $platform"
        exit 1
    fi

    python3 - "$package_swift" "$platform" <<'PYEOF'
import re
import sys

path, platform = sys.argv[1], sys.argv[2]
source = open(path).read()
pattern = re.compile(
    r'url: "[^"]*RiveNative_' + platform + r'\.xcframework\.zip",\s*\n'
    r'(\s*)checksum: riveNativeChecksum')
replacement = 'path: "Frameworks/RiveNative_' + platform + '.xcframework"'
updated, count = pattern.subn(replacement, source)
if count == 0:
    if re.search(r'^\s*path: "Frameworks/RiveNative_' + platform + r'\.xcframework"',
                 source, re.MULTILINE):
        print(f'{path} already uses the local binary.')
        sys.exit(0)
    sys.exit(f'Error: no remote binary target found in {path}')
if count > 1:
    sys.exit(f'Error: expected one remote binary target in {path}, found {count}')
open(path, 'w').write(updated)
print(f'{path} now uses the local Frameworks/RiveNative_{platform}.xcframework')
PYEOF
}

restore() {
    local platform="$1"
    git -C "$PACKAGE_DIR" checkout -- "$platform/rive_native/Package.swift"
    echo "$platform/rive_native/Package.swift restored to the committed form."
}

case "$1" in
ios | macos)
    if [[ "$2" == "restore" ]]; then
        restore "$1"
    else
        use_local "$1"
    fi
    ;;
all)
    if [[ "$2" == "restore" ]]; then
        restore ios
        restore macos
    else
        use_local ios
        use_local macos
    fi
    ;;
*)
    echo "Usage: $0 <ios|macos|all> [restore]"
    exit 1
    ;;
esac
