#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
xcodegen generate --quiet
route="${1:-simulator}"
prototype_build="${2:-1}"
if [[ "$route" == "project" ]]; then
  open OrbitContextPrototype.xcodeproj
  exit
fi
sdk=iphonesimulator
if [[ "$route" == "device" ]]; then sdk=iphoneos; fi
xcodebuild -quiet -project OrbitContextPrototype.xcodeproj -scheme OrbitContextPrototype \
  -sdk "$sdk" -destination "generic/platform=$([[ "$sdk" == "iphoneos" ]] && print iOS || print 'iOS Simulator')" \
  -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO "CURRENT_PROJECT_VERSION=$prototype_build" build
if [[ "$route" == "device" ]]; then
  rm -rf build/ipa/Payload
  mkdir -p build/ipa/Payload
  ditto build/Build/Products/Debug-iphoneos/OrbitContextPrototype.app build/ipa/Payload/OrbitContextPrototype.app
  (cd build/ipa && ditto -c -k --norsrc --keepParent Payload ../OrbitContextPrototype-unsigned.ipa)
  print "Unsigned SideStore candidate: $PWD/build/OrbitContextPrototype-unsigned.ipa"
else
  print "Simulator app: $PWD/build/Build/Products/Debug-iphonesimulator/OrbitContextPrototype.app"
  print 'Install/launch on a booted iPad simulator with simctl, or use ./run.sh project.'
fi
