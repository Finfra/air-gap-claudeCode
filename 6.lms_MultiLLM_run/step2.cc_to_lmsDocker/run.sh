#!/bin/bash
# step2/run.sh — docker cc → docker lms 직결
#
# 이 단계가 세우는 것: 네트워크 1개 + lms 1개 + claude 1개.
#   게이트웨이·다중 백엔드는 step3/step4 소관이며 여기서 만들지 않는다.
#   step1 대비 추가된 변수는 "LMS 를 컨테이너로 옮긴 것" 하나뿐 → 실패하면 원인은 lms 쪽.
#
# 사용:
#   cp .env.org .env && vi .env
#   ./run.sh            # 기동
#   ./run.sh --stop     # 정지 + 제거
#   ./run.sh --status   # 상태
#   ./run.sh --check    # 게이트 판정
#   ./run.sh --logs     # lms 로그 추적

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
else
  echo "[warn] $ENV_FILE 없음 — 기본값 사용 (cp .env.org .env 권장)"
fi

: "${LMS_MODEL:=google/gemma-4-e2b}"
: "${LMS_PORT:=1234}"
: "${LMS_HEALTH_TRIES:=30}"
: "${LMS_CONTEXT_LENGTH:=32768}"
: "${LMS_GPU:=max}"
: "${LMS_PARALLEL:=1}"
: "${LMS_SKIP_GET:=1}"
: "${LMS_GET_TIMEOUT:=60}"
: "${LMS_MODEL_MOUNT:=}"
: "${CLAUDE_MAX_OUTPUT_TOKENS:=8192}"
: "${CLAUDE_DIET:=1}"
: "${API_TIMEOUT_MS:=600000}"
: "${MOUNT_CODE_DIR:=}"
: "${LMS_CONTAINER_NAME:=lms}"
: "${CLAUDE_CONTAINER_NAME:=cc-step2}"
: "${LMS_NETWORK_NAME:=lms-step2}"
: "${LMS_IMAGE:=lms:small}"
: "${CLAUDE_IMAGE:=claude:latest}"
: "${TZ:=Asia/Seoul}"
: "${USE_GPU:=1}"
: "${LMS_PUBLISH_PORT:=}"

CLAUDE_HOME_VOLUME="cc-step2-home"

# ── 서브커맨드 ─────────────────────────────────────────────────────────────
case "${1:-}" in
  --stop|stop)
    docker rm -f "$CLAUDE_CONTAINER_NAME" "$LMS_CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "[+] 컨테이너 제거 (네트워크·볼륨 유지)"
    echo "    완전 정리: docker network rm $LMS_NETWORK_NAME; docker volume rm $CLAUDE_HOME_VOLUME"
    exit 0 ;;
  --status|status)
    docker ps -a --filter "network=$LMS_NETWORK_NAME" \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    exit 0 ;;
  --logs|logs)
    exec docker logs -f "$LMS_CONTAINER_NAME" ;;
  --check|check)
    # 진단 경로에서는 errexit/pipefail 을 끈다.
    #   ① 실패 브랜치의 grep 이 '일치 없음'(exit 1)을 반환하면 pipefail 이 스크립트를 통째로
    #      죽여, 게이트 2~5 가 아예 실행되지 않는다 — 첫 실패에서 나머지 진단을 잃는 것은
    #      폐쇄망에서 가장 손해가 큰 동작이다 (2026-07-20 step2 실측 재현).
    #   ② 판정 실패는 RC 로만 표현하고, 모든 게이트를 끝까지 돌린다.
    set +e
    set +o pipefail
    RC=0
    echo "[게이트 1] lms 0.0.0.0 바인딩"
    # 컨테이너 기동 직후 로그가 아직 안 실린 경우가 있어 짧게 재시도한다
    # (재시도 없이 판정하면 정상 구성인데 ❌ 가 뜬다 — 실측).
    BIND_LINE=""
    for _ in $(seq 1 10); do
      BIND_LINE="$(docker logs "$LMS_CONTAINER_NAME" 2>&1 | grep 'bind OK' | tail -1)"
      [ -n "$BIND_LINE" ] && break
      sleep 2
    done
    if [ -n "$BIND_LINE" ]; then
      echo "  ✅ $BIND_LINE"
    else
      echo "  ❌ 'bind OK' 없음 (20s 재시도) — loopback 전용 바인딩 의심"
      docker logs "$LMS_CONTAINER_NAME" 2>&1 | grep -i 'loopback\|WARNING\|ERROR' | tail -3 | sed 's/^/     /'
      RC=1
    fi

    echo "[게이트 1-2] 모델 로드 클린 여부 (허브 키 폴백이 없어야 함)"
    FALLBACK="$(docker logs "$LMS_CONTAINER_NAME" 2>&1 | grep '허브 키 로드 실패' | tail -1)"
    if [ -n "$FALLBACK" ]; then
      echo "  ⚠️  $FALLBACK"
      echo "     → .env 의 LMS_MODEL 을 'lms ls' 의 로컬 키로 교체할 것"
      RC=1
    else
      echo "  ✅ 폴백 없이 1회에 로드됨"
    fi

    echo "[게이트 2] cc 컨테이너 → lms:${LMS_PORT}/v1/models  (외부 관점 판정)"
    if docker exec "$CLAUDE_CONTAINER_NAME" \
         curl -fsS "http://${LMS_CONTAINER_NAME}:${LMS_PORT}/v1/models" >/dev/null 2>&1; then
      echo "  ✅ 200"
      docker exec "$CLAUDE_CONTAINER_NAME" \
        curl -fsS "http://${LMS_CONTAINER_NAME}:${LMS_PORT}/v1/models" | head -c 300; echo
    else
      echo "  ❌ 실패 — lms 내부 curl 성공은 판정 근거가 아님. README 진단표 참조"
      RC=1
    fi

    echo "[게이트 3] 모델 로드 상태"
    docker exec "$LMS_CONTAINER_NAME" sh -lc 'PATH=$HOME/.lmstudio/bin:$PATH lms ps' 2>&1 | tail -4

    echo "[게이트 5] VRAM (83% 안전선)"
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader \
        | awk -F'[ ,]+' '{pct=$3/$1*100; printf "  %s/%s MiB = %.1f%% %s\n", $3, $1, pct, (pct<=83?"✅":"❌ 안전선 초과")}'
    else
      echo "  · nvidia-smi 없음 — CPU 모드"
    fi
    exit $RC ;;
  --help|-h|help)
    grep -E '^# ' "$0" | sed 's/^# \?//'
    exit 0 ;;
