#!/usr/bin/env bash
# vLLM 중지 (이미지·HF 캐시는 유지 — 재기동 시 재다운로드 없음)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker compose down

echo ""
echo "=== 반납 후 통합 메모리 ==="
free -h
