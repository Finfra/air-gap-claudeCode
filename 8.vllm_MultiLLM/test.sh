#!/bin/bash
# 8.vllm_MultiLLM 종단 점검 — 기동 완료 후 실행
#   1 복제본 상태 · 2 TurboQuant 적용 · 3 게이트웨이 /v1/models · 4 OpenAI chat
#   5 Anthropic /v1/messages · 6 분산(헤더 없음) · 7 세션 고정(X-Session)
#   8 Claude Code 응답 · 9 Claude Code tool call(Write)
#   SKIP_CLAUDE=1 이면 8·9 생략
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
BASE="http://localhost:${GATEWAY_PORT:-8080}"
MODEL="${SERVED_MODEL_NAME:-local-llm}"
PROJECT="${COMPOSE_PROJECT_NAME:-air_gap_claude_code_vllm_multi}"
CLAUDE="${CLAUDE_CONTAINER_NAME:-vllm-claude}"

FAIL=0
pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; FAIL=1; }

# 응답 헤더의 X-Upstream (어느 백엔드가 받았나)
upstream_of() {  # <path> <body> [X-Session]
  local hdr=()
  [ -n "${3:-}" ] && hdr=(-H "X-Session: $3")
  curl -s -o /dev/null -D - "$BASE$1" -H "Content-Type: application/json" "${hdr[@]}" -d "$2" \
    | awk -F': ' 'tolower($1)=="x-upstream"{gsub("\r","",$2); print $2}'
}

echo "== 1. 복제본 상태"
mapfile -t BACKENDS < <(docker ps --filter "label=com.docker.compose.project=$PROJECT" \
  --filter "label=com.docker.compose.service=vllm" --format '{{.Names}} {{.Status}}')
for b in "${BACKENDS[@]}"; do
  [[ "$b" == *"(healthy)"* ]] && pass "$b" || fail "$b"
done
[ "${#BACKENDS[@]}" -gt 0 ] || fail "vllm 복제본 없음"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader | sed 's/^/  GPU 메모리: /'

echo "== 2. TurboQuant KV cache 적용 (기동 로그)"
for b in "${BACKENDS[@]}"; do
  name="${b%% *}"
  kv=$(docker logs "$name" 2>&1 | grep -oE "kv_cache_dtype=[a-z0-9_]+" | tail -1)
  tok=$(docker logs "$name" 2>&1 | grep -oE "GPU KV cache size: [0-9,]+ tokens" | tail -1)
  [ "$kv" = "kv_cache_dtype=${KV_CACHE_DTYPE}" ] && pass "$name $kv · $tok" || fail "$name 기대 ${KV_CACHE_DTYPE} / 실제 '${kv}'"
done

echo "== 3. 게이트웨이 /v1/models"
models=$(curl -sf "$BASE/v1/models") && [[ "$models" == *"\"$MODEL\""* ]] \
  && pass "$MODEL 노출" || fail "/v1/models 실패: ${models:0:200}"

echo "== 4. OpenAI /v1/chat/completions"
out=$(curl -sf "$BASE/v1/chat/completions" -H "Content-Type: application/json" -d "{
  \"model\": \"$MODEL\", \"max_tokens\": 64,
  \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: PONG\"}]}")
[[ "$out" == *PONG* ]] && pass "응답에 PONG" || fail "${out:0:300}"

echo "== 5. Anthropic /v1/messages (Claude Code 가 쓰는 경로)"
out=$(curl -sf "$BASE/v1/messages" -H "Content-Type: application/json" \
  -H "x-api-key: vllm" -H "anthropic-version: 2023-06-01" -d "{
  \"model\": \"$MODEL\", \"max_tokens\": 64,
  \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: PONG\"}]}")
[[ "$out" == *'"type":"message"'* && "$out" == *PONG* ]] && pass "message 응답에 PONG" || fail "${out:0:300}"

PING='{"model":"'"$MODEL"'","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
echo "== 6. 분산 — X-Session 없는 요청 12회"
dist=$(for i in $(seq 12); do upstream_of /v1/chat/completions "$PING"; done | sort | uniq -c)
echo "$dist" | sed 's/^/    /'
n=$(echo "$dist" | grep -c .)
if [ "${#BACKENDS[@]}" -le 1 ]; then pass "백엔드 1개 — 분산 판정 생략"
elif [ "$n" -ge 2 ]; then pass "백엔드 ${n}곳으로 분산"; else fail "한 백엔드로만 감"; fi

echo "== 7. 세션 고정 — 세션 4개 × 같은 X-Session 8회"
for s in sess-A sess-B sess-C sess-D; do
  u=$(for i in $(seq 8); do upstream_of /v1/chat/completions "$PING" "$s"; done | sort -u)
  [ "$(echo "$u" | grep -c .)" -eq 1 ] && pass "$s → $u 고정" || fail "$s 가 여러 백엔드로: $(echo $u)"
done

if [ "${SKIP_CLAUDE:-0}" != "1" ]; then
  echo "== 8. Claude Code 응답 (claude -p → 게이트웨이 → vLLM /v1/messages)"
  out=$(docker exec "$CLAUDE" bash -lc 'cd ~ && timeout 300 claude -p "Reply with exactly one word: PONG" 2>&1')
  [[ "$out" == *PONG* ]] && pass "claude -p 응답: $(echo "$out" | tail -1 | cut -c1-80)" || fail "claude -p: ${out:0:300}"
  # 카탈로그에 없는 모델은 `[claude-code:unrecognized_model]` 진단 한 줄이 항상 찍힌다(정보성).
  #   컨텍스트 창을 못 받았을 때만 «200k 로 가정» 경고가 붙는다 → 그것만 실패로 본다
  if [[ "$out" == *"context window it assumes"* ]]; then
    fail "Claude Code 가 컨텍스트 창을 200k 로 가정 — CLAUDE_CODE_MAX_CONTEXT_TOKENS 전달 확인"
  else
    pass "컨텍스트 창 ${MAX_MODEL_LEN:-32768} 인식 (200k 가정 경고 없음)"
  fi

  echo "== 9. Claude Code tool call — Write 도구로 파일 생성"
  f="tooltest-$$.txt"
  docker exec "$CLAUDE" rm -f "/home/ubuntu/$f"
  out=$(docker exec "$CLAUDE" bash -lc "cd ~ && timeout 300 claude --dangerously-skip-permissions -p 'Use the Write tool to create the file /home/ubuntu/$f containing exactly the text TOOL_OK. Do not explain.' 2>&1")
  got=$(docker exec "$CLAUDE" cat "/home/ubuntu/$f" 2>/dev/null)
  [[ "$got" == *TOOL_OK* ]] && pass "~/$f = $got" || fail "파일 미생성 — claude 출력: ${out:0:300}"
  docker exec "$CLAUDE" rm -f "/home/ubuntu/$f"
fi
echo
[ $FAIL -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
