#!/bin/bash
# fallback.gw_ollama/serve-ollama.sh — lms 실패 시 대체 경로:
#   반입한 lms-gateway:latest 이미지를 그대로 재사용하되, upstream 을 lms 대신
#   기존 ollamawebui:11434 로 갈아끼워 게이트웨이(:8080)를 다시 세운다.
#   → Windows 클라이언트의 접속 주소(http://<서버IP>:8080)는 그대로, 백엔드만 ollama 로 바뀐다.
#
#   ⚠️ 이미지 재빌드 없음. 다른 nginx 템플릿 + 다른 env 를 주는 것이 "gateway 컨테이너 수정"의 실체다.
#   ⚠️ 게이트웨이·ollama 의 /v1 은 무인증이다. 폐쇄망/신뢰 LAN 전제에서만 공개할 것.
#
# 사용:
#   ./serve-ollama.sh            # gateway 를 ollama 백엔드로 0.0.0.0 재공개 + Windows 설정값 출력
#   ./serve-ollama.sh --check    # 게이트 판정 (백엔드 생존 · LAN 리슨 · 자기 IP 접근)
#   ./serve-ollama.sh --revert   # gateway 제거 (lms 스택으로 복귀는 step4/step5 로)
#   ./serve-ollama.sh --settings # Windows 에 붙여넣을 settings.json 만 출력

set -euo pipefail

# ── 파라미터 (환경변수로 덮어쓰기 가능) ──────────────────────────────────────
OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-ollamawebui}"   # 폐쇄망에서 11434 서비스 중인 컨테이너명
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-gateway}"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-lms-gateway:latest}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
OLLAMA_MODEL="${OLLAMA_MODEL:-}"                       # 비우면 /v1/models 첫 id 자동 사용
TZ="${TZ:-Asia/Seoul}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/ollama.nginx.conf.template"
[ -f "$TEMPLATE" ] || { echo "[!] $TEMPLATE 없음"; exit 1; }

# ── ollamawebui 가 붙어 있는 docker 네트워크 자동 탐지 ───────────────────────
#   게이트웨이는 ollamawebui 와 같은 네트워크에 있어야 컨테이너명(ollamawebui)으로 닿는다.
detect_ollama_net() {
  docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
    "$OLLAMA_CONTAINER" 2>/dev/null | awk '{print $1}'
}
OLLAMA_NET="${OLLAMA_NET:-$(detect_ollama_net || true)}"

# upstream 결정: 같은 네트워크면 컨테이너명, 아니면 호스트 게이트웨이 IP 로 폴백
if [ -n "$OLLAMA_NET" ]; then
  OLLAMA_UPSTREAM="${OLLAMA_UPSTREAM:-${OLLAMA_CONTAINER}:${OLLAMA_PORT}}"
else
  OLLAMA_UPSTREAM="${OLLAMA_UPSTREAM:-host.docker.internal:${OLLAMA_PORT}}"
fi

# ── 서버 LAN IP 추정 (기본 라우트 인터페이스, docker 브릿지 172.x 회피) ──────
detect_lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}
LAN_IP="${LAN_IP:-$(detect_lan_ip || true)}"
: "${LAN_IP:=<서버IP>}"

# ── 모델 키 조회 (게이트웨이 경유 /v1/models 의 첫 id) ───────────────────────
resolve_model() {
  [ -n "$OLLAMA_MODEL" ] && { echo "$OLLAMA_MODEL"; return; }
  curl -fsS --max-time 5 "http://127.0.0.1:${GATEWAY_PORT}/v1/models" 2>/dev/null \
    | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/'
}

