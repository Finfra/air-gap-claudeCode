#!/bin/bash
# finfra/claude — Claude Code 클라이언트 컨테이너 PID 1 (이미 USER=ubuntu)
#
#   step1~5 공용. 백엔드 주소는 이미지에 굽지 않고 아래 우선순위로 런타임 결정한다:
#
#     1) CC_BASE_URL          전체 URL 직접 지정      ex) http://192.168.0.4:8080   (step5·원격 LAN)
#     2) ANTHROPIC_BASE_URL   docker run -e 로 이미 준 경우 그대로 사용
#     3) GW_HOST[:GW_PORT]    게이트웨이 경유         ex) gateway:8080              (step3·step4)
#     4) LMS_HOST[:LMS_PORT]  LMS 직결                ex) lms:1234                  (step1·step2)
#     5) 기본값 http://gateway:8080
#
#   부가 모드 (컨테이너를 띄우지 않고 설정만 뽑을 때):
#     docker run --rm -e CC_BASE_URL=http://192.168.0.4:8080 -e CC_MODEL=gemma-4-e2b-it \
#       finfra/claude:latest settings
#   → Windows(%USERPROFILE%\.claude\settings.json)에 그대로 붙여넣을 JSON 을 stdout 으로 출력.
#     step5 의 settings.json.sample 을 손으로 관리하지 않아도 되게 하는 경로다.
set -e

# ── 백엔드 주소 결정 ───────────────────────────────────────────────────────
if [ -n "${CC_BASE_URL:-}" ]; then
  BASE_URL="$CC_BASE_URL"
elif [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
  BASE_URL="$ANTHROPIC_BASE_URL"
elif [ -n "${GW_HOST:-}" ]; then
  BASE_URL="http://${GW_HOST}:${GW_PORT:-8080}"
elif [ -n "${LMS_HOST:-}" ]; then
  BASE_URL="http://${LMS_HOST}:${LMS_PORT:-1234}"
else
  BASE_URL="http://gateway:8080"
fi
BASE_URL="${BASE_URL%/}"

MODEL="${CC_MODEL:-${ANTHROPIC_MODEL:-${LMS_MODEL:-}}}"
AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-lms}"
MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-8192}"
TIMEOUT_MS="${API_TIMEOUT_MS:-600000}"

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

# ── settings.json 본문 생성 ────────────────────────────────────────────────
#   ⚠️ X-Session 은 여기에 넣지 않는다 — settings.json 의 env 가 셸 export 보다 우선하므로
#      정적 값이면 **모든 세션이 한 백엔드에 고정**되어 분산이 죽는다(아래 '세션 고정' 참조).
render_settings() {
  cat <<JSON
{
  "model": "${MODEL}",
  "env": {
    "ANTHROPIC_BASE_URL": "${BASE_URL}",
    "ANTHROPIC_AUTH_TOKEN": "${AUTH_TOKEN}",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "${MAX_OUTPUT_TOKENS}",
    "API_TIMEOUT_MS": "${TIMEOUT_MS}",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  },
  "permissions": {
    "deny": [
      ${DENY_LIST}
    ]
  }
}
JSON
}

# 설정만 출력하고 종료 (step5 Windows 배포용 — 컨테이너를 띄우지 않는다)
case "${1:-}" in
  settings|--print-settings)
    render_settings
    exit 0
    ;;
esac

mkdir -p "$HOME/.claude"
render_settings > "$HOME/.claude/settings.json"
echo "[entrypoint] base_url=${BASE_URL} model=${MODEL:-<unset>} diet=${CLAUDE_DIET}"

