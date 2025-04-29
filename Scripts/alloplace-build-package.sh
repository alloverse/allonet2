#!/bin/bash
set -euxo pipefail # exit on error, on undefined, print each line, exit on pipe error

swift build -c release --disable-sandbox --product AlloPlace
mkdir -p .build/install
cp .build/release/AlloPlace .build/install/
cp -a .build/release/LiveKitWebRTC.framework .build/install/
codesign --timestamp --sign "Developer ID Application: Nevyn Bengtsson" .build/install/AlloPlace .build/install/LiveKitWebRTC.framework
ditto -c -k .build/install .build/AlloPlace.zip