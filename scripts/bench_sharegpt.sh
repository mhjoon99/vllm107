#!/usr/bin/env bash
# ShareGPT 데이터셋으로 서빙 벤치마크 (vllm bench serve) — 서버가 떠 있는 상태에서 실행
# 결과는 results/bench_results.jsonl 에 누적(append)된다.
#
# 사용법:
#   bash scripts/bench_sharegpt.sh [num_prompts] [request_rate] [max_concurrency]
#   bash scripts/bench_sharegpt.sh              # 300 프롬프트, 5 req/s, 동시 8
#   bash scripts/bench_sharegpt.sh 20 5 4       # 파이프라인 확인용 초단축 실행
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# .env에서 MODEL_ID(토크나이저용)·SERVED_NAME(서빙 이름) 로드
set -a; [[ -f .env ]] && source .env; set +a
: "${MODEL_ID:?MODEL_ID가 .env에 없습니다}"
SERVED_NAME="${SERVED_NAME:-vllm-srv}"

NUM_PROMPTS="${1:-300}"
REQUEST_RATE="${2:-5}"
MAX_CONCURRENCY="${3:-8}"

DATASET_FILE="ShareGPT_V3_unfiltered_cleaned_split.json"
export DATASET_DIR="${DATASET_DIR:-${HOME}/.cache/aigw-vllm/datasets}"
if [[ ! -f "${DATASET_DIR}/${DATASET_FILE}" ]]; then
    echo "[error] 데이터셋이 없습니다. 먼저 bash scripts/download_dataset.sh 를 실행하세요." >&2
    exit 1
fi

mkdir -p results

echo "[info] 벤치 시작: sharegpt / ${NUM_PROMPTS} prompts / ${REQUEST_RATE} req/s / concurrency ${MAX_CONCURRENCY}"
echo "[info] 예상 소요: 대략 num_prompts ÷ request_rate 초 이상"

# --model은 서버가 노출하는 이름(SERVED_NAME), 토크나이저는 실제 HF repo(MODEL_ID)에서
docker compose run --rm bench \
    --backend vllm \
    --base-url "http://vllm:8000" \
    --model "${SERVED_NAME}" \
    --tokenizer "${MODEL_ID}" \
    --dataset-name sharegpt \
    --dataset-path "/data/${DATASET_FILE}" \
    --num-prompts "${NUM_PROMPTS}" \
    --request-rate "${REQUEST_RATE}" \
    --burstiness 1.0 \
    --max-concurrency "${MAX_CONCURRENCY}" \
    --save-result \
    --append-result \
    --result-dir /results \
    --result-filename bench_results.jsonl \
    --metadata "setup=gb10-sharegpt"

echo ""
echo "✅ 완료. 결과 누적 파일: results/bench_results.jsonl"