# ── 백엔드 도달 확인 ───────────────────────────────────────────────────────
#   여기서 실패하면 이후 'cc' 1턴도 반드시 실패한다. 기동 시점에 드러내서
#   "Claude 문제"로 오진하는 것을 막는 게 목적(기동 게이팅).
#   CC_WAIT=0 이면 생략 — 백엔드를 나중에 띄우는 개발 흐름용.
CC_WAIT="${CC_WAIT:-1}"
CC_WAIT_TRIES="${CC_WAIT_TRIES:-30}"
if [ "$CC_WAIT" != "0" ]; then
  # http://host:port → host 만 추출 (getent 는 URL 을 못 읽는다)
  URL_HOSTPORT="${BASE_URL#*://}"
  URL_HOST="${URL_HOSTPORT%%:*}"
  URL_HOST="${URL_HOST%%/*}"

  # IP 리터럴이면 이름 해석 검사를 건너뛴다(step5 처럼 LAN IP 직접 지정하는 경우)
  if [[ "$URL_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || getent hosts "$URL_HOST" >/dev/null 2>&1; then
    echo "[entrypoint] waiting for backend at ${BASE_URL} ..."
    TRIES=0
    until curl -fsS "${BASE_URL}/v1/models" >/dev/null 2>&1; do
      TRIES=$((TRIES+1))
      if [ "$TRIES" -ge "$CC_WAIT_TRIES" ]; then
        echo "[entrypoint] WARNING: backend unreachable after $((CC_WAIT_TRIES*2))s — continuing anyway"
        echo "[entrypoint]   확인: curl ${BASE_URL}/v1/models · 게이트웨이 로그(502·host not found in upstream)"
        break
      fi
      echo "[entrypoint] backend unavailable - sleeping (${TRIES}/${CC_WAIT_TRIES})"
      sleep 2
    done
    curl -fsS "${BASE_URL}/v1/models" >/dev/null 2>&1 \
      && echo "[entrypoint] backend is up - starting Claude Code environment"
  else
    echo "[entrypoint] WARNING: host '${URL_HOST}' not resolvable — CC_BASE_URL / GW_HOST / --network 확인"
  fi
fi

# ── 세션 고정 (X-Session affinity) ─────────────────────────────────────────
#   백엔드가 2개 이상일 때만 의미가 있다. 셸마다 고유한 X-Session 헤더를 주입하면
#   게이트웨이가 consistent hash 로 같은 백엔드에 고정한다. 없으면 세션 후속 턴이 다른
#   백엔드로 떨어져 매번 전체 컨텍스트를 재프리필한다(30k 토큰 기준 6.2s vs 0.49s ≈ 13배).
#   에러 없이 느려지기만 해서 발견이 어렵다. 단일 백엔드에서도 무해하므로 기본 활성.
#   $$(셸 PID)+$RANDOM 은 셸 기동 시 평가되므로 세션(셸)별로 값이 다르다.
CC_AFFINITY="${CC_AFFINITY:-1}"
if [ "$CC_AFFINITY" != "0" ]; then
  AFFINITY_LINE='export ANTHROPIC_CUSTOM_HEADERS="X-Session: cc-$$-$RANDOM"'
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    grep -qs 'ANTHROPIC_CUSTOM_HEADERS' "$rc" || echo "$AFFINITY_LINE" >> "$rc"
  done

  #   rc 파일은 로그인/대화형 셸에서만 읽힌다 — 'docker exec <cc> claude' 처럼 셸을 거치지 않는
  #   진입은 헤더 없이 나가고, 게이트웨이가 $request_id 로 해시해 매 턴 다른 백엔드로 흩어진다.
  #   PATH 선순위 shim 으로 어떤 진입 경로에서도 헤더를 보장한다.
  #   (이미지 ENV PATH 가 ~/.local/bin 을 앞에 두므로 docker exec 에도 적용된다)
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/claude" <<'SHIM'
#!/bin/bash
# X-Session affinity shim — 이미 설정돼 있으면(대화형 셸 경유) 그 값을 존중한다.
[ -n "${ANTHROPIC_CUSTOM_HEADERS:-}" ] || export ANTHROPIC_CUSTOM_HEADERS="X-Session: cc-$$-$RANDOM"
exec /usr/bin/claude "$@"
SHIM
  chmod +x "$HOME/.local/bin/claude"
else
  rm -f "$HOME/.local/bin/claude"
fi

# 편의 alias — /home/ubuntu 가 named volume 으로 덮이면 이미지의 /etc/bash.bashrc 만으로는
#   부족한 경우가 있어 홈에도 둔다.
grep -qs "alias cc=" "$HOME/.bashrc" \
  || echo "alias cc='claude --dangerously-skip-permissions'" >> "$HOME/.bashrc"

exec "$@"
