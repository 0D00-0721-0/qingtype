#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${QINGTYPE_NOTARY_PROFILE:?请先配置 notarytool Keychain profile，并设置 QINGTYPE_NOTARY_PROFILE}"
image="${1:?用法：scripts/notarize-app.sh build/distribution/QingType-VERSION-ARCH.dmg}"
codesign --verify --strict "$image"
# No credentials are written into the source or shell arguments.
xcrun notarytool submit "$image" --keychain-profile "$QINGTYPE_NOTARY_PROFILE" --wait
xcrun stapler staple "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
(cd "$(dirname "$image")" && shasum -a 256 "$(basename "$image")" > "$(basename "$image").sha256")
