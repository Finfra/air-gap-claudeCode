#!/bin/bash
# step3 — Claude Code 클라이언트 컨테이너 PID 1 (이미 USER=ubuntu)
#   경로: [docker: claude] ──→ gateway:GW_PORT ──→ lms-1:LMS_PORT  (nginx L7 패스스루)
#
#   step3 는 step2 대비 "게이트웨이(nginx) 한 계층" 하나만 추가한 단계다. 따라서:
#     - ANTHROPIC_BASE_URL 이 게이트웨이를 가리킨다. 단 nginx 는 순수 L7 패스스루라
#       프로토콜은 여전히 OpenAI /v1 직결이다 (변환 프록시 아님)
#     - X-Session affinity 없음: 백엔드가 1개뿐이라 세션 고정이 성립할 대상이 없음 (step4 에서 도입)
set -e

GW_HOST="${GW_HOST:-gateway}"
GW_PORT="${GW_PORT:-8080}"

# ── 프롬프트 다이어트 ──────────────────────────────────────────────────────
#   도구 스키마가 프롬프트의 83%(24개 16,136 토큰) — deny 로 4개(Read/Bash/Edit/Write)만
#   남기면 19,385→3,041 토큰(-84%), 로컬 LLM 왕복 3.7~6.8배 단축 실측.
#   deny 는 블랙리스트라 Claude Code 버전업으로 새 도구가 생기면 자동 포함됨 — 주기 재검증 필요.
#   CLAUDE_DIET=0 이면 비활성(전체 도구).
#   ⚠️ WebSearch/WebFetch 는 다이어트와 무관하게 **항상** deny — 폐쇄망에서 외부망 도구를
#      켜두면 모델이 호출→실패→재시도 루프에 빠진다. CLAUDE_DIET=0 으로도 열리지 않게 분리.
CLAUDE_DIET="${CLAUDE_DIET:-1}"
AIRGAP_DENY='"WebSearch", "WebFetch"'
if [ "$CLAUDE_DIET" != "0" ]; then
  DENY_LIST="\"Workflow\", \"Agent\", \"CronCreate\", \"CronDelete\", \"CronList\",
      \"ScheduleWakeup\", \"EnterWorktree\", \"ExitWorktree\",
      \"TaskCreate\", \"TaskUpdate\", \"TaskGet\", \"TaskList\", \"TaskOutput\", \"TaskStop\",
      \"SendMessage\", \"NotebookEdit\", \"Skill\",
      ${AIRGAP_DENY}"
else
  DENY_LIST="${AIRGAP_DENY}"
fi

# ── settings.json 생성 (LMS 직결) ──────────────────────────────────────────
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<JSON
{
  "model": "${ANTHROPIC_MODEL:-${LMS_MODEL:-}}",
  "env": {
    "ANTHROPIC_BASE_URL": "http://${GW_HOST}:${GW_PORT}",
    "ANTHROPIC_AUTH_TOKEN": "lms"
  },
  "permissions": {
    "deny": [
      ${DENY_LIST}
    ]
  }
}
JSON

# ── 게이트웨이 도달 확인 ───────────────────────────────────────────────────
#   step3 의 핵심 판정 지점 — 여기서 실패하면 nginx 또는 upstream 해석 문제다.
#   게이트웨이가 /v1/models 에 200 을 주려면 백엔드가 이미 응답 중이어야 하므로,
#   이 대기가 통과하면 lms-1 까지의 경로가 살아 있다는 뜻이다 (기동 게이팅).
if getent hosts "$GW_HOST" >/dev/null 2>&1; then
  echo "[entrypoint] waiting for gateway at ${GW_HOST}:${GW_PORT} ..."
  TRIES=0
  until curl -fsS "http://${GW_HOST}:${GW_PORT}/v1/models" >/dev/null 2>&1; do
    TRIES=$((TRIES+1))
    if [ "$TRIES" -ge 30 ]; then
      echo "[entrypoint] WARNING: gateway unreachable after 60s — continuing anyway"
      echo "[entrypoint]   확인: docker logs gateway  (host not found in upstream / 502)"
      break
    fi
    echo "[entrypoint] gateway unavailable - sleeping (${TRIES}/30)"
    sleep 2
  done
  if curl -fsS "http://${GW_HOST}:${GW_PORT}/v1/models" >/dev/null 2>&1; then
    echo "[entrypoint] gateway is up - starting Claude Code environment"
  fi
else
  echo "[entrypoint] WARNING: host '${GW_HOST}' not resolvable — GW_HOST / --network 확인"
fi

# 편의 alias — 대화형 셸에서 'cc' 로 진입
grep -qs "alias cc=" "$HOME/.bashrc" \
  || echo "alias cc='claude --dangerously-skip-permissions'" >> "$HOME/.bashrc"

exec "$@"
