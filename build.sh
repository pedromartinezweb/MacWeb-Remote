#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
build_root="${MACWEB_BUILD_ROOT:-$HOME/Library/Caches/MacWebRemote-build}"
configuration="${MACWEB_CONFIGURATION:-release}"
app_bundle="$build_root/MacWebRemote.app"
swift build --configuration "$configuration" --scratch-path "$build_root/SwiftPM" -j 4
bin_path="$(swift build --configuration "$configuration" --scratch-path "$build_root/SwiftPM" --show-bin-path)"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$build_root/AppIcon.iconset"
cp "$bin_path/MacWebRemote" "$app_bundle/Contents/MacOS/MacWebRemote"
cp Info.plist "$app_bundle/Contents/Info.plist"
cp LICENSE "$app_bundle/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto --norsrc --noextattr ThirdPartyLicenses "$app_bundle/Contents/Resources/ThirdPartyLicenses"
ditto --norsrc --noextattr Web "$app_bundle/Contents/Resources/Web"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$build_root/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" Assets/AppIcon.png --out "$build_root/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$build_root/AppIcon.iconset" -o "$app_bundle/Contents/Resources/AppIcon.icns"
sips -z 192 192 Assets/AppIcon.png --out "$app_bundle/Contents/Resources/Web/icon.png" >/dev/null
signing_identity="${MACWEB_SIGNING_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
    print "Development ad-hoc signature: macOS privacy grants may need renewal after rebuilding."
fi
codesign --force --sign "$signing_identity" --identifier local.pedro.MacWebRemote "$app_bundle"
codesign --verify --strict "$app_bundle"
print "Built app: $app_bundle"
