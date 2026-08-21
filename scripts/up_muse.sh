#!/usr/bin/env bash
# Muse-Glimmer-30B 기동 (compose profile "muse")
#
# 평시 `docker compose up -d`에는 이 서비스가 뜨지 않는다. 반드시 이 스크립트로 띄운다.
# 기동 전에 두 가지를 강제로 검사한다 — 둘 다 실패하면 서버가 죽거나 옆 스택까지 OOM:
#   (1) 이미지가 muse_glimmer 아키텍처를 아는가 (vLLM 2026-08-14 이후 nightly만 지원)
#   (2) 통합 메모리 예산 합이 0.90 이하인가 (옆 스택 포함)
#
# 사용법: bash scripts/up_muse.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
    echo "[error] .env가 없습니다. cp .env.example .env 후 값을 채우세요." >&2
    exit 1
fi

# .env를 통째로 source하지 않는다 — EXTRA_ARGS 같은 다중 토큰 값이
# "VAR=a b c" 형태라 뒤쪽 토큰이 명령으로 실행돼버린다. 필요한 키만 뽑는다.
envget() {  # envget KEY [기본값]
    local v
    v="$(grep -E "^${1}=" .env \
        | tr -d '\015' \
        | tail -n1 | cut -d= -f2- \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]*$//')"
    printf '%s' "${v:-$2}"
}

VLLM_IMAGE="$(envget VLLM_IMAGE vllm-openai:gb10-verified)"
MUSE_MODEL_ID="$(envget MUSE_MODEL_ID RedHatAI/Muse-Glimmer-30B-NVFP4)"
MUSE_SERVED_NAME="$(envget MUSE_SERVED_NAME muse-glimmer-30b)"
PORT=53110

# ── 검사 1: 이미지의 아키텍처 지원 ──────────────────────────────────────────
echo "=== [1/2] 이미지 아키텍처 지원 검사: ${VLLM_IMAGE} ==="
if ! docker image inspect "${VLLM_IMAGE}" >/dev/null 2>&1; then
    echo "❌ 이미지 ${VLLM_IMAGE} 가 없습니다." >&2
    exit 1
fi

SUPPORT_OUT="$(docker run --rm --entrypoint python3 "${VLLM_IMAGE}" -c '
import importlib.util, sys
try:
    import vllm
    ver = vllm.__version__
except Exception as e:
    print("ERR", e); sys.exit(0)
ok = importlib.util.find_spec("vllm.model_executor.models.muse_glimmer") is not None
print(("OK" if ok else "NOSUPPORT"), ver)
' 2>/dev/null || echo "ERR docker-run-failed")"

STATUS="${SUPPORT_OUT%% *}"
VLLM_VER="${SUPPORT_OUT#* }"

case "${STATUS}" in
  OK)
    echo "✅ muse_glimmer 지원 확인 (vLLM ${VLLM_VER})"
    ;;
  NOSUPPORT)
    cat >&2 <<MSG
❌ 이 이미지(vLLM ${VLLM_VER})에는 muse_glimmer 아키텍처가 없습니다.
   vLLM의 Muse-Glimmer 지원은 2026-08-14에 main에 들어갔고, 정식 릴리스
   v0.27.1(2026-08-11)에는 포함돼 있지 않습니다. 그대로 띄우면
   "Unrecognized architecture MuseGlimmerForConditionalGeneration"로 종료됩니다.

   해결 — 기존 검증본 태그는 **보존하고** 새 태그로 받아서 검증하세요:
     docker pull vllm/vllm-openai:nightly
     docker tag vllm/vllm-openai:nightly vllm-openai:gb10-verified-2
     # .env 에  VLLM_IMAGE=vllm-openai:gb10-verified-2  로 지정 후 재실행
   ⚠️ 이미지가 바뀌면 본체·리랭커도 같은 이미지를 쓰므로 aarch64/GB10 재검증이 필요합니다.
MSG
    exit 1
    ;;
  *)
    echo "❌ 지원 여부를 확인하지 못했습니다: ${SUPPORT_OUT}" >&2
    exit 1
    ;;
esac

# ── 검사 2: 통합 메모리 예산 ────────────────────────────────────────────────
echo ""
echo "=== [2/2] 통합 메모리 예산 검사 ==="
NEIGHBOR="$(envget NEIGHBOR_GPU_MEM_UTIL 0.7)"
MAIN="$(envget GPU_MEM_UTIL 0.25)"
RERANK="$(envget RERANK_GPU_MEM_UTIL 0.05)"
MUSE="$(envget MUSE_GPU_MEM_UTIL 0.22)"
BUDGET="$(envget MEM_BUDGET_CEILING 0.90)"

