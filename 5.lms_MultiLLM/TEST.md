# 5.lms_MultiLLM 멀티 백엔드 검증 절차 (compose 판)

lms:small 2백엔드 기준. 실측 결과·판별 신호 상세는
`_doc_work/report/lms-small-dispatch-verify_report.md` 참조.
2026-07-16 실기동 검증 완료 (아래 기대값은 그 실측치).

백엔드 컨테이너 이름: `air_gap_claude_code_lms_multi-lms-1`, `-lms-2`
(compose `--scale` 자동 네이밍 — 아래에서 `lms-N` 으로 표기)

## 0) 기동

```bash
cp .env.org .env        # LMS_IMAGE=lms:small, LMS_MODEL=google/gemma-4-e2b,
                        # LMS_CONTEXT_LENGTH=131072, CLAUDE_MAX_OUTPUT_TOKENS=32000
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --scale lms=2
# ⚠️ '--build' 금지 — Dockerfile.lms 재빌드가 lms:small 태그를 덮어씀
docker compose ps       # lms×2 (healthy) → gateway (healthy) → claude 순 기동 확인
```

## 1) 모델 로드 + VRAM

```bash
docker exec <lms-N> bash -c 'lms ps'
#   기대: google/gemma-4-e2b · CONTEXT 131072 · PARALLEL 1 (양쪽 모두)
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
#   기대: 백엔드당 ~3.7GB, 총 ~7.5GB 사용 / ~8.6GB 여유
#   ⚠️ GPU 0MiB 면 CPU 로드 — .env 의 LMS_GPU=max 확인 (빈값=자동은 CPU 로드 사례 있음)
```

## 2) 게이트웨이 추론 + 분산

```bash
curl -fsS http://127.0.0.1:8080/v1/models     # 모델 목록 반환 확인
for i in 1 2 3 4; do curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
  -X POST http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"google/gemma-4-e2b","messages":[{"role":"user","content":"Say pong."}],"max_tokens":30}'; done
#   기대: 4회 모두 200

# 분산 확인 — 백엔드별 처리 건수 (양쪽 모두 0 이 아니어야 함. 실측 2:2)
docker logs <lms-1> 2>&1 | grep -c 'type: llm.prediction.input'
docker logs <lms-2> 2>&1 | grep -c 'type: llm.prediction.input'
```

## 3) 사용 중/유휴 실시간 판별

```bash
docker exec -it <lms-N> bash -lc 'watch -n2 lms ps'   # STATUS: IDLE ↔ GENERATING

# 서버 동작 실시간 관찰 — 요청 수신·프롬프트 진행률·토큰 속도(tok/s)가 그 자리에서 찍힘.
#   백엔드별 터미널에 하나씩 띄워 두면 어느 쪽이 처리하는지 즉시 식별됨.
#   --source: model(기본, 프롬프트 입/출력) / server(HTTP·타이밍) / runtime. --stats·--json 병용 가능.
docker exec -it <lms-N> bash -lc 'lms log stream --source server'
#   예: [INFO] Running Anthropic messages API on conversation with 7 messages.
#       [INFO] Prompt processing progress: 86.7% ... prompt eval 574 tok/s, eval 88 tok/s
```

* VRAM 은 판별 수단이 아님 — 선할당이라 처리 중에도 불변 (실측 180샘플 단일값).
* ⚠️ 이 폴더(5판)의 nginx 는 `server lms:PORT resolve` 단일 엔트리라 **세션 고정이 성립하지 않음**(요청 단위 라운드로빈). 세션 고정이 필요하면 `6.lms_MultiLLM_run` 방식(개별 `server lms-1..N` 엔트리 + consistent hash)을 쓸 것 — 2026-07-18 실측.

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
#   기대: BANANA-7742 (prompt_tokens ≈ 40046, 실측 ~13s)
```

## 5) Claude Code 종단

```bash
docker exec claude bash -lc 'claude -p "1+1은? 숫자만 답해."'   # 기대: 2
# 대화형: docker exec -it claude bash → cc
```

## 정리

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml down   # 볼륨 유지
```
