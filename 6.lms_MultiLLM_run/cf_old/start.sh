#!/bin/bash
# 6.lms_MultiLLM_run/start.sh
#   ─ 순수 docker run 기반 다중 LMS 백엔드 + nginx L7 분산 + claude 클라이언트.
#   ─ air-gap: docker compose 미설치 환경 대응 (5.lms_MultiLLM 을 이식).
#
# 전제:
#   - lms:latest, gateway:latest, claude:latest 이미지가 이미 로드됨 (docker load -i ...)
#     * 이미지 태그가 다르면 아래 LMS_IMAGE/GATEWAY_IMAGE/CLAUDE_IMAGE 를 .env 로 오버라이드
#   - 스크립트가 놓인 폴더에 entrypoint.sh, entrypoint.lms.sh, nginx.conf.template 이 함께 있음
#
# 스크립트가 하는 일:
#   1) .env 로드 → 기본값 병합
#   2) 네트워크 · 모델 볼륨 확보
#   3) lms-1..N 백엔드 기동 (--network-alias lms — Docker DNS 로 nginx 분산)
#      · entrypoint.lms.sh 를 5.lms_MultiLLM 판으로 override (:ro bind mount + --entrypoint)
#   4) 각 백엔드 /v1/models 헬스 폴링
#   5) gateway (nginx) 기동 — nginx.conf.template 를 :ro bind mount, ${LMS_PORT} envsubst
#   6) gateway /v1/models 폴링 (claude 기동 게이팅)
#   7) claude 기동 — entrypoint.sh 5.버전 override + GW_HOST/GW_PORT 주입
#
# 사용:
#   cp .env.org .env && vi .env
#   ./start.sh            # 기본 (GPU 사용)
#   USE_GPU=0 ./start.sh  # CPU 강제
#   ./start.sh --stop     # 전부 정지 + 제거
#   ./start.sh --status   # 컨테이너 상태 확인

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── .env 로드 (있으면) ─────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
else
  echo "[warn] $ENV_FILE 없음 — 기본값 사용 (cp .env.org .env 권장)"
fi

# ── 기본값 (env.sh/.env.org 과 동기) ───────────────────────────────────────
: "${LMS_MODEL:=meta-llama-3.1-8b-instruct}"
: "${LMS_PORT:=1234}"
: "${LMS_HEALTH_TRIES:=30}"
: "${LMS_CONTEXT_LENGTH:=32768}"
: "${LMS_GPU:=}"          # 빈값=자동 offload (VRAM<모델크기 환경에서 max 는 CUDA OOM)
: "${LMS_PARALLEL:=1}"    # 슬롯 분할 방지 — Claude Code 는 1 필수 (ctx/슬롯수 = 슬롯당 ctx)
: "${LMS_SKIP_GET:=1}"    # 1=기동 시 'lms get'(허브 접속) 완전 생략 — 폐쇄망 기본값
: "${LMS_GET_TIMEOUT:=60}"  # LMS_SKIP_GET=0 일 때 'lms get' 상한(초). blackhole 방화벽 hang 방지
: "${LMS_MODEL_MOUNT:=lms-models}"        # 빈문자열이면 named volume, 절대경로면 bind
: "${GATEWAY_PORT:=8080}"
: "${LMS_BACKEND_COUNT:=2}"
: "${API_TIMEOUT_MS:=600000}"
: "${GATEWAY_CONTAINER_NAME:=gateway}"
: "${CLAUDE_CONTAINER_NAME:=claude}"
: "${LMS_NETWORK_NAME:=lms}"
: "${TZ:=Asia/Seoul}"
: "${USER_UID:=1000}"
: "${USER_GID:=1000}"

# 이미지 태그 (air-gap 로드된 이미지 이름과 일치해야 함)
: "${LMS_IMAGE:=lms:latest}"
: "${GATEWAY_IMAGE:=lms-gateway:latest}"
: "${CLAUDE_IMAGE:=claude:latest}"

# 옵션
: "${USE_GPU:=1}"                          # 1=NVIDIA GPU, 0=CPU only
: "${MOUNT_CODE_DIR:=}"                    # 호스트 코드 폴더(선택, claude 마운트)
# Claude Code 출력 토큰 상한 — LMS 컨텍스트에 input+output 합산 예산이 필요.
# 기본 max_tokens(≈32k)가 그대로 가면 32k 컨텍스트 백엔드에서 500 발생.
: "${CLAUDE_MAX_OUTPUT_TOKENS:=8192}"
# 프롬프트 다이어트 (1=도구 4개만, 0=전체 24개) — entrypoint.sh 주석 참조
: "${CLAUDE_DIET:=1}"

