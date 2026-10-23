#!/usr/bin/env bash
set -euo pipefail

clt=/Library/Developer/CommandLineTools

if [[ "${1:-}" == build || "${1:-}" == test ]] && [[ "$(xcode-select -p)" == "$clt" ]]; then
  sub=$1
  shift
  exec swift "$sub" -Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing" "$@"
fi

exec swift "$@"
