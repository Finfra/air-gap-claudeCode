#!/bin/bash
# step5/serve-lan.sh — 서버 측 준비: 게이트웨이를 LAN 에 공개한다.
#
# step5 는 클라이언트 OS 만 바꾸는 단계다. 서버 스택(lms-1·lms-2·gateway)은 step4 의 것을
# **그대로 재사용**한다. 따라서 이 스크립트는 백엔드를 절대 건드리지 않고,
# **gateway 컨테이너만** 0.0.0.0 바인딩으로 다시 만든다.
#   (docker 는 실행 중 컨테이너의 포트 publish 를 바꿀 수 없어 재생성이 유일한 방법이다.
#    gateway 는 무상태라 재생성 비용이 없다 — lms 는 모델 재로드가 필요하므로 손대지 않는다.)
#
# ⚠️ 게이트웨이·LMS 의 /v1 은 **무인증**이다(토큰 'lms' 는 형식상).
#    폐쇄망 또는 신뢰 LAN 전제에서만 공개할 것.
#
# 사용:
#   ./serve-lan.sh            # 게이트웨이를 0.0.0.0 으로 재공개 + Windows 용 설정값 출력
#   ./serve-lan.sh --check    # 게이트 판정 (LAN 리슨 · 자기 IP 접근 · 백엔드 생존)
#   ./serve-lan.sh --revert   # 127.0.0.1 전용으로 되돌림
#   ./serve-lan.sh --settings # Windows 에 붙여넣을 settings.json 만 출력

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP4_DIR="$(cd "$SCRIPT_DIR/../step4.cc_gw_lms2" && pwd)"

# step4 의 .env 를 그대로 읽는다 — step5 는 별도 설정을 갖지 않는다(같은 스택이므로).
ENV_FILE="${STEP4_DIR}/.env"
[ -f "$ENV_FILE" ] || { echo "[!] $ENV_FILE 없음 — step4 를 먼저 구성·기동할 것"; exit 1; }
set -a; . "$ENV_FILE"; set +a

: "${LMS_MODEL:=gemma-4-e2b-it}"
: "${LMS_PORT:=1234}"
: "${LMS_BACKEND_COUNT:=2}"
: "${GATEWAY_PORT:=8080}"
: "${GATEWAY_INTERNAL_PORT:=8080}"
: "${GATEWAY_CONTAINER_NAME:=gateway}"
: "${LMS_NETWORK_NAME:=lms-step4}"
: "${GATEWAY_IMAGE:=lms-gateway:latest}"
: "${API_TIMEOUT_MS:=600000}"
: "${CLAUDE_MAX_OUTPUT_TOKENS:=8192}"
: "${TZ:=Asia/Seoul}"

# 서버의 LAN IP 추정 — 기본 라우트가 나가는 인터페이스의 주소.
#   docker 브릿지(172.x)가 잡히지 않도록 기본 라우트 기준으로 고른다.
detect_lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}
LAN_IP="${LAN_IP:-$(detect_lan_ip)}"
: "${LAN_IP:=<서버IP>}"

build_upstream() {
  local out="" i
  for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
    out="${out}    server lms-$i:${LMS_PORT} resolve max_fails=3 fail_timeout=30s;
"
  done
  printf '%s' "$out"
}

# 백엔드 생존 확인 — step5 는 step4 스택 위에서만 성립한다.
#   백엔드가 죽은 채로 게이트웨이만 열면 Windows 에서 502 를 보고
#   'Windows 문제'로 오진하게 된다. 여기서 fail-loud 로 끊는다.
require_backends() {
  local i missing=0
  for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
    if ! docker inspect -f '{{.State.Running}}' "lms-$i" 2>/dev/null | grep -q true; then
      echo "  ❌ lms-$i 미실행"; missing=1
    else
      echo "  ✅ lms-$i 실행 중"
    fi
  done
  if [ "$missing" = "1" ]; then
    echo
    echo "[!] step5 는 step4 스택(lms-1..N)이 살아 있어야 성립한다."
    echo "    기동: cd $STEP4_DIR && ./run.sh"
    exit 1
  fi
}

