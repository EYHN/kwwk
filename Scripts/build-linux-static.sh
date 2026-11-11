#!/usr/bin/env bash
# Build a fully static (musl) Linux `kwwk` with the Swift Static Linux SDK and
# package it as `dist/kwwk-linux-<arch>.tar.gz`: the binary plus the resource
# bundle it loads from beside itself. The result runs on any x86_64/aarch64
# Linux (glibc or musl) with no Swift runtime installed.
#
# Run inside an official `swift:<version>` image (CI does); the matching
# static SDK is downloaded for whatever toolchain is installed.
#
#   Scripts/build-linux-static.sh [x86_64|aarch64]
set -euo pipefail

arch="${1:-x86_64}"
sdk_id="${arch}-swift-linux-musl"

# "Swift version 6.1.2 (swift-6.1.2-RELEASE)" -> swift-6.1.2-RELEASE
toolchain="$(swift --version 2>&1 | sed -n 's/.*(\(swift-[0-9.]*-RELEASE\)).*/\1/p' | head -n1)"
if [[ -z "$toolchain" ]]; then
    echo "cannot determine a release toolchain from: $(swift --version 2>&1 | head -n1)" >&2
    exit 1
fi

if ! swift sdk list 2>/dev/null | grep -q "static-linux"; then
    version="${toolchain#swift-}"
    version="${version%-RELEASE}"
    base="https://download.swift.org/swift-${version}-release/static-sdk/${toolchain}"
    tmp="$(mktemp -d)"
    # The bundle's own version moved from 0.0.1 (Swift 6.0/6.1) to 0.1.0.
    bundle=""
    for sdk_version in 0.1.0 0.0.1; do
        candidate="${toolchain}_static-linux-${sdk_version}.artifactbundle.tar.gz"
        if curl -fsSL --retry 3 -o "${tmp}/${candidate}" "${base}/${candidate}"; then
            bundle="$candidate"
            break
        fi
    done
    if [[ -z "$bundle" ]]; then
        echo "no static Linux SDK found under ${base}" >&2
        exit 1
    fi
    swift sdk install "${tmp}/${bundle}"
    rm -rf "$tmp"
fi

swift build -c release --product kwwk --swift-sdk "$sdk_id"
bin_dir="$(swift build -c release --product kwwk --swift-sdk "$sdk_id" --show-bin-path)"

stage="dist/kwwk-linux-${arch}"
rm -rf "$stage"
mkdir -p "$stage"
cp "${bin_dir}/kwwk" "$stage/"
# SwiftPM names the bundle `<package>_<target>.resources` on Linux.
found=0
for resources in "${bin_dir}"/*.resources "${bin_dir}"/*.bundle; do
    [[ -e "$resources" ]] || continue
    cp -R "$resources" "$stage/"
    found=1
done
if [[ "$found" -ne 1 ]]; then
    echo "no resource bundle beside ${bin_dir}/kwwk" >&2
    exit 1
fi
strip "$stage/kwwk" 2>/dev/null || true

if file "$stage/kwwk" 2>/dev/null | grep -q "dynamically linked"; then
    echo "expected a static binary: $(file "$stage/kwwk")" >&2
    exit 1
fi

tar -C dist -czf "dist/kwwk-linux-${arch}.tar.gz" "kwwk-linux-${arch}"
(cd dist && sha256sum "kwwk-linux-${arch}.tar.gz" > "kwwk-linux-${arch}.tar.gz.sha256")
ls -la "$stage" dist
