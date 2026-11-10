#!/usr/bin/env bash
# Protocol self-check on the Mac (no iPhone needed).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -Onone -parse-as-library Iris/Protocol.swift Iris/Guide.swift Iris/Log.swift Iris/Intent.swift Tests/check.swift -o .build/check
.build/check
