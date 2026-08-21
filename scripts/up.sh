#!/usr/bin/env bash
# [선택] vLLM 기동 + health 대기 + 메모리 지표 요약 (R8 예산 검증 기록용)
# 일반 기동은 `docker compose up -d`만으로 충분 (health 후 워밍업까지 자동) — README 참고
# 사용법: bash scripts/up.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
    echo "[error] .env가 없습니다. cp .env.example .env 후 MODEL_ID를 채우세요." >&2
    exit 1
fi

docker compose up -d   # vllm + vllm-warmup (bench는 profiles로 제외됨)

PORT=53108
echo ""
echo "[info] 서버 기동 대기 중... (최초 실행은 모델 다운로드 때문에 수 분~수십 분 걸릴 수 있음)"
echo "[info] 로그 실시간 보기: docker logs -f vllm-srv"

MAX_WAIT_SEC="${MAX_WAIT_SEC:-1800}"
ELAPSED=0
until curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1; do
    if ! docker ps --format '{{.Names}}' | grep -q '^vllm-srv$'; then
        echo ""
        echo "❌ 컨테이너가 종료됐습니다. 마지막 로그:"
        docker logs --tail 30 vllm-srv
        exit 1
    fi
    if (( ELAPSED >= MAX_WAIT_SEC )); then
        echo "❌ ${MAX_WAIT_SEC}초 안에 서버가 뜨지 않았습니다. docker logs vllm-srv 로 확인하세요."
        exit 1
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if (( ELAPSED % 30 == 0 )); then
        echo "  [${ELAPSED}s] $(docker logs --tail 1 vllm-srv 2>&1 | tail -c 120)"
    fi
done

echo ""
echo "✅ vLLM 서버 준비 완료: http://localhost:${PORT}"
echo ""
echo "[info] 워밍업은 vllm-warmup 컨테이너가 자동 수행 — 확인: docker logs vllm-srv-warmup"
echo ""
echo "=== 메모리 지표 (R8 예산 검증용 — 이 값들을 계획서에 기록) ==="
docker logs vllm-srv 2>&1 \
    | grep -E "Model loading took|Available KV cache memory|GPU KV cache size|Maximum concurrency" \
    || echo "(해당 로그 라인을 찾지 못했습니다 — docker logs vllm-srv 로 직접 확인)"
echo ""
echo "=== 현재 통합 메모리 (GB10은 nvidia-smi 대신 free) ==="
free -h
echo ""
echo "다음 단계:"
echo "  curl -s http://localhost:${PORT}/v1/models | python3 -m json.tool"