print_settings() {
  local model; model="$(resolve_model)"; : "${model:=<모델키>}"
  cat <<JSON
{
  "model": "${model}",
  "env": {
    "ANTHROPIC_BASE_URL": "http://${LAN_IP}:${GATEWAY_PORT}",
    "ANTHROPIC_AUTH_TOKEN": "ollama",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8192",
    "API_TIMEOUT_MS": "600000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
JSON
}

# ── ollamawebui 생존 확인 — 죽어 있으면 게이트웨이만 열어봐야 502 오진 유발 ──
require_ollama() {
  if ! docker inspect -f '{{.State.Running}}' "$OLLAMA_CONTAINER" 2>/dev/null | grep -q true; then
    echo "  ❌ ${OLLAMA_CONTAINER} 미실행 — 폐쇄망 ollama 서비스부터 확인할 것"
    exit 1
  fi
  echo "  ✅ ${OLLAMA_CONTAINER} 실행 중 (upstream=${OLLAMA_UPSTREAM}, net=${OLLAMA_NET:-<host>})"
}

run_gateway() {
  local bind_host="$1" net_args=()
  [ -n "$OLLAMA_NET" ] && net_args=(--network "$OLLAMA_NET")
  # 같은 네트워크가 아니면 host.docker.internal 을 열어줌
  [ -z "$OLLAMA_NET" ] && net_args=(--add-host=host.docker.internal:host-gateway)

  docker rm -f "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$GATEWAY_CONTAINER" \
    "${net_args[@]}" \
    --restart unless-stopped \
    -p "${bind_host}:${GATEWAY_PORT}:8080" \
    -v "${TEMPLATE}:/etc/nginx/templates/default.conf.template:ro" \
    -e OLLAMA_UPSTREAM="$OLLAMA_UPSTREAM" \
    -e TZ="$TZ" \
    "$GATEWAY_IMAGE" >/dev/null

  local TRIES=0
  until curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/v1/models" >/dev/null 2>&1; do
    TRIES=$((TRIES+1))
    [ "$TRIES" -ge 30 ] && { echo "[!] gateway 무응답 — docker logs $GATEWAY_CONTAINER"; exit 1; }
    sleep 2
  done
}

case "${1:-}" in
  --settings|settings)
    print_settings; exit 0 ;;

  --revert|revert)
    echo "[*] gateway 컨테이너 제거 (ollamawebui 는 건드리지 않음)"
    docker rm -f "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
    echo "[+] 완료 — lms 스택 복귀는 step4/step5 절차로"
    exit 0 ;;

  --check|check)
    set +e
    RC=0
    echo "[전제] ollamawebui 생존"; require_ollama || RC=1

    echo "[게이트 A] gateway LAN 리슨 (0.0.0.0)"
    PUB="$(docker port "$GATEWAY_CONTAINER" 2>/dev/null)"
    echo "  publish: ${PUB:-<없음>}"
    echo "$PUB" | grep -q '0\.0\.0\.0' && echo "  ✅ 0.0.0.0 바인딩" \
      || { echo "  ❌ 호스트 내부 전용 — ./serve-ollama.sh 로 재공개"; RC=1; }

    echo "[게이트 B] 서버 자기 LAN IP 접근 (${LAN_IP}:${GATEWAY_PORT})"
    if curl -fsS --max-time 10 "http://${LAN_IP}:${GATEWAY_PORT}/v1/models" >/dev/null 2>&1; then
      echo "  ✅ 200"
      curl -fsS "http://${LAN_IP}:${GATEWAY_PORT}/v1/models" | head -c 200; echo
    else
      echo "  ❌ 실패 — 이 단계가 안 되면 Windows 에서도 안 된다"; RC=1
    fi

    echo "[게이트 C] 방화벽 (${GATEWAY_PORT}/tcp 인바운드)"
    if command -v ufw >/dev/null 2>&1; then
      UFW="$(sudo -n ufw status 2>/dev/null | head -1 || true)"
      if [ -z "$UFW" ]; then echo "  · sudo 필요 — 수동: sudo ufw status"
      elif echo "$UFW" | grep -qi inactive; then echo "  ✅ ufw inactive"
      else sudo -n ufw status 2>/dev/null | grep -q "${GATEWAY_PORT}" \
        && echo "  ✅ ${GATEWAY_PORT} 허용 규칙 있음" \
        || { echo "  ⚠️ ufw active 인데 ${GATEWAY_PORT} 규칙 없음 — sudo ufw allow ${GATEWAY_PORT}/tcp"; RC=1; }
      fi
    else echo "  · ufw 미설치 — iptables/보안그룹 직접 확인"; fi

    echo
    echo "  Windows 에서 확인: curl.exe http://${LAN_IP}:${GATEWAY_PORT}/v1/models"
    exit $RC ;;

  --help|-h|help)
    grep -E '^# ' "$0" | sed 's/^# \?//'; exit 0 ;;
esac

# ── 기본 동작: ollama 백엔드로 gateway LAN 공개 ──────────────────────────────
echo "[*] ollamawebui 생존 확인"; require_ollama
echo "[*] gateway 를 ollama 백엔드로 0.0.0.0 재공개 (upstream=${OLLAMA_UPSTREAM})"
run_gateway "0.0.0.0"
echo "[+] gateway ready"
docker port "$GATEWAY_CONTAINER" | sed 's/^/    /'

echo
echo "─────────────────────────────────────────────────────────────"
echo " 서버 주소 : http://${LAN_IP}:${GATEWAY_PORT}"
echo " 백엔드    : ${OLLAMA_UPSTREAM}"
echo " 모델 키   : $(resolve_model || echo '<모델키 — /v1/models 확인>')"
echo
echo " Windows 도달 확인: curl.exe http://${LAN_IP}:${GATEWAY_PORT}/v1/models"
echo
echo " %USERPROFILE%\\.claude\\settings.json 에 넣을 내용:"
echo "─────────────────────────────────────────────────────────────"
print_settings
echo "─────────────────────────────────────────────────────────────"
echo " 판정: $0 --check      되돌리기: $0 --revert"
echo "─────────────────────────────────────────────────────────────"
