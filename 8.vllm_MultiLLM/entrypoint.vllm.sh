#!/bin/bash
# vLLM 백엔드 PID 1 — `vllm serve` 를 env 로 조립해 기동한다
#
# 복제본 기동 직렬화 (VLLM_STARTUP_LOCK=1, 기본):
#   --scale vllm=N 복제본이 GPU 1장을 나눠 쓰면 동시에 기동할 때 서로의 메모리 프로파일링을
#   오염시킨다(상대가 잡은 VRAM 을 자기 사용량으로 오인 → KV 예산 오산·OOM).
#   공유 볼륨(/locks)의 flock 으로 «한 번에 하나씩 로드 → /health 200 → 다음 복제본» 순서를 강제한다.
#   같은 HF 캐시에 동시 다운로드하는 경합도 함께 막는다.
set -euo pipefail

PORT=8000
LOCK_FILE="${VLLM_LOCK_DIR:-/locks}/startup.lock"
ME="$(hostname)"

log() { echo "[entrypoint ${ME}] $*"; }

[ -n "${VLLM_MODEL:-}" ] || { log "ERROR: VLLM_MODEL 미설정"; exit 1; }

# 폐쇄망: 모델이 캐시에 있으면 HF 접속을 끈다 (접속 시도 타임아웃으로 기동이 늦어지는 것 방지)
if [ "${VLLM_OFFLINE:-0}" = "1" ]; then
  export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
  log "offline mode (HF_HUB_OFFLINE=1)"
fi

ARGS=(
  "${VLLM_MODEL}"
  --served-model-name "${SERVED_MODEL_NAME:-local-llm}"
  --host 0.0.0.0 --port "${PORT}"
  --kv-cache-dtype "${KV_CACHE_DTYPE:-auto}"
  --max-model-len "${MAX_MODEL_LEN:-32768}"
  --max-num-seqs "${MAX_NUM_SEQS:-4}"
  --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS:-2048}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.45}"
  --enable-prefix-caching
)
[ "${CPU_OFFLOAD_GB:-0}" != "0" ] && ARGS+=(--cpu-offload-gb "${CPU_OFFLOAD_GB}")
[ -n "${REASONING_PARSER:-}" ] && ARGS+=(--reasoning-parser "${REASONING_PARSER}")
[ -n "${TOOL_CALL_PARSER:-}" ] && ARGS+=(--enable-auto-tool-choice --tool-call-parser "${TOOL_CALL_PARSER}")
# 자유 인자 (공백 분리) — ex) --enforce-eager / GGUF 의 --tokenizer·--hf-config-path
# shellcheck disable=SC2206
[ -n "${VLLM_EXTRA_ARGS:-}" ] && ARGS+=(${VLLM_EXTRA_ARGS})

PID=""
trap '[ -n "$PID" ] && kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; exit 143' TERM INT

if [ "${VLLM_STARTUP_LOCK:-1}" = "1" ]; then
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  log "waiting for startup lock ..."
  flock 9
  log "startup lock acquired"
fi

log "vllm serve ${ARGS[*]}"
# 9>&- : 잠금 fd 를 vllm 프로세스에 물려주지 않는다 (물려주면 해제 후에도 잠금이 남는다)
vllm serve "${ARGS[@]}" 9>&- &
PID=$!

if [ "${VLLM_STARTUP_LOCK:-1}" = "1" ]; then
  # 로드 완료(/health 200) 또는 프로세스 사망까지 대기 — 어느 쪽이든 잠금을 풀어 다음 복제본을 진행시킨다
  until curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; do
    if ! kill -0 "$PID" 2>/dev/null; then
      log "ERROR: vllm 프로세스가 로드 중 종료됨 — 잠금 해제"
      flock -u 9
      wait "$PID" || exit $?
      exit 1
    fi
    sleep 5
  done
  flock -u 9
  exec 9>&-
  log "ready — startup lock released"
fi

wait "$PID"
