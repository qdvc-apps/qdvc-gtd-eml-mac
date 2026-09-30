#!/usr/bin/env bash
# Build "QDVC GTD EML.app" from the Swift package and ad-hoc sign it.
#
# No Apple Developer account is needed: ad-hoc signing ("Sign to Run
# Locally") is enough for the app to run on the Mac that built it.
#
#   scripts/build-app.sh              # release build into build/
#   scripts/build-app.sh --universal  # arm64 + x86_64 (needs full Xcode)
#   scripts/build-app.sh --install    # also copy to ~/Applications
set -euo pipefail

cd "$(dirname "$0")/.."

universal=0
install=0
for arg in "$@"; do
    case "$arg" in
        --universal) universal=1 ;;
        --install) install=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

build_args=(-c release --product QDVCGTDEML)
if [[ $universal -eq 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ${build_args[*]}"
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"

app="build/QDVC GTD EML.app"
echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/QDVCGTDEML" "$app/Contents/MacOS/QDVCGTDEML"
cp Resources/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
# App icon (regenerate with tools/make_icon.py; Info.plist names it AppIcon).
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --verbose=1 "$app"

if [[ $install -eq 1 ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/QDVC GTD EML.app"
    cp -R "$app" "$HOME/Applications/"
    echo "==> Installed to ~/Applications/QDVC GTD EML.app"
fi

echo "Done: $(pwd)/$app"