CLAUDE_HOME_VOLUME="claude-home"

# ── 서브커맨드: stop / status ──────────────────────────────────────────────
case "${1:-}" in
  --stop|stop)
    echo "[*] 정지 및 제거"
    for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
      docker rm -f "lms-$i" >/dev/null 2>&1 || true
    done
    docker rm -f "$GATEWAY_CONTAINER_NAME" "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "[+] 완료 (네트워크·볼륨은 유지 — 완전 정리는 아래 명령 참고)"
    echo "    docker network rm $LMS_NETWORK_NAME"
    echo "    docker volume  rm $CLAUDE_HOME_VOLUME $LMS_MODEL_MOUNT"
    exit 0 ;;
  --status|status)
    docker ps -a --filter "network=$LMS_NETWORK_NAME" \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    exit 0 ;;
  --help|-h|help)
    grep -E '^# ' "$0" | sed 's/^# \?//'
    exit 0 ;;
esac

# ── 필수 파일 존재 확인 ────────────────────────────────────────────────────
for f in entrypoint.sh entrypoint.lms.sh nginx.conf.template; do
  [ -f "$SCRIPT_DIR/$f" ] || { echo "[!] $SCRIPT_DIR/$f 없음 — 폴더 이관 누락"; exit 1; }
done

echo "[*] 이미지 존재 확인"
for img in "$LMS_IMAGE" "$GATEWAY_IMAGE" "$CLAUDE_IMAGE"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "[!] 이미지 '$img' 없음 — 'docker load -i <tar>' 로 반입 후 재시도"
    echo "    (또는 .env 에서 *_IMAGE 오버라이드)"
    exit 1
  fi
done

# ── 1) 네트워크 ────────────────────────────────────────────────────────────
if ! docker network inspect "$LMS_NETWORK_NAME" >/dev/null 2>&1; then
  docker network create "$LMS_NETWORK_NAME" >/dev/null
  echo "[+] network 생성: $LMS_NETWORK_NAME"
else
  echo "[=] network 존재: $LMS_NETWORK_NAME"
fi