print_settings() {
  cat <<JSON
{
  "model": "${LMS_MODEL}",
  "env": {
    "ANTHROPIC_BASE_URL": "http://${LAN_IP}:${GATEWAY_PORT}",
    "ANTHROPIC_AUTH_TOKEN": "lms",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "${CLAUDE_MAX_OUTPUT_TOKENS}",
    "API_TIMEOUT_MS": "${API_TIMEOUT_MS}",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
JSON
}

restart_gateway() {
  local bind_host="$1"
  docker rm -f "$GATEWAY_CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$GATEWAY_CONTAINER_NAME" \
    --network "$LMS_NETWORK_NAME" \
    --restart unless-stopped \
    -p "${bind_host}:${GATEWAY_PORT}:${GATEWAY_INTERNAL_PORT}" \
    -v "$STEP4_DIR/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro" \
    -e LMS_PORT="$LMS_PORT" \
    -e LMS_UPSTREAM_SERVERS="$(build_upstream)" \
    -e TZ="$TZ" \
    "$GATEWAY_IMAGE" >/dev/null

  local TRIES=0
  until curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/v1/models" >/dev/null 2>&1; do
    TRIES=$((TRIES+1))
    [ "$TRIES" -ge 45 ] && { echo "[!] gateway 무응답 — docker logs $GATEWAY_CONTAINER_NAME"; exit 1; }
    sleep 2
  done
}

case "${1:-}" in
  --settings|settings)
    print_settings; exit 0 ;;

  --revert|revert)
    echo "[*] 게이트웨이를 127.0.0.1 전용으로 되돌림 (백엔드는 유지)"
    echo "[*] 백엔드 확인"; require_backends
    restart_gateway "127.0.0.1"
    echo "[+] 완료 — LAN 에서 접근 불가 상태"
    docker port "$GATEWAY_CONTAINER_NAME"
    exit 0 ;;

  --check|check)
    set +e; set +o pipefail
    RC=0
    echo "[전제] step4 백엔드 생존"
    for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
      docker inspect -f '{{.State.Running}}' "lms-$i" 2>/dev/null | grep -q true \
        && echo "  ✅ lms-$i 실행 중" || { echo "  ❌ lms-$i 미실행"; RC=1; }
    done

    echo "[게이트 A] 게이트웨이 LAN 리슨 (0.0.0.0)"
    PUB="$(docker port "$GATEWAY_CONTAINER_NAME" 2>/dev/null)"
    echo "  publish: ${PUB:-<없음>}"
    if echo "$PUB" | grep -q '0\.0\.0\.0'; then
      echo "  ✅ 0.0.0.0 바인딩"
    else
      echo "  ❌ 호스트 내부 전용 — ./serve-lan.sh 로 재공개 필요"
      RC=1
    fi

    echo "[게이트 B] 서버 자기 LAN IP 로 접근 (${LAN_IP}:${GATEWAY_PORT})"
    if curl -fsS --max-time 10 "http://${LAN_IP}:${GATEWAY_PORT}/v1/models" >/dev/null 2>&1; then
      echo "  ✅ 200"
      curl -fsS "http://${LAN_IP}:${GATEWAY_PORT}/v1/models" | head -c 200; echo
    else
      echo "  ❌ 실패 — 이 단계가 안 되면 Windows 에서도 절대 안 된다"
      RC=1
    fi

    echo "[게이트 C] 방화벽 (${GATEWAY_PORT}/tcp 인바운드)"
    if command -v ufw >/dev/null 2>&1; then
      UFW="$(sudo -n ufw status 2>/dev/null | head -1)"
      if [ -z "$UFW" ]; then
        echo "  · ufw 상태 조회에 sudo 필요 — 수동 확인: sudo ufw status"
      elif echo "$UFW" | grep -qi inactive; then
        echo "  ✅ ufw inactive — 차단 없음"
      else
        sudo -n ufw status 2>/dev/null | grep -q "${GATEWAY_PORT}" \
          && echo "  ✅ ${GATEWAY_PORT} 허용 규칙 있음" \
          || { echo "  ⚠️ ufw active 인데 ${GATEWAY_PORT} 규칙 없음 — sudo ufw allow ${GATEWAY_PORT}/tcp"; RC=1; }
      fi
    else
      echo "  · ufw 미설치 — iptables/보안그룹 직접 확인"
    fi

    echo
    echo "  Windows 에서 확인할 명령:"
    echo "    curl.exe http://${LAN_IP}:${GATEWAY_PORT}/v1/models"
    exit $RC ;;

  --help|-h|help)
    grep -E '^# ' "$0" | sed 's/^# \?//'
    exit 0 ;;
esac

# ── 기본 동작: LAN 공개 ────────────────────────────────────────────────────
echo "[*] step4 백엔드 확인 (건드리지 않음)"
require_backends

echo "[*] gateway 만 0.0.0.0 으로 재공개 (lms-1..N 은 그대로 유지)"
restart_gateway "0.0.0.0"
echo "[+] gateway ready"
docker port "$GATEWAY_CONTAINER_NAME" | sed 's/^/    /'

echo
echo "─────────────────────────────────────────────────────────────"
echo " 서버 주소 : http://${LAN_IP}:${GATEWAY_PORT}"
echo " 모델 키   : ${LMS_MODEL}"
echo
echo " Windows 에서 먼저 도달 확인:"
echo "   curl.exe http://${LAN_IP}:${GATEWAY_PORT}/v1/models"
echo
echo " %USERPROFILE%\\.claude\\settings.json 에 넣을 내용:"
echo "─────────────────────────────────────────────────────────────"
print_settings
echo "─────────────────────────────────────────────────────────────"
echo " 판정: $0 --check      되돌리기: $0 --revert"
echo "─────────────────────────────────────────────────────────────"
