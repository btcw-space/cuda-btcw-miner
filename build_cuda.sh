#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p release
if ! command -v nvcc >/dev/null 2>&1; then
  echo "nvcc was not found. Install the NVIDIA CUDA toolkit, then open a new shell." >&2
  exit 1
fi
ARCH="${CUDA_ARCH:-sm_89}"
MAX_REGS="${1:-${CUDA_MAX_REGS:-160}}"
SIGN_BATCH="${CUDA_SIGN_BATCH:-128}"
if [[ "$SIGN_BATCH" != "64" && "$SIGN_BATCH" != "128" ]]; then
  echo "CUDA_SIGN_BATCH must be 64 or 128" >&2
  exit 2
fi
case "$ARCH" in
  sm_75|sm_80|sm_86|sm_89|sm_90|sm_100|sm_120) ;;
  *)
    echo "CUDA_ARCH must be one of sm_75 sm_80 sm_86 sm_89 sm_90 sm_100 sm_120" >&2
    exit 2
    ;;
esac
OUTPUT="release/btcw_cuda_miner_batch${SIGN_BATCH}"
echo "Building $OUTPUT for $ARCH (RTX 20 sm_75, RTX 30 sm_86, RTX 40 sm_89, RTX 50 sm_120)"
nvcc -O3 -std=c++17 -arch="$ARCH" --maxrregcount "$MAX_REGS" -DBTCW_SIGN_BATCH="$SIGN_BATCH" -Xptxas=-v,-warn-spills btcw_cuda_miner.cu -o "$OUTPUT" -lrt -lpthread
cp "$OUTPUT" release/btcw_cuda_miner
chmod +x release/btcw_cuda_miner "$OUTPUT"
echo "Built $OUTPUT for $ARCH maxrregcount=$MAX_REGS sign_batch=$SIGN_BATCH"
echo "Run: ./release/btcw_cuda_miner"
