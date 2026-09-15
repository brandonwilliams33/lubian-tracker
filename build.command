#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/cache dist/炉边记牌器.app/Contents/MacOS
for arch in arm64 x86_64; do
  xcrun swiftc -O -target "$arch-apple-macosx13.0" -module-cache-path build/cache Sources/Core.swift Sources/LogReader.swift Sources/Overlay.swift Sources/Tavern.swift Sources/App.swift -o "build/Lubian-$arch"
done
lipo -create build/Lubian-arm64 build/Lubian-x86_64 -output dist/炉边记牌器.app/Contents/MacOS/Lubian
cp Info.plist dist/炉边记牌器.app/Contents/Info.plist
codesign --force --deep --sign - dist/炉边记牌器.app
ditto -c -k --sequesterRsrc --keepParent dist/炉边记牌器.app dist/炉边记牌器-Mac.zip
print '完成：dist/炉边记牌器-Mac.zip'
