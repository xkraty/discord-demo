#!/usr/bin/env bash
# Concatenate pako + inject.js into inject.bundle.js, which is what the
# manifest loads as the MAIN-world content script.
set -euo pipefail
cd "$(dirname "$0")"
cat vendor/pako.min.js inject.js > inject.bundle.js
echo "wrote inject.bundle.js ($(wc -c < inject.bundle.js) bytes)"
