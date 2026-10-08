#!/bin/bash
# lms:small 빌드 스크립트 — Dockerfile.small 헤더 주석 참고
#   전제: build.small/models/lmstudio-community/gemma-4-E2B-it-GGUF/ 에 모델 존재
#   (없으면 임시 컨테이너에서 `lms get -y google/gemma-4-e2b` 후 docker cp 로 준비)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

MODEL_DIR="build.small/models/lmstudio-community/gemma-4-E2B-it-GGUF"
if [ ! -f "$MODEL_DIR/gemma-4-E2B-it-Q4_K_M.gguf" ]; then
  echo "[!] $MODEL_DIR 에 모델 gguf 없음 — README '이미지 재생성' 절 참고" >&2
  exit 1
fi

# entrypoint 를 빌드 컨텍스트로 복사 (이미지 내장용 — Dockerfile.small 참조)
cp entrypoint.lms.sh build.small/entrypoint.lms.sh
docker build -f Dockerfile.small -t lms:small build.small/
docker images lms:small
echo "[+] lms:small 빌드 완료 (lms:latest 는 변경되지 않음)"
