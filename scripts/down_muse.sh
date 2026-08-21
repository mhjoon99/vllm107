#!/usr/bin/env bash
# Muse-Glimmer-30B만 중지 (본체·리랭커는 그대로 둔다. 이미지·HF 캐시는 유지)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker compose --profile muse rm -sf vllm-muse vllm-muse-warmup

echo ""
echo "=== 반납 후 통합 메모리 ==="
free -h
