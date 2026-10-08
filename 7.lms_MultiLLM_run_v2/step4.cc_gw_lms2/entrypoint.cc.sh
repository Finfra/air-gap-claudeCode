#!/bin/bash
# step4 — Claude Code 클라이언트 컨테이너 PID 1 (이미 USER=ubuntu)
#   경로: [docker: claude] ──→ gateway:GW_PORT ──→ lms-1 / lms-2  (nginx consistent hash)
#
#   step4 는 step3 대비 "백엔드 다중화" 하나만 추가한 단계다. 따라서:
#     - ANTHROPIC_BASE_URL 은 step3 와 동일하게 게이트웨이를 가리킨다
#     - **X-Session affinity 도입** — 아래 '세션 고정' 절 참조. 백엔드가 2개 이상이면
#       세션 후속 턴이 다른 백엔드에 떨어질 수 있고, 그때마다 전체 컨텍스트를 재프리필한다
#       (30k 토큰 기준 6.2s vs 0.49s ≈ 13배). 에러 없이 느려지기만 해서 발견이 어렵다.
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

# ── 세션 고정 (X-Session affinity) ─────────────────────────────────────────
#   셸마다 고유한 X-Session 헤더를 주입하면 게이트웨이가 consistent hash 로 같은 백엔드에
#   고정한다. $$(셸 PID)+$RANDOM 은 셸 기동 시 평가되므로 세션(셸)별로 값이 다르다.
#
#   ⚠️ settings.json 의 env 에 정적 X-Session 을 넣으면 안 된다 — settings.json 이 셸
#      export 보다 우선하므로(실측), 정적 값이면 **모든 세션이 한 백엔드에 고정**되어
#      분산이 죽는다. 그래서 여기서는 rc 파일 export + PATH shim 두 경로만 쓴다.
AFFINITY_LINE='export ANTHROPIC_CUSTOM_HEADERS="X-Session: cc-$$-$RANDOM"'
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  grep -qs 'ANTHROPIC_CUSTOM_HEADERS' "$rc" || echo "$AFFINITY_LINE" >> "$rc"
done

#   rc 파일은 로그인/대화형 셸에서만 읽힌다 — 'docker exec cc-step4 claude' 처럼 셸을
#   거치지 않는 진입은 헤더 없이 나가고, 게이트웨이가 $request_id 로 해시해 매 턴 다른
#   백엔드로 흩어진다. 에러 없이 느려지기만 해서 발견이 어렵다.
#   PATH 선순위 shim 으로 어떤 진입 경로에서도 헤더를 보장한다.
#   (docker run 시 -e PATH 로 ~/.local/bin 을 앞에 둬야 docker exec 에도 적용된다)
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude" <<'SHIM'
#!/bin/bash
# X-Session affinity shim — 이미 설정돼 있으면(대화형 셸 경유) 그 값을 존중한다.
[ -n "${ANTHROPIC_CUSTOM_HEADERS:-}" ] || export ANTHROPIC_CUSTOM_HEADERS="X-Session: cc-$$-$RANDOM"
exec /usr/bin/claude "$@"
SHIM
chmod +x "$HOME/.local/bin/claude"

# 편의 alias — 대화형 셸에서 'cc' 로 진입
grep -qs "alias cc=" "$HOME/.bashrc" \
  || echo "alias cc='claude --dangerously-skip-permissions'" >> "$HOME/.bashrc"

exec "$@"