printf '  옆 스택 (NEIGHBOR_GPU_MEM_UTIL)  %s\n' "${NEIGHBOR}"
printf '  본체    (GPU_MEM_UTIL)          %s\n' "${MAIN}"
printf '  리랭커  (RERANK_GPU_MEM_UTIL)   %s\n' "${RERANK}"
printf '  Muse    (MUSE_GPU_MEM_UTIL)     %s\n' "${MUSE}"
awk -v a="${NEIGHBOR}" -v b="${MAIN}" -v c="${RERANK}" -v d="${MUSE}" -v cap="${BUDGET}" '
BEGIN { s = a + b + c + d; printf "  ─────────────────────────────────\n  합계  %.2f  (상한 %.2f)\n", s, cap }'

if ! awk -v a="${NEIGHBOR}" -v b="${MAIN}" -v c="${RERANK}" -v d="${MUSE}" -v cap="${BUDGET}" \
    'BEGIN { exit !((a + b + c + d) <= cap) }'; then
    cat >&2 <<MSG

❌ 메모리 예산 초과 — 기동을 중단합니다.
   vLLM의 --gpu-memory-utilization은 각 프로세스가 전체 통합 메모리 기준으로
   독립 계산합니다. 합이 1.0을 넘으면 이 서비스뿐 아니라 **옆 스택까지 OOM**납니다.

   조치 (둘 중 하나 — 임의로 옆 스택을 건드리지 말고 담당자와 협의):
     · 옆 스택이 반납한 값을 .env의 NEIGHBOR_GPU_MEM_UTIL에 반영
     · 본체 GPU_MEM_UTIL / RERANK_GPU_MEM_UTIL / MUSE_GPU_MEM_UTIL 하향
   상한 자체를 바꿔야 한다면 MEM_BUDGET_CEILING로 명시적으로 올리세요 (권장하지 않음).
MSG
    exit 1
fi
echo "✅ 예산 통과"

# ── 기동 ────────────────────────────────────────────────────────────────────
echo ""
echo "[info] 모델: ${MUSE_MODEL_ID}"
echo "[info] 최초 기동은 양자화본 ~20GB 다운로드 + 30B 로딩으로 오래 걸립니다."
echo "[info] 로그 실시간 보기: docker logs -f vllm-muse-srv"
docker compose --profile muse up -d vllm-muse vllm-muse-warmup

MAX_WAIT_SEC="${MAX_WAIT_SEC:-3600}"
ELAPSED=0
until curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1; do
    if ! docker ps --format '{{.Names}}' | grep -q '^vllm-muse-srv$'; then
        echo ""
        echo "❌ 컨테이너가 종료됐습니다. 마지막 로그:"
        docker logs --tail 40 vllm-muse-srv
        exit 1
    fi
    if (( ELAPSED >= MAX_WAIT_SEC )); then
        echo "❌ ${MAX_WAIT_SEC}초 안에 서버가 뜨지 않았습니다. docker logs vllm-muse-srv 로 확인하세요."
        exit 1
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if (( ELAPSED % 30 == 0 )); then
        echo "  [${ELAPSED}s] $(docker logs --tail 1 vllm-muse-srv 2>&1 | tail -c 120)"
    fi
done

echo ""
echo "✅ Muse-Glimmer 준비 완료: http://localhost:${PORT}"
echo "[info] 워밍업 확인: docker logs vllm-muse-srv-warmup   (\"muse warmup ok\"면 정상)"
echo ""
echo "=== 메모리 실측 (MUSE_GPU_MEM_UTIL 재조정 근거로 기록) ==="
docker logs vllm-muse-srv 2>&1 \
    | grep -E "Model loading took|Available KV cache memory|GPU KV cache size|Maximum concurrency" \
    || echo "(해당 로그 라인을 찾지 못했습니다 — docker logs vllm-muse-srv 로 직접 확인)"
echo ""
echo "=== 현재 통합 메모리 ==="
free -h
echo ""
echo "다음 단계:"
echo "  curl -s http://localhost:${PORT}/v1/models"
echo "  curl -s http://localhost:${PORT}/v1/chat/completions -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${MUSE_SERVED_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8}'"
