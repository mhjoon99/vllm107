#!/usr/bin/env bash
# prefix_repetition 합성 데이터셋으로 서빙 벤치마크 — prefix caching 효과 확인용
# (같은 시스템 프롬프트를 공유하는 게이트웨이 트래픽과 유사한 워크로드)
#
# 사용법:
#   bash scripts/bench_prefix.sh [num_prompts] [request_rate] [max_concurrency]
#   bash scripts/bench_prefix.sh                # 200 프롬프트, 5 req/s, 동시 8
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; [[ -f .env ]] && source .env; set +a
: "${MODEL_ID:?MODEL_ID가 .env에 없습니다}"
SERVED_NAME="${SERVED_NAME:-vllm-srv}"

NUM_PROMPTS="${1:-200}"
REQUEST_RATE="${2:-5}"
MAX_CONCURRENCY="${3:-8}"

export DATASET_DIR="${DATASET_DIR:-${HOME}/.cache/aigw-vllm/datasets}"
mkdir -p "${DATASET_DIR}"   # 합성 데이터셋이라 파일은 불필요하지만 마운트 소스는 있어야 함
mkdir -p results

echo "[info] 벤치 시작: prefix_repetition / ${NUM_PROMPTS} prompts / ${REQUEST_RATE} req/s / concurrency ${MAX_CONCURRENCY}"

docker compose run --rm bench \
    --backend vllm \
    --base-url "http://vllm:8000" \
    --model "${SERVED_NAME}" \
    --tokenizer "${MODEL_ID}" \
    --dataset-name prefix_repetition \
    --num-prompts "${NUM_PROMPTS}" \
    --request-rate "${REQUEST_RATE}" \
    --burstiness 1.0 \
    --prefix-repetition-prefix-len 256 \
    --prefix-repetition-suffix-len 256 \
    --prefix-repetition-num-prefixes 10 \
    --prefix-repetition-output-len 128 \
    --max-concurrency "${MAX_CONCURRENCY}" \
    --save-result \
    --append-result \
    --result-dir /results \
    --result-filename bench_results.jsonl \
    --metadata "setup=gb10-prefix"

echo ""
echo "✅ 완료. 결과 누적 파일: results/bench_results.jsonl"
