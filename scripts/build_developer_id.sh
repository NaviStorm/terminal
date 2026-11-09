#!/bin/sh
# Compile la Release Developer ID dans le dossier DerivedData indiqué.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xcodebuild -project "$project_dir/mTerm.xcodeproj" -scheme mTerm \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$1" \
    ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" build
