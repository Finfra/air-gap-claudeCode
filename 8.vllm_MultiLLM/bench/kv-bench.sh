#!/bin/bash
# KV cache dtype before/after 비교 — 단일 vLLM 을 dtype 별로 같은 조건에서 띄우고 같은 부하를 건다
#   사용: bench/kv-bench.sh [dtype ...]
#         기본 dtype: auto(bf16, before) fp8 turboquant_k8v4 turboquant_4bit_nc turboquant_3bit_nc
#   조건(.env 의 모델·GPU_MEMORY_UTILIZATION 을 그대로 쓰고 아래만 덮어씀):
#     BENCH_MAX_MODEL_LEN (기본 8192 — bf16 도 기동되는 길이) · BENCH_MAX_NUM_SEQS (기본 32 — 동시 수 제한을 KV 가 정하게)
#     BENCH_CONCURRENCY 16 · BENCH_PROMPT_TOKENS 3000 · BENCH_NEEDLE_TOKENS 6000
#     BENCH_STARTUP_ONLY=1 이면 기동 로그(KV 토큰·실패 사유)만 수집
#     BENCH_ENV=qwen38-27b.env.org 처럼 다른 프리셋 지정 가능 (기본 .env)
#   ⚠️ 실행 중인 스택(start.sh)은 GPU 를 같이 쓰므로 먼저 ./clear.sh
cd "$(dirname "$0")/.."
set -a; . "./${BENCH_ENV:-.env}"; set +a

IMG="${VLLM_IMAGE:-vllm-turboquant:v0.30.0-cu129}"
PORT="${BENCH_PORT:-18000}"
LEN="${BENCH_MAX_MODEL_LEN:-8192}"
NAME=kv-bench
OUT="bench/results/$(date +%Y.%m.%d_%H%M%S)_${SERVED_MODEL_NAME}_len${LEN}"
mkdir -p "$OUT"
[ $# -gt 0 ] && DTYPES=("$@") || DTYPES=(auto fp8 turboquant_k8v4 turboquant_4bit_nc turboquant_3bit_nc)
HF="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"; HF="${HF/#\~/$HOME}"
VC="${VLLM_CACHE_DIR:-$HOME/.cache/vllm}"; VC="${VC/#\~/$HOME}"

if docker ps --format '{{.Names}}' | grep -q .; then
  echo "❌ 실행 중인 컨테이너가 있음 — GPU 를 비운 뒤 실행 (./clear.sh)" >&2
  docker ps --format '  {{.Names}}' >&2
  exit 1
fi

for dt in "${DTYPES[@]}"; do
  echo "== $dt (max_model_len $LEN, util ${GPU_MEMORY_UTILIZATION})"
  docker rm -f "$NAME" >/dev/null 2>&1
  t0=$(date +%s)
  docker run -d --name "$NAME" --gpus all --ipc host -p "$PORT:8000" \
    -e VLLM_MODEL="$VLLM_MODEL" -e SERVED_MODEL_NAME="$SERVED_MODEL_NAME" \
    -e KV_CACHE_DTYPE="$dt" -e MAX_MODEL_LEN="$LEN" \
    -e MAX_NUM_SEQS="${BENCH_MAX_NUM_SEQS:-32}" -e MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}" \
    -e GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION" -e VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}" \
    -e VLLM_STARTUP_LOCK=0 -e HF_HOME=/root/.cache/huggingface \
    -e NVIDIA_DISABLE_REQUIRE=1 -e CUDA_MODULE_LOADING=LAZY -e VLLM_USE_FLASHINFER_SAMPLER=0 \
    -v "$HF:/root/.cache/huggingface" -v "$VC:/root/.cache/vllm" "$IMG" >/dev/null

  ok=0
  for _ in $(seq 180); do  # 최대 15분
    if curl -sf "localhost:$PORT/health" >/dev/null; then ok=1; break; fi
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] || break
    sleep 5
  done
  echo "  기동 $(( $(date +%s) - t0 ))초 · $( [ $ok = 1 ] && echo healthy || echo 실패 )"
  if [ $ok = 1 ] && [ "${BENCH_STARTUP_ONLY:-0}" != 1 ]; then
    python3 bench/kv_bench.py run --base "http://localhost:$PORT" --model "$SERVED_MODEL_NAME" --dtype "$dt" \
      --out "$OUT/$dt.json" --concurrency "${BENCH_CONCURRENCY:-16}" \
      --prompt-tokens "${BENCH_PROMPT_TOKENS:-3000}" --needle-tokens "${BENCH_NEEDLE_TOKENS:-6000}" 2>&1 | sed 's/^/  /'
  fi
  docker logs "$NAME" > "$OUT/$dt.log" 2>&1
  grep -hE "Available KV cache memory|GPU KV cache size|Maximum concurrency" "$OUT/$dt.log" | tail -3 | sed 's/^.*\] /  /'
  docker rm -f "$NAME" >/dev/null
done

echo
python3 bench/kv_bench.py report "$OUT" --concurrency "${BENCH_CONCURRENCY:-16}" | tee "$OUT/report.md"
echo "결과: $OUT"
