#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/cache
xcrun swiftc -module-cache-path build/cache Sources/Core.swift Sources/LogReader.swift Sources/Tests.swift -o build/tests
build/tests
