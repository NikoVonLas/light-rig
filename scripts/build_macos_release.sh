#!/bin/bash
# Build the same signed Sparkle feed and universal DMG locally and on GitHub.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tag=${1:?expected vMAJOR.MINOR.PATCH}
repo=${2:?expected GitHub release repository (owner/name)}
output=${3:?expected output directory}
[[ $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "Invalid stable release tag: $tag" >&2; exit 1; }
[[ $repo =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid release repository" >&2; exit 1; }
key=${SPARKLE_PRIVATE_KEY:?missing Sparkle signing seed}
unset SPARKLE_PRIVATE_KEY
mkdir -p "$output"
output=$(cd "$output" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cache="$root/macos/.build/distribution"
mkdir -p "$cache"
export CLANG_MODULE_CACHE_PATH="$cache/clang"

# Use the exact same framework and signing tools from the upstream release.
tools="$work/sparkle"
mkdir "$tools"
archive=${SPARKLE_ARCHIVE:-"$work/Sparkle.tar.xz"}
if [[ -z ${SPARKLE_ARCHIVE:-} ]]; then
    curl --fail --location --silent --show-error --retry 3 \
        https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz -o "$archive"
fi
echo "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  $archive" | shasum -a 256 -c -
tar -xf "$archive" -C "$tools"
# generate_keys exports a base64-encoded 32-byte Ed25519 seed.
public_key=$(printf '%s' "$key" | swift -module-cache-path "$cache/modules" -e '
import Foundation
import CryptoKit
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let seed = Data(base64Encoded: input, options: .ignoreUnknownCharacters), seed.count == 32 else { exit(1) }
print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())
')
version=${tag#v}
app="$work/image/Canon Rig.app"
mkdir -p "$app/Contents/"{Frameworks,MacOS,Resources} "$work/feed"
for arch in arm64 x86_64; do
    args=(--package-path "$root/macos" --configuration release --product CanonRig
          --build-system native --arch "$arch" --scratch-path "$cache/$arch"
          --disable-sandbox --cache-path "$cache/swift" --config-path "$cache/config" --security-path "$cache/security"
          -Xswiftc -module-cache-path -Xswiftc "$cache/modules"
          -Xswiftc -DCANON_RIG_UPDATES -Xswiftc -F -Xswiftc "$tools"
          -Xlinker -F -Xlinker "$tools" -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
    swift build "${args[@]}"
    bin=$(swift build "${args[@]}" --show-bin-path)
    cp "$bin/CanonRig" "$work/CanonRig-$arch"
done
exe="$app/Contents/MacOS/CanonRig"
lipo -create "$work/CanonRig-arm64" "$work/CanonRig-x86_64" -output "$exe"
ditto "$tools/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$root/macos/THIRD_PARTY_NOTICES.md" "$tools/LICENSE" "$app/Contents/Resources/"
plist="$app/Contents/Info.plist"
cp "$root/macos/Support/Info.plist" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -insert SUFeedURL -string "https://github.com/$repo/releases/latest/download/appcast.xml" "$plist"
plutil -insert SUPublicEDKey -string "$public_key" "$plist"
plutil -insert SURequireSignedFeed -bool YES "$plist"
plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$plist"
plutil -insert SUEnableAutomaticChecks -bool YES "$plist"
plutil -insert SUAutomaticallyUpdate -bool YES "$plist"
plutil -insert SUScheduledCheckInterval -integer 3600 "$plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict --all-architectures "$app"
ln -s /Applications "$work/image/Applications"
name="Canon-Rig-$version.dmg"
hdiutil create -fs HFS+ -volname "Canon Rig" -srcfolder "$work/image" -format UDZO "$work/feed/$name"
hdiutil verify "$work/feed/$name"
printf '%s' "$key" | "$tools/bin/generate_appcast" --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$repo/releases/download/$tag/" "$work/feed"
feed="$work/feed/appcast.xml"
signature=$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$feed")
test "$(xmllint --xpath 'string(//enclosure/@url)' "$feed")" = "https://github.com/$repo/releases/download/$tag/$name"
printf '%s' "$key" | "$tools/bin/sign_update" --ed-key-file - --verify "$feed"
printf '%s' "$key" | "$tools/bin/sign_update" --ed-key-file - --verify "$work/feed/$name" "$signature"
cp "$work/feed/$name" "$feed" "$output/"
