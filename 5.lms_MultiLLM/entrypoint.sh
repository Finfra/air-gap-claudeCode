#!/bin/bash
# Claude Code 클라이언트 컨테이너 PID 1 — 이미 USER=ubuntu (Dockerfile USER ubuntu)
#   - 게이트웨이(nginx) 단일 주소에 직결. 게이트웨이가 N개 LMS 백엔드로 분산.
#   - 변환 프록시 없음: ANTHROPIC_BASE_URL 이 gateway:PORT 를 직접 가리킴(B1)
#   - GW_HOST: 게이트웨이 컨테이너명(기본 gateway), GW_PORT: 게이트웨이 내부 포트(기본 8080)
set -e

GW_HOST="${GW_HOST:-gateway}"
GW_PORT="${GW_PORT:-8080}"

# Claude Code 프롬프트 다이어트 (SSOT: DeviceManagement fg1/lms/diet_settings.json)
#   도구 스키마가 프롬프트의 83%(24개 16,136 토큰) — deny 로 4개(Read/Bash/Edit/Write)만 남기면
#   19,385→3,041 토큰(-84%), 로컬 LLM 왕복 3.7~6.8배 단축 실측(benchmark_lms_report.md).
#   deny 는 블랙리스트라 Claude Code 버전업으로 새 도구가 생기면 자동 포함됨 — 주기 재검증 필요.
#   CLAUDE_DIET=0 이면 비활성(전체 24개 도구).
#   ⚠️ WebSearch/WebFetch 는 다이어트와 무관하게 **항상** deny — 폐쇄망에서 외부망 도구를
#      켜두면 모델이 호출→실패→재시도 루프에 빠짐. CLAUDE_DIET=0 으로도 열리지 않게 분리함.
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
DIET_BLOCK=',
  "permissions": {
    "deny": [
      '"${DENY_LIST}"'
    ]
  }'

# claude settings.json 생성 (게이트웨이 단일 주소 반영)
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<JSON
{
  "model": "${ANTHROPIC_MODEL:-${LMS_MODEL:-}}",
  "env": {
    "ANTHROPIC_BASE_URL": "http://${GW_HOST}:${GW_PORT}",
    "ANTHROPIC_AUTH_TOKEN": "lms"
  }${DIET_BLOCK}
}
JSON

# 게이트웨이 연결 확인 (해석 가능하면 /v1/models 대기, 아니면 경고 후 진행)
#   게이트웨이 healthcheck 가 백엔드 응답 시에만 통과하므로, 여기 도달했다면
#   최소 1개 백엔드가 모델을 서빙 중일 가능성이 높음(B7 기동 게이팅).
if getent hosts "$GW_HOST" >/dev/null 2>&1; then
  echo "[entrypoint] waiting for gateway at ${GW_HOST}:${GW_PORT} ..."
  TRIES=0
  until curl -fsS "http://${GW_HOST}:${GW_PORT}/v1/models" >/dev/null 2>&1; do
    TRIES=$((TRIES+1))
    if [ "$TRIES" -ge 60 ]; then
      echo "[entrypoint] WARNING: gateway unreachable after 120s — continuing anyway"
      break
    fi
    echo "[entrypoint] gateway unavailable - sleeping (${TRIES}/60)"
    sleep 2
  done
  if curl -fsS "http://${GW_HOST}:${GW_PORT}/v1/models" >/dev/null 2>&1; then
    echo "[entrypoint] gateway is up - starting Claude Code environment"
  fi
else
  echo "[entrypoint] WARNING: host '${GW_HOST}' not resolvable - check service name / GW_HOST"
fi

# 세션→백엔드 고정(affinity): 셸마다 고유 X-Session 헤더를 주입 — 게이트웨이가
#   consistent hash 로 같은 백엔드에 고정 (실측 근거: lms-affinity-test_report.md).
#   $$(셸 PID)+$RANDOM 은 셸 기동 시 평가되므로 세션(셸)별로 값이 다름.
AFFINITY_LINE='export ANTHROPIC_CUSTOM_HEADERS="X-Session: cc-$$-$RANDOM"'
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  grep -qs 'ANTHROPIC_CUSTOM_HEADERS' "$rc" || echo "$AFFINITY_LINE" >> "$rc"
done

exec "$@"
