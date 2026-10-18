#!/usr/bin/env bash
# Build the C++ model of ta_core (cmodel/) with CMake and run its unit tests
# (requantizer cases, directed bus tests, and a replay of the RTL bench's
# vector file), against the vectors host/ta/vectors.py wrote. Prints
# CMODEL_PASS when every test passes. Run from WSL in the repository root.
set -euo pipefail
cd "$(dirname "$0")/.."
vectors=$PWD/artifacts/vectors
[[ -f $vectors/core.txt && -f $vectors/quant.txt ]] || { echo "run: python -m host.ta.vectors first"; exit 1; }
cmake -S cmodel -B build/cmodel -DTA_VECTORS="$vectors" > /dev/null
cmake --build build/cmodel -j 8
ctest --test-dir build/cmodel --output-on-failure -V | grep -E "TEST_PASS|TEST_FAIL|cases from|replayed|array|tests passed|Test +#"
echo "CMODEL_PASS g++ $(g++ -dumpfullversion), cmake $(cmake --version | head -1 | awk '{print $3}')"
