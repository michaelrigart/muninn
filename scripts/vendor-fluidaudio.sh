#!/usr/bin/env bash
# Vendors FluidAudio without its prebuilt NemoTextProcessing binary target.
# The binary is optional upstream (guarded by canImport) but SwiftPM downloads
# every binary artifact at resolution time, which the build environment blocks.
set -euo pipefail

version="${FLUIDAUDIO_VERSION:-v0.17.7}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/Vendor/FluidAudio"

if [[ -f "$dest/.vendored-$version" ]]; then
  exit 0
fi

rm -rf "$dest"
mkdir -p "$root/Vendor"
mkdir -p "$dest"
curl -fsSL "https://github.com/FluidInference/FluidAudio/archive/refs/tags/$version.tar.gz" \
  | tar -xz -C "$dest" --strip-components 1 --exclude "*/.claude*" --exclude "*/.github*" --exclude "*/Tests/*" --exclude "*/Examples/*"
rm -rf "$dest/Package@swift-6.2.swift" "$dest/Tests" "$dest/Examples" "$dest/Sources/FluidAudioCLI"

cat > "$dest/Package.swift" <<'MANIFEST'
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FluidAudio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FluidAudio", targets: ["FluidAudio"]),
    ],
    targets: [
        .target(
            name: "FluidAudio",
            dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"],
            path: "Sources/FluidAudio",
            exclude: ["ASR/Parakeet/Unified/benchmark.md"],
            resources: [.process("TTS/LuxTts/G2p/Resources")]
        ),
        .target(name: "FastClusterWrapper", path: "Sources/FastClusterWrapper", publicHeadersPath: "include"),
        .target(name: "MachTaskSelfWrapper", path: "Sources/MachTaskSelfWrapper", publicHeadersPath: "include"),
    ],
    cxxLanguageStandard: .cxx17
)
MANIFEST

touch "$dest/.vendored-$version"
