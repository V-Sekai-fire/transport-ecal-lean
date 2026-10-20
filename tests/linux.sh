#!/bin/sh
# Build and run tests/run.sh in a Linux container (ubuntu 24.04), from a copy of the sources:
# the host's .ecal/build and .lake stay out, so the container builds its own.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
podman run --rm -i --platform linux/arm64 -e N="${N:-2000}" -e FRAMES="${FRAMES:-60}" \
	-v "$ROOT":/host:ro ubuntu:24.04 sh -eu <<'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq build-essential cmake ninja-build git curl ca-certificates >/dev/null
curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none >/dev/null
export PATH=$HOME/.elan/bin:$PATH
mkdir -p /w && cd /w
tar -C /host --exclude=./.lake --exclude=./.ecal/build -cf - . | tar -xf -
./scripts/build-ecal.sh >/dev/null 2>&1 || { echo "eCAL build failed"; exit 1; }
lake build 2>&1 | grep -E "error|Build completed" | head
./tests/run.sh
EOF
