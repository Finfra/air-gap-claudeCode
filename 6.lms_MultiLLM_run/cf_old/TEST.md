# 6.lms_MultiLLM_run 멀티 백엔드 검증 절차 (docker run 판)

lms:small 2백엔드 기준. 실측 결과·판별 신호 상세는
`_doc_work/report/lms-small-dispatch-verify_report.md` 참조.
2026-07-16 실기동 검증 완료 (아래 기대값은 그 실측치).

백엔드 컨테이너 이름: `lms-1`, `lms-2` (start.sh 고정 네이밍)

## 0) 기동

```bash
# .env: LMS_IMAGE=lms:small, LMS_MODEL=google/gemma-4-e2b,
#       LMS_CONTEXT_LENGTH=131072, LMS_GPU=max, LMS_BACKEND_COUNT=2,
#       LMS_MODEL_MOUNT=lms-models-small, CLAUDE_MAX_OUTPUT_TOKENS=32000
./start.sh
./start.sh --status     # lms-1·lms-2·gateway·claude 4컨테이너 Up 확인
```

## 1) 모델 로드 + VRAM

```bash
docker exec lms-N bash -c 'lms ps'
#   기대: google/gemma-4-e2b · CONTEXT 131072 · PARALLEL 1 (양쪽 모두)
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
#   기대: 백엔드당 ~3.95GB, 총 ~7.9GB 사용 / ~8.2GB 여유
#   ⚠️ GPU 0MiB 면 CPU 로드 — .env 의 LMS_GPU=max 확인 (빈값=자동은 CPU 로드 사례 있음)
```

## 2) 게이트웨이 추론 + 분산

```bash
curl -fsS http://127.0.0.1:8080/v1/models     # 모델 목록 반환 확인
for i in 1 2 3 4; do curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
  -X POST http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"google/gemma-4-e2b","messages":[{"role":"user","content":"Say pong."}],"max_tokens":30}'; done
#   기대: 4회 모두 200

# 분산 확인 — 백엔드별 처리 건수 (양쪽 모두 0 이 아니어야 함)
docker logs lms-1 2>&1 | grep -c 'type: llm.prediction.input'
docker logs lms-2 2>&1 | grep -c 'type: llm.prediction.input'
```

## 3) 사용 중/유휴 실시간 판별

```bash
docker exec -it lms-N bash -lc 'watch -n2 lms ps'   # STATUS: IDLE ↔ GENERATING
# GPU 사용률 병행: nvidia-smi pmon -s um  (pid ↔ 컨테이너는 docker top lms-N 의 llmworker)

# 서버 동작 실시간 관찰 — 요청 수신·프롬프트 진행률·토큰 속도(tok/s)가 그 자리에서 찍힘.
#   lms-1·lms-2 터미널에 하나씩 띄워 두면 어느 쪽이 처리하는지 즉시 식별됨.
#   --source: model(기본, 프롬프트 입/출력) / server(HTTP·타이밍) / runtime. --stats·--json 병용 가능.
docker exec -it lms-N bash -lc 'lms log stream --source server'
#   예: [INFO] Running Anthropic messages API on conversation with 7 messages.
#       [INFO] Prompt processing progress: 86.7% ... prompt eval 574 tok/s, eval 88 tok/s
```

* VRAM 은 판별 수단이 아님 — 선할당이라 처리 중에도 불변 (실측 180샘플 단일값).
* 세션 고정: `X-Session` 헤더가 있으면 그 세션은 한 백엔드에 고정(6절 참조), 헤더 없는 요청만 요청 단위 분산.

## 4) 32k 초과 컨텍스트 (needle 테스트)

~40k 토큰 프롬프트 중간에 비밀 코드를 심고 회수 확인:

```bash
python3 - <<'EOF'
import json
f = "The quick brown fox jumps over the lazy dog. " * 4000
t = f[:60000] + "\n[SECRET CODE: BANANA-7742]\n" + f[60000:]
json.dump({"model":"google/gemma-4-e2b","max_tokens":2000,
  "messages":[{"role":"user","content":t+"\n\nWhat is the SECRET CODE mentioned above? Answer with the code only."}]},
  open("/tmp/needle.json","w"))
EOF
curl -sS -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' --data @/tmp/needle.json | grep -o 'BANANA-[0-9]*' | head -1
#   기대: BANANA-7742 (prompt_tokens ≈ 40046, 실측 prefill ~12s)
```

## 5) Claude Code 종단

```bash
docker exec claude bash -lc 'claude -p "1+1은? 숫자만 답해."'   # 기대: 2
# 대화형: docker exec -it claude bash → cc
```

## 6) 세션 고정 (X-Session affinity — 2026-07-17 패치)

```bash
# 헤더 없음 → 요청 단위 분산 (기존 동작): 4회 후 양쪽 로그 카운트 모두 증가
for i in 1 2 3 4; do curl -sS -o /dev/null -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"google/gemma-4-e2b","messages":[{"role":"user","content":"pong"}],"max_tokens":10}'; done

# 같은 X-Session 값 → 항상 같은 백엔드 (한쪽 로그만 증가)
for i in 1 2 3; do curl -sS -o /dev/null -H 'X-Session: test-a' -X POST ... ; done

# CC 셸별 자동 주입 확인 (entrypoint 가 .bashrc/.profile 에 export 추가)
docker exec claude bash -lc 'echo $ANTHROPIC_CUSTOM_HEADERS'   # 기대: X-Session: cc-<pid>-<rand>
```

## 7) 프롬프트 다이어트 (CLAUDE_DIET=1 기본 — 2026-07-17 패치)

```bash
docker exec claude cat /home/ubuntu/.claude/settings.json   # 기대: permissions.deny 19개
# 백엔드 로그에서 프롬프트 크기 확인 — diet ≈3k 토큰 (full ≈19.4k)
docker exec claude bash -lc 'claude -p "12*34는? 숫자만."'
docker logs lms-1 2>&1 | grep -o 'n_tokens = [0-9]*' | tail -2   # (lms-2 도 확인)
# 전체 도구가 필요하면: .env 에서 CLAUDE_DIET=0 후 ./start.sh (claude 만 재생성돼도 됨)
```

## 정리 / 31b 복귀

```bash
./start.sh --stop
# 31b 단일 백엔드 복귀: cp .env.org .env && ./start.sh   (.env.org = 31b·lms:latest 운영 기본값)
```