esac

# ── 사전 확인 ──────────────────────────────────────────────────────────────
for f in entrypoint.lms.sh entrypoint.cc.sh; do
  [ -f "$SCRIPT_DIR/$f" ] || { echo "[!] $SCRIPT_DIR/$f 없음"; exit 1; }
done

for img in "$LMS_IMAGE" "$CLAUDE_IMAGE"; do
  docker image inspect "$img" >/dev/null 2>&1 \
    || { echo "[!] 이미지 '$img' 없음 — 'docker load -i <tar>' 후 재시도"; exit 1; }
done

# 호스트 LM Studio 가 GPU 를 점유하고 있으면 컨테이너 LMS 가 OOM 된다 (16GB 공유 환경).
if command -v nvidia-smi >/dev/null 2>&1 && [ "$USE_GPU" = "1" ]; then
  USED_MIB="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
  if [ "${USED_MIB:-0}" -gt 1024 ]; then
    echo "[!] GPU 가 이미 ${USED_MIB} MiB 사용 중 — 호스트 LM Studio 등이 점유하고 있을 수 있음."
    echo "    해제: lms unload --all && lms server stop"
    echo "    (의도적이면 USE_GPU=0 으로 CPU 강제 또는 이 확인을 무시하고 진행)"
    exit 1
  fi
fi

# ── 1) 네트워크 ────────────────────────────────────────────────────────────
if ! docker network inspect "$LMS_NETWORK_NAME" >/dev/null 2>&1; then
  docker network create "$LMS_NETWORK_NAME" >/dev/null
  echo "[+] network 생성: $LMS_NETWORK_NAME"
else
  echo "[=] network 존재: $LMS_NETWORK_NAME"
fi

