#!/bin/bash
# step1/run.sh — docker cc → 호스트 LMS 직결
#
# 이 단계가 세우는 것: claude 컨테이너 1개. 그게 전부다.
#   네트워크·볼륨·게이트웨이·다중 백엔드는 후속 단계(step2~4) 소관이며 여기서 만들지 않는다.
#   LMS 는 호스트에 이미 떠 있는 것을 그대로 쓴다 → 실패하면 원인은 100% cc 쪽.
#
# 사용:
#   cp .env.org .env && vi .env
#   ./run.sh            # 기동
#   ./run.sh --stop     # 정지 + 제거
#   ./run.sh --status   # 상태
#   ./run.sh --check    # 게이트 판정 (외부 관점 도달 확인)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
else
  echo "[warn] $ENV_FILE 없음 — 기본값 사용 (cp .env.org .env 권장)"
fi

: "${LMS_HOST:=host.docker.internal}"
: "${LMS_PORT:=1234}"
: "${LMS_MODEL:=}"
: "${CLAUDE_MAX_OUTPUT_TOKENS:=8192}"
: "${CLAUDE_DIET:=1}"
: "${API_TIMEOUT_MS:=600000}"
: "${MOUNT_CODE_DIR:=}"
: "${CLAUDE_CONTAINER_NAME:=cc-step1}"
: "${CLAUDE_IMAGE:=claude:latest}"
: "${TZ:=Asia/Seoul}"

CLAUDE_HOME_VOLUME="cc-step1-home"

# ── 서브커맨드 ─────────────────────────────────────────────────────────────
case "${1:-}" in
  --stop|stop)
    docker rm -f "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "[+] $CLAUDE_CONTAINER_NAME 제거 (볼륨 유지: docker volume rm $CLAUDE_HOME_VOLUME)"
    exit 0 ;;
  --status|status)
    docker ps -a --filter "name=^/${CLAUDE_CONTAINER_NAME}$" \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    exit 0 ;;
  --check|check)
    echo "[게이트 1] cc 컨테이너 → 호스트 LMS /v1/models"
    if docker exec "$CLAUDE_CONTAINER_NAME" \
         curl -fsS "http://${LMS_HOST}:${LMS_PORT}/v1/models" >/dev/null 2>&1; then
      echo "  ✅ 200 — 도달 성공"
      docker exec "$CLAUDE_CONTAINER_NAME" \
        curl -fsS "http://${LMS_HOST}:${LMS_PORT}/v1/models" | head -c 400; echo
    else
      echo "  ❌ 실패 — README '실패 시 진단 순서' 참조"
      docker exec "$CLAUDE_CONTAINER_NAME" getent hosts "$LMS_HOST" \
        || echo "  · 이름 해석 실패: --add-host 누락 또는 LMS_HOST 오지정"
      exit 1
    fi
    echo "[게이트 3] 외부망 접속 시도 로그 (아무것도 안 나와야 정상)"
    docker logs "$CLAUDE_CONTAINER_NAME" 2>&1 | grep -iE 'anthropic\.com|statsig|sentry' \
      && echo "  ❌ 외부망 호출 흔적 발견" || echo "  ✅ 없음"
    exit 0 ;;
  --help|-h|help)
    grep -E '^# ' "$0" | sed 's/^# \?//'
    exit 0 ;;
esac

# ── 사전 확인 ──────────────────────────────────────────────────────────────
[ -f "$SCRIPT_DIR/entrypoint.cc.sh" ] || { echo "[!] entrypoint.cc.sh 없음"; exit 1; }

if ! docker image inspect "$CLAUDE_IMAGE" >/dev/null 2>&1; then
  echo "[!] 이미지 '$CLAUDE_IMAGE' 없음 — 'docker load -i <tar>' 후 재시도"
  exit 1
fi

if [ -z "$LMS_MODEL" ]; then
  echo "[!] .env 의 LMS_MODEL 이 비어 있음."
  echo "    'curl -s http://127.0.0.1:${LMS_PORT}/v1/models' 응답의 id 를 그대로 넣을 것."
  exit 1
fi

# 호스트에서 LMS 가 실제로 서빙 중인지 먼저 본다 — 컨테이너를 띄우기 전에
#   "호스트 LMS 미기동"을 "cc 고장"으로 오진하는 것을 막는다.
if ! curl -fsS --max-time 3 "http://127.0.0.1:${LMS_PORT}/v1/models" >/dev/null 2>&1; then
  echo "[!] 호스트 127.0.0.1:${LMS_PORT} 에서 LMS 응답 없음 — step1 의 전제가 성립하지 않음."
  echo "    호스트에서 먼저: lms server start --port ${LMS_PORT} --bind 0.0.0.0"
  echo "    (LM Studio 는 기본 loopback 전용 바인딩이라 --bind 0.0.0.0 이 필요)"
  exit 1
fi
echo "[=] 호스트 LMS 응답 확인 (127.0.0.1:${LMS_PORT})"

# ── 마운트 ─────────────────────────────────────────────────────────────────
CODE_MOUNT_OPT=()
if [ -n "$MOUNT_CODE_DIR" ]; then
  HOST_CODE_DIR="${MOUNT_CODE_DIR/#\~/$HOME}"
  mkdir -p "$HOST_CODE_DIR"
  CODE_MOUNT_OPT=(-v "$HOST_CODE_DIR:/home/ubuntu/code")
  echo "[+] code mount: $HOST_CODE_DIR"
fi

docker volume inspect "$CLAUDE_HOME_VOLUME" >/dev/null 2>&1 \
  || docker volume create "$CLAUDE_HOME_VOLUME" >/dev/null

# ── 기동 ───────────────────────────────────────────────────────────────────
# --add-host: Linux 는 host.docker.internal 이 기본 제공되지 않는다. host-gateway 는
#   Docker 20.10+ 가 해석하는 특수 값으로, 브릿지 게이트웨이 IP 로 치환된다.
docker rm -f "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CLAUDE_CONTAINER_NAME" \
  --restart unless-stopped \
  -it \
  --add-host=host.docker.internal:host-gateway \
  -v "$CLAUDE_HOME_VOLUME:/home/ubuntu" \
  "${CODE_MOUNT_OPT[@]}" \
  -v "$SCRIPT_DIR/entrypoint.cc.sh:/usr/local/bin/entrypoint.cc.sh:ro" \
  --entrypoint /usr/local/bin/entrypoint.cc.sh \
  -e ANTHROPIC_BASE_URL="http://${LMS_HOST}:${LMS_PORT}" \
  -e ANTHROPIC_AUTH_TOKEN=lms \
  -e ANTHROPIC_MODEL="$LMS_MODEL" \
  -e ANTHROPIC_SMALL_FAST_MODEL="$LMS_MODEL" \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="$CLAUDE_MAX_OUTPUT_TOKENS" \
  -e CLAUDE_DIET="$CLAUDE_DIET" \
  -e LMS_HOST="$LMS_HOST" \
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
echo " 안에서:      cc         # alias = claude --dangerously-skip-permissions"
echo " 정지:        $0 --stop"
echo "─────────────────────────────────────────────────────────────"
