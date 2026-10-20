#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -f OrbitContextPrototype.xcodeproj/project.pbxproj || project.yml -nt OrbitContextPrototype.xcodeproj/project.pbxproj ]]; then
  xcodegen generate --quiet
fi
route="${1:-simulator}"
if [[ "$route" == "project" ]]; then
  open OrbitContextPrototype.xcodeproj
  exit
fi
sdk=iphonesimulator
if [[ "$route" == "device" ]]; then sdk=iphoneos; fi
xcodebuild -quiet -project OrbitContextPrototype.xcodeproj -scheme OrbitContextPrototype \
  -sdk "$sdk" -destination "generic/platform=$([[ "$sdk" == "iphoneos" ]] && print iOS || print 'iOS Simulator')" \
  -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
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