# ── 2) 모델 마운트 결정 ────────────────────────────────────────────────────
# ⚠️ 빈 named volume 을 모델 경로에 마운트하면 이미지 내장 모델이 가려진다.
#    LMS_MODEL_MOUNT 가 비어 있으면 마운트하지 않고 이미지 내장 모델을 그대로 쓴다.
MODEL_MOUNT_OPT=()
if [ -n "$LMS_MODEL_MOUNT" ]; then
  if [[ "$LMS_MODEL_MOUNT" == /* || "$LMS_MODEL_MOUNT" == \~* ]]; then
    HOST_MODEL_DIR="${LMS_MODEL_MOUNT/#\~/$HOME}"
    mkdir -p "$HOST_MODEL_DIR"
    MODEL_MOUNT_OPT=(-v "$HOST_MODEL_DIR:/home/lms/.lmstudio/models")
    echo "[+] model mount(bind): $HOST_MODEL_DIR"
  else
    docker volume inspect "$LMS_MODEL_MOUNT" >/dev/null 2>&1 \
      || docker volume create "$LMS_MODEL_MOUNT" >/dev/null
    MODEL_MOUNT_OPT=(-v "$LMS_MODEL_MOUNT:/home/lms/.lmstudio/models")
    echo "[+] model mount(volume): $LMS_MODEL_MOUNT"
  fi
else
  echo "[=] model mount 없음 — 이미지 내장 모델 사용 ($LMS_IMAGE)"
fi

# ── 3) lms 기동 ────────────────────────────────────────────────────────────
GPU_OPT=()
[ "$USE_GPU" = "1" ] && GPU_OPT=(--gpus all)

PORT_OPT=()
[ -n "$LMS_PUBLISH_PORT" ] && PORT_OPT=(-p "${LMS_PUBLISH_PORT}:${LMS_PORT}")

docker rm -f "$LMS_CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$LMS_CONTAINER_NAME" \
  --network "$LMS_NETWORK_NAME" \
  --restart unless-stopped \
  "${GPU_OPT[@]}" \
  "${PORT_OPT[@]}" \
  "${MODEL_MOUNT_OPT[@]}" \
  -v "$SCRIPT_DIR/entrypoint.lms.sh:/usr/local/bin/entrypoint.lms.sh:ro" \
  --entrypoint /usr/local/bin/entrypoint.lms.sh \
  -e LMS_MODEL="$LMS_MODEL" \
  -e LMS_PORT="$LMS_PORT" \
  -e LMS_HEALTH_TRIES="$LMS_HEALTH_TRIES" \
  -e LMS_CONTEXT_LENGTH="$LMS_CONTEXT_LENGTH" \
  -e LMS_GPU="$LMS_GPU" \
  -e LMS_PARALLEL="$LMS_PARALLEL" \
  -e LMS_SKIP_GET="$LMS_SKIP_GET" \
  -e LMS_GET_TIMEOUT="$LMS_GET_TIMEOUT" \
  -e TZ="$TZ" \
  "$LMS_IMAGE" >/dev/null
echo "[+] $LMS_CONTAINER_NAME 기동"

# ── 4) 헬스 대기 ───────────────────────────────────────────────────────────
echo "[*] lms /v1/models 대기 (최대 240s)"
TRIES=0
until docker exec "$LMS_CONTAINER_NAME" \
        curl -fsS "http://127.0.0.1:${LMS_PORT}/v1/models" >/dev/null 2>&1; do
  TRIES=$((TRIES+1))
  if [ "$TRIES" -ge 120 ]; then
    echo "[!] lms 무응답 — 'docker logs $LMS_CONTAINER_NAME' 확인 후 재시도"
    exit 1
  fi
  # 컨테이너가 죽었으면 즉시 중단 (조용히 폴링만 계속하는 것 방지)
  docker inspect -f '{{.State.Running}}' "$LMS_CONTAINER_NAME" 2>/dev/null | grep -q true \
    || { echo "[!] lms 컨테이너가 종료됨 — docker logs $LMS_CONTAINER_NAME"; exit 1; }
  sleep 2
done
echo "[+] lms ready"

# ── 5) claude 기동 ─────────────────────────────────────────────────────────
CODE_MOUNT_OPT=()
if [ -n "$MOUNT_CODE_DIR" ]; then
  HOST_CODE_DIR="${MOUNT_CODE_DIR/#\~/$HOME}"
  mkdir -p "$HOST_CODE_DIR"
  CODE_MOUNT_OPT=(-v "$HOST_CODE_DIR:/home/ubuntu/code")
  echo "[+] code mount: $HOST_CODE_DIR"
fi

docker volume inspect "$CLAUDE_HOME_VOLUME" >/dev/null 2>&1 \
  || docker volume create "$CLAUDE_HOME_VOLUME" >/dev/null

docker rm -f "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CLAUDE_CONTAINER_NAME" \
  --network "$LMS_NETWORK_NAME" \
  --restart unless-stopped \
  -it \
  -v "$CLAUDE_HOME_VOLUME:/home/ubuntu" \
  "${CODE_MOUNT_OPT[@]}" \
  -v "$SCRIPT_DIR/entrypoint.cc.sh:/usr/local/bin/entrypoint.cc.sh:ro" \
  --entrypoint /usr/local/bin/entrypoint.cc.sh \
  -e ANTHROPIC_BASE_URL="http://${LMS_CONTAINER_NAME}:${LMS_PORT}" \
  -e ANTHROPIC_AUTH_TOKEN=lms \
  -e ANTHROPIC_MODEL="$LMS_MODEL" \
  -e ANTHROPIC_SMALL_FAST_MODEL="$LMS_MODEL" \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="$CLAUDE_MAX_OUTPUT_TOKENS" \
  -e CLAUDE_DIET="$CLAUDE_DIET" \
  -e LMS_HOST="$LMS_CONTAINER_NAME" \
  -e LMS_PORT="$LMS_PORT" \
  -e LMS_MODEL="$LMS_MODEL" \
  -e API_TIMEOUT_MS="$API_TIMEOUT_MS" \
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  -e TZ="$TZ" \
  "$CLAUDE_IMAGE" sleep infinity >/dev/null

echo "[+] $CLAUDE_CONTAINER_NAME 기동"
echo
echo "─────────────────────────────────────────────────────────────"
echo " 게이트 판정: $0 --check"
echo " 접속:        docker exec -it $CLAUDE_CONTAINER_NAME bash"
echo " 안에서:      cc"
echo " lms 로그:    $0 --logs"
echo " 정지:        $0 --stop"
echo "─────────────────────────────────────────────────────────────"