# ── 2) 모델 마운트 결정 (named volume vs bind mount) ───────────────────────
if [[ "$LMS_MODEL_MOUNT" == /* || "$LMS_MODEL_MOUNT" == \~* ]]; then
  # 호스트 경로 (bind mount)
  HOST_MODEL_DIR="${LMS_MODEL_MOUNT/#\~/$HOME}"
  mkdir -p "$HOST_MODEL_DIR"
  MODEL_MOUNT_OPT=(-v "$HOST_MODEL_DIR:/home/lms/.lmstudio/models")
  echo "[+] model mount(bind): $HOST_MODEL_DIR"
else
  # named volume
  docker volume inspect "$LMS_MODEL_MOUNT" >/dev/null 2>&1 || docker volume create "$LMS_MODEL_MOUNT" >/dev/null
  MODEL_MOUNT_OPT=(-v "$LMS_MODEL_MOUNT:/home/lms/.lmstudio/models")
  echo "[+] model mount(volume): $LMS_MODEL_MOUNT"
fi

# ── 3) LMS 백엔드 N개 기동 ──────────────────────────────────────────────────
# GPU 배치: 백엔드 1개당 GPU 1장 전용 할당(--gpus "device=K").
#   '--gpus all' 을 N개 백엔드에 똑같이 주면 전원이 같은 GPU0 에 적재된다 —
#   31b@32k ×2 ≈ 44GB 로 A6000(48GB) 92%, VRAM 83% 안전선 초과 → 장문에서 CUDA OOM.
#   (83% 는 권고가 아니라 97% 구성에서 재현된 실측 OOM. 짧은 프롬프트는 통과하다 죽음.)
GPU_COUNT=0
if [ "$USE_GPU" = "1" ]; then
  GPU_COUNT="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
  : "${GPU_COUNT:=0}"
  echo "[*] 감지된 GPU: ${GPU_COUNT}장 / 백엔드: ${LMS_BACKEND_COUNT}개"
  if [ "$GPU_COUNT" -eq 0 ]; then
    echo "[!] nvidia-smi 로 GPU 를 찾지 못함 — '--gpus all' 로 진행 (드라이버/toolkit 확인 필요)"
  elif [ "$LMS_BACKEND_COUNT" -gt "$GPU_COUNT" ]; then
    # 초과 구독 = OOM 경로. 기본은 정지시키고, 의도적일 때만 명시 승인으로 통과.
    echo "[!] 백엔드(${LMS_BACKEND_COUNT}) > GPU(${GPU_COUNT}) — 같은 GPU 에 다중 적재되어 VRAM 초과 위험."
    echo "    권장: .env 의 LMS_BACKEND_COUNT 를 ${GPU_COUNT} 이하로 낮출 것."
    echo "    (VRAM 이 (모델+KV)×백엔드 를 확실히 감당한다면 LMS_ALLOW_GPU_OVERSUBSCRIBE=1 로 강행)"
    [ "${LMS_ALLOW_GPU_OVERSUBSCRIBE:-0}" = "1" ] || exit 1
    echo "[!] LMS_ALLOW_GPU_OVERSUBSCRIBE=1 — 초과 구독 강행. nvidia-smi 로 VRAM 감시할 것."
  fi
fi

echo "[*] LMS 백엔드 $LMS_BACKEND_COUNT 개 기동"
for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
  NAME="lms-$i"
  # 백엔드 i → GPU (i-1). GPU 수를 넘어서면 순환(초과 구독 승인된 경우에만 도달).
  GPU_OPT=()
  if [ "$USE_GPU" = "1" ]; then
    if [ "$GPU_COUNT" -gt 0 ]; then
      GPU_OPT=(--gpus "device=$(( (i-1) % GPU_COUNT ))")
    else
      GPU_OPT=(--gpus all)
    fi
  fi
  # 백엔드별 호스트 포트 노출 — lms-i 를 host:$((LMS_PORT+i-1)) 로 매핑.
  # 외부(호스트/타 머신)에서 lms-1 을 직접 때려 테스트할 수 있게 하고,
  # 다중 백엔드 시 포트 충돌 없이 lms-2:1235, lms-3:1236... 로 확장.
  HOST_PORT=$((LMS_PORT + i - 1))
  PORT_OPT=(-p "${HOST_PORT}:${LMS_PORT}")
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" \
    --network "$LMS_NETWORK_NAME" \
    --network-alias lms \
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
  if [ "$USE_GPU" = "1" ] && [ "$GPU_COUNT" -gt 0 ]; then
    echo "  [+] $NAME 기동 (GPU $(( (i-1) % GPU_COUNT )), host :${HOST_PORT})"
  else
    echo "  [+] $NAME 기동 (host :${HOST_PORT})"
  fi
done

# ── 4) 각 LMS /v1/models 헬스 대기 (첫 백엔드만 정밀 대기, 나머진 확인만) ──
echo "[*] LMS /v1/models 헬스 대기 (백엔드당 최대 120s, 순차 → 총 최대 $((LMS_BACKEND_COUNT*120))s)"
WAIT_MAX=60
for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
  NAME="lms-$i"
  TRIES=0
  until docker exec "$NAME" curl -fsS "http://127.0.0.1:${LMS_PORT}/v1/models" >/dev/null 2>&1; do
    TRIES=$((TRIES+1))
    if [ "$TRIES" -ge "$WAIT_MAX" ]; then
      echo "  [!] $NAME /v1/models 무응답 ($((WAIT_MAX*2))s) — 계속 진행"
      break
    fi
    sleep 2
  done
  [ "$TRIES" -lt "$WAIT_MAX" ] && echo "  [+] $NAME ready"
done

# ── 5) 게이트웨이(nginx) 기동 ──────────────────────────────────────────────
# upstream 서버 목록 생성 — 백엔드 이름(lms-1..N)을 명시해야 consistent hash 세션 고정이 성립.
#   (단일 'server lms:1234 resolve' 는 DNS RR 로 affinity 무효 — nginx.conf.template 주석 참조)
#   'resolve' 는 nginx.conf.template 의 'zone lms_backends 64k' 와 한 쌍 — 이름을 부팅
#   시점에 고정하지 않고 런타임에 재해석해, 기동 순서 역전/백엔드 IP 변경에 견디게 한다.
LMS_UPSTREAM_SERVERS=""
for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
  LMS_UPSTREAM_SERVERS="${LMS_UPSTREAM_SERVERS}    server lms-$i:${LMS_PORT} resolve max_fails=3 fail_timeout=30s;
"
done

docker rm -f "$GATEWAY_CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$GATEWAY_CONTAINER_NAME" \
  --network "$LMS_NETWORK_NAME" \
  --restart unless-stopped \
  -p "${GATEWAY_PORT}:8080" \
  -v "$SCRIPT_DIR/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro" \
  -e LMS_PORT="$LMS_PORT" \
  -e LMS_UPSTREAM_SERVERS="$LMS_UPSTREAM_SERVERS" \
  -e TZ="$TZ" \
  "$GATEWAY_IMAGE" >/dev/null
echo "[+] $GATEWAY_CONTAINER_NAME 기동 (외부 포트 :$GATEWAY_PORT)"

# ── 6) gateway 헬스 대기 ───────────────────────────────────────────────────
echo "[*] gateway /v1/models 대기 (최대 ~90s)"
TRIES=0
until curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/v1/models" >/dev/null 2>&1; do
  TRIES=$((TRIES+1))
  if [ "$TRIES" -ge 45 ]; then
    echo "[!] gateway 무응답 — claude 는 진행하되 로그 확인 권장 (docker logs $GATEWAY_CONTAINER_NAME)"
    break
  fi
  sleep 2
done
[ "$TRIES" -lt 45 ] && echo "[+] gateway ready"

# ── 7) claude 기동 ─────────────────────────────────────────────────────────
CODE_MOUNT_OPT=()
if [ -n "$MOUNT_CODE_DIR" ]; then
  HOST_CODE_DIR="${MOUNT_CODE_DIR/#\~/$HOME}"
  mkdir -p "$HOST_CODE_DIR"
  CODE_MOUNT_OPT=(-v "$HOST_CODE_DIR:/home/ubuntu/code")
  echo "[+] code mount: $HOST_CODE_DIR"
fi

docker volume inspect "$CLAUDE_HOME_VOLUME" >/dev/null 2>&1 || docker volume create "$CLAUDE_HOME_VOLUME" >/dev/null

# 개발 머신 전용 편의 마운트 — 호스트에 ~/df 가 있을 때만 붙는다(폐쇄망에선 보통 no-op).
DF_MOUNT_OPT=()
[ -d "$HOME/df" ] && DF_MOUNT_OPT=(-v "$HOME/df:/home/ubuntu/df")

docker rm -f "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CLAUDE_CONTAINER_NAME" \
  --network "$LMS_NETWORK_NAME" \
  --restart unless-stopped \
  -it \
  -v "$CLAUDE_HOME_VOLUME:/home/ubuntu" \
  "${DF_MOUNT_OPT[@]}" \
  "${CODE_MOUNT_OPT[@]}" \
  -v "$SCRIPT_DIR/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro" \
  --entrypoint /usr/local/bin/entrypoint.sh \
  `# ~/.local/bin 선순위 — entrypoint.sh 가 만드는 claude shim(X-Session affinity 보장)이` \
  `# 'docker exec claude claude' 처럼 셸 미경유 진입에서도 잡히게 한다. docker exec 는` \
  `# 컨테이너 생성 시 env 를 상속하므로 여기서 PATH 를 지정해야 효과가 있다.` \
  -e PATH="/home/ubuntu/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e ANTHROPIC_BASE_URL="http://${GATEWAY_CONTAINER_NAME}:8080" \
  -e ANTHROPIC_AUTH_TOKEN=lms \
  -e ANTHROPIC_MODEL="$LMS_MODEL" \
  -e ANTHROPIC_SMALL_FAST_MODEL="$LMS_MODEL" \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="$CLAUDE_MAX_OUTPUT_TOKENS" \
  -e CLAUDE_DIET="$CLAUDE_DIET" \
  -e GW_HOST="$GATEWAY_CONTAINER_NAME" \
  -e GW_PORT=8080 \
  -e LMS_MODEL="$LMS_MODEL" \
  -e API_TIMEOUT_MS="$API_TIMEOUT_MS" \
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  -e TZ="$TZ" \
  "$CLAUDE_IMAGE" sleep infinity >/dev/null

echo "[+] $CLAUDE_CONTAINER_NAME 기동"
echo
echo "─────────────────────────────────────────────────────────────"
echo " 접속:  docker exec -it $CLAUDE_CONTAINER_NAME bash"
echo " 안에서: cc         # alias = claude --dangerously-skip-permissions"
echo " 게이트웨이: http://127.0.0.1:${GATEWAY_PORT}/v1/models"
echo " 상태:  $0 --status"
echo " 정지:  $0 --stop"
echo "─────────────────────────────────────────────────────────────"
