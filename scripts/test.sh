#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -mmacosx-version-min=14.4 -fsanitize=address,undefined -g \
    -I Sources/AudioBridge/include Sources/AudioBridge/AudioBridge.m Tests/AudioTests.m \
    -framework Foundation -framework AppKit -framework CoreAudio -o .build/tests/audio-tests
.build/tests/audio-tests
swift build
