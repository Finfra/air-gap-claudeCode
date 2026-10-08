#!/bin/bash
# 8.vllm_MultiLLM 스트리밍 채팅 테스트 — 게이트웨이 경유 (출력 끝에 tok/s·응답 백엔드 표시)
#   출처: fg1 ~/_git/__all/dockers/vllm_qwen38/chat.sh
#   사용: ./chat.sh "질문"            (thinking 끔 — 빠름)
#         THINK=1 ./chat.sh "질문"    (사고 과정 포함)
#         MAX_TOKENS=500 ./chat.sh "질문"
#         SESSION=s1 ./chat.sh "질문"       (X-Session 헤더 — 같은 값이면 같은 백엔드)
#         BASE_URL=http://<호스트>:8080 ./chat.sh "질문"   (원격 게이트웨이)
#   컨테이너 안에서 쓰려면 공유 볼륨에 복사: cp chat.sh ~/df/  → 컨테이너 /df/chat.sh
#   python3 표준 라이브러리만 사용 (호스트·컨테이너 공통)
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
PROMPT="${1:-파이썬으로 피보나치 함수 짜줘}"
BASE="${BASE_URL:-http://localhost:${GATEWAY_PORT:-8080}}"

PROMPT="$PROMPT" BASE="$BASE" MODEL="${SERVED_MODEL_NAME:-local-llm}" SESSION="${SESSION:-}" \
THINK="${THINK:-0}" MAX_TOKENS="${MAX_TOKENS:-300}" python3 -u - <<'PY'
import json, os, sys, time, urllib.error, urllib.request

body = {
    "model": os.environ["MODEL"],
    "messages": [{"role": "user", "content": os.environ["PROMPT"]}],
    "max_tokens": int(os.environ["MAX_TOKENS"]),
    "stream": True,
    "stream_options": {"include_usage": True},
    "chat_template_kwargs": {"enable_thinking": os.environ["THINK"] == "1"},
}
req = urllib.request.Request(os.environ["BASE"] + "/v1/chat/completions",
                             data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json",
                                      **({"X-Session": os.environ["SESSION"]} if os.environ["SESSION"] else {})})
t0 = time.time(); usage = None; in_reason = False
try:
    r = urllib.request.urlopen(req)
except urllib.error.URLError as e:
    sys.exit(f"❌ 서버 접속 실패 ({os.environ['BASE']}): {e.reason}\n"
             "   게이트웨이 미기동 또는 백엔드 로딩 중 — `curl -s <BASE>/v1/models` 가 200 이 될 때까지 대기")
upstream = r.headers.get("X-Upstream", "?")
with r:
    for raw in r:
        line = raw.decode().strip()
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        d = json.loads(line[6:])
        usage = d.get("usage") or usage
        if not d.get("choices"):
            continue
        delta = d["choices"][0]["delta"]
        if delta.get("reasoning"):
            if not in_reason:
                print("\033[2m[thinking] ", end=""); in_reason = True
            print(delta["reasoning"], end="", flush=True)
        if delta.get("content"):
            if in_reason:
                print("\033[0m\n"); in_reason = False
            print(delta["content"], end="", flush=True)
dt = time.time() - t0
n = usage["completion_tokens"] if usage else 0
print(f"\033[0m\n\n--- {n} tokens / {dt:.1f}s = {n/dt:.2f} tok/s · backend {upstream}")
PY
