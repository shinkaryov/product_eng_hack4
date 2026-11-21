#!/usr/bin/env bash
# Generates iOS/Android platform folders around the existing lib/ (without overwriting it),
# adds iOS permission strings and installs dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter not found. Install it: brew install --cask flutter" >&2
  exit 1
fi

# Without --overwrite, flutter create keeps every existing file (lib/, pubspec.yaml, README, tests).
flutter create . --project-name familydoc --org ai.familydoc --platforms ios,android

PLIST=ios/Runner/Info.plist
set_key() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
}
set_key CFBundleDisplayName "FamilyDoc"
set_key NSCameraUsageDescription "FamilyDoc uses the camera to scan your documents."
set_key NSPhotoLibraryUsageDescription "FamilyDoc lets you add document photos from your library."

flutter pub get
echo
echo "Ready. Next: open -a Simulator && flutter run"
