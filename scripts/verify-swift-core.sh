#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p artifacts
# Uses only the system Swift compiler and SQLite; XCTest is not in every CLT install.
swiftc -I ios/CSQLite ios/Core/*.swift scripts/swift-check/main.swift -o artifacts/verify-swift-core
./artifacts/verify-swift-core
