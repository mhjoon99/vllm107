#!/usr/bin/env bash
# ShareGPT 벤치마크 데이터셋 다운로드 (~640MB) — bench_sharegpt.sh 실행 전 1회
set -euo pipefail

DATASET_DIR="${DATASET_DIR:-${HOME}/.cache/aigw-vllm/datasets}"
DATASET_FILE="ShareGPT_V3_unfiltered_cleaned_split.json"
URL="https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/${DATASET_FILE}"

mkdir -p "${DATASET_DIR}"

if [[ -f "${DATASET_DIR}/${DATASET_FILE}" ]]; then
    echo "[skip] 이미 존재합니다: ${DATASET_DIR}/${DATASET_FILE}"
else
    echo "[info] 다운로드 중 (~640MB, 이어받기 지원): ${URL}"
    curl -L -C - --fail --progress-bar -o "${DATASET_DIR}/${DATASET_FILE}" "${URL}"
fi

ls -lh "${DATASET_DIR}/${DATASET_FILE}"
