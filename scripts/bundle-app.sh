#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Muninn.app"

"$root/scripts/vendor-fluidaudio.sh"
"$root/scripts/swiftpm.sh" build -c release --product Muninn --package-path "$root"
bin="$("$root/scripts/swiftpm.sh" build -c release --show-bin-path --package-path "$root")"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Muninn" "$app/Contents/MacOS/Muninn"
cp "$root/scripts/Info.plist" "$app/Contents/Info.plist"
for bundle in "$bin"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$app/Contents/Resources/"
done

if [[ "${MUNINN_SIGN_IDENTITY:--}" == "-" ]]; then
  echo "warning: signing ad hoc; macOS permissions and Little Snitch rules will be asked again after each rebuild (set MUNINN_SIGN_IDENTITY to keep them)" >&2
fi

codesign --force --options runtime --entitlements "$root/scripts/Muninn.entitlements" --sign "${MUNINN_SIGN_IDENTITY:--}" "$app"
codesign --verify --verbose "$app"
