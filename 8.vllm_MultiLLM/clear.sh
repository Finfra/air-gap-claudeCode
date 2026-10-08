#!/bin/bash
# 8.vllm_MultiLLM 정리 — 컨테이너·네트워크만 제거 (모델 캐시·claude 홈·df 보존)
#   ./clear.sh --volumes  → named volume(claude-home·hf-cache·vllm-cache·vllm-locks)까지 삭제
set -e
cd "$(dirname "$0")"
if [ "${1:-}" = "--volumes" ]; then
  docker compose down --remove-orphans --volumes
  echo "✅ 컨테이너 + named volume 삭제 (호스트 bind 경로 HF_CACHE_DIR·VLLM_CACHE_DIR·DF_DIR 는 보존)"
else
  docker compose down --remove-orphans
  echo "✅ 컨테이너 정리 완료 (모델 캐시·claude 홈 보존)"
fi
