#!/bin/bash
# 8.vllm_MultiLLM 기동 — gateway + vLLM ×N + claude
#   사용: ./start.sh            (.env 없으면 .env.org 로 생성)
#         ./start.sh 3          (복제본 수를 이번만 3 으로 — --scale vllm=3)
set -e
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "📋 .env 가 없어 .env.org 로 생성함 (27B 단일 백엔드는 qwen38-27b.env.org)"
  cp .env.org .env
fi
set -a; . ./.env; set +a
REPLICAS="${1:-${VLLM_REPLICAS:-2}}"

if ! command -v nvidia-smi &>/dev/null; then
  echo "❌ NVIDIA GPU 미감지 — vLLM 은 GPU 필수" >&2
  exit 1
fi

# 드라이버 점검 (cu129 이미지 기준 575+ 권장) — 미달이면 경고만 내고 compose 의 우회 env 로 진행
DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
if [ "${DRV%%.*}" -lt 575 ]; then
  echo "⚠️  NVIDIA 드라이버 ${DRV} (<575) — cu129 재빌드 이미지 + NVIDIA_DISABLE_REQUIRE 우회로 기동" >&2
fi

# GPU 를 복제본 여럿이 나눠 쓸 때(복제본 수 > GPU 수)만 메모리 비율 합 점검 — 단독이면 0.95 도 정상
GPUS=$(nvidia-smi -L | wc -l)
SUM=$(awk -v n="$REPLICAS" -v u="${GPU_MEMORY_UTILIZATION:-0.45}" -v g="$GPUS" 'BEGIN{printf "%.2f", n*u/g}')
if [ "$REPLICAS" -gt "$GPUS" ] && awk -v s="$SUM" 'BEGIN{exit !(s>0.92)}'; then
  echo "❌ 복제본 ${REPLICAS} × GPU_MEMORY_UTILIZATION ${GPU_MEMORY_UTILIZATION} = GPU당 ${SUM} (>0.92) — 비율을 낮추거나 복제본을 줄일 것" >&2
  exit 1
fi

# 호스트 bind 폴더 보장 (root 소유로 생성되는 것 방지)
for d in "${DF_DIR:-}" "${HF_CACHE_DIR:-}" "${VLLM_CACHE_DIR:-}"; do
  if [ -n "$d" ]; then mkdir -p "${d/#\~/$HOME}"; fi
done

# depends_on: service_healthy 때문에 전 복제본 로드가 끝날 때까지 블록된다 (복제본당 수 분)
#   진행 확인: 다른 터미널에서 docker compose logs -f vllm
echo "⏳ 복제본 ${REPLICAS}개를 하나씩 순서대로 로드함 — 전부 healthy 가 될 때까지 대기"
docker compose up -d --build --scale vllm="$REPLICAS"

# 이미 떠 있던 게이트웨이는 복제본 수가 바뀌어도 재생성되지 않는다 → upstream 목록을 다시 만들고 reload
docker compose exec -T gateway sh -c '/docker-entrypoint.d/40-vllm-upstreams.sh && nginx -s reload'

echo ""
echo "✅ 기동 완료 — gateway · vllm ×${REPLICAS} · claude"
echo "  - 모델:     ${VLLM_MODEL} (KV cache: ${KV_CACHE_DTYPE})"
echo "  - 로그:     docker compose logs -f vllm"
echo "  - API:      http://localhost:${GATEWAY_PORT:-8080}  (/v1/messages · /v1/chat/completions)"
echo "  - 점검:     ./test.sh"
echo "  - Claude:   docker exec -it ${CLAUDE_CONTAINER_NAME:-vllm-claude} bash → cc"
