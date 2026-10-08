---
name: README
description: step3 — docker cc → docker gateway → docker lms. nginx 게이트웨이 계층만 추가 검증
date: 2026-07-20
---

# 목적

```
[docker: claude] ──→ gateway:8080 ──→ lms-1:1234 ──→ [docker: lms-1]
```

step2 에서 cc·lms 직결이 확정된 상태에서 **게이트웨이(nginx) 한 계층만** 끼운다. 이전 반입 실패 3대 증상 중 "게이트웨이 경유 접근 실패"를 정면으로 격리하는 단계.

검증 대상:

* nginx `upstream` + `resolve` + `zone` 조합 (기동 순서 역전·백엔드 IP 변경 내성)
* `envsubst` 템플릿 전개 (`${LMS_UPSTREAM_SERVERS}` 주입)
* **SSE 스트리밍 보존** (`proxy_buffering off` — 켜져 있으면 토큰 스트림이 깨짐)
* 장시간 추론 타임아웃 (`proxy_read_timeout 600s`)
* 대용량 요청 본문 (`client_max_body_size 64m` — 도구 스키마 페이로드)

**이 단계를 통과한 `lms:latest` 가 폐쇄망 반입 대상 이미지다.**

# 구현 방법

## 구성 파일

| 파일 | 역할 |
| :--- | :--- |
| `.env.org` | 파라미터 템플릿 |
| `entrypoint.lms.sh` | step2 통과본 그대로 |
| `entrypoint.cc.sh` | `LMS_HOST` 대신 `GW_HOST/GW_PORT` 대기로 전환 |
| `nginx.conf.template` | 게이트웨이 설정 (`cf_old/nginx.conf.template` 계승) |
| `run.sh` | 네트워크 → lms-1 → 헬스 → gateway → 헬스 → cc |

`nginx.conf.template` 은 `/etc/nginx/templates/default.conf.template` 로 `:ro` bind mount 하고, `LMS_PORT`·`LMS_UPSTREAM_SERVERS` 를 환경변수로 주입하여 이미지 재빌드 없이 교체 가능하게 한다.

> ⚠️ **단일 `server lms:1234 resolve` 금지.** DNS 라운드로빈으로 해석된 IP 들을 nginx 가
> hash 대상으로 구분하지 못해 세션 고정이 무효화된다(2026-07-18 실측). `run.sh` 가
> `LMS_BACKEND_COUNT` 만큼 `server lms-N:1234 resolve ...` 엔트리를 생성해 주입한다.
> `zone lms_backends 64k` 와 각 server 의 `resolve` 는 **한 쌍** — 하나만 있으면 기동 실패
> 또는 IP 고착(502)이 발생한다.

## 실행 절차

> 컨테이너 이름은 `.env` 기준 **lms-1** / **gateway** / **cc-step3**.

```bash
cd step3.cc_gw_lms
cp .env.org .env && vi .env       # LMS_BACKEND_COUNT=1 고정 (run.sh 가 강제)

# 1) 게이트웨이 설정 정적 검증 (기동 전) — 게이트 1
./run.sh --nginx-test

# 2) 기동 (위 정적 검증을 내장 실행하며, 실패 시 컨테이너를 세우지 않는다)
./run.sh

# 3) 게이트 자동 판정 (2·3 + 백엔드 직접 도달 + 전개된 nginx 지시어 + VRAM)
./run.sh --check

# 4) SSE 스트리밍 — 게이트 4
./run.sh --sse

# 5) 백엔드 재기동 내성 — 게이트 6
./run.sh --resilience

# 6) Claude Code 1턴
docker exec -it cc-step3 bash && cc
#    비대화형 판정
docker exec cc-step3 bash -lc 'claude --dangerously-skip-permissions -p "Reply with exactly: PONG"'
```

> ⚠️ **`nginx -t` 를 직접 돌릴 때 bare `envsubst` 를 쓰지 말 것.** 인자 없는 `envsubst` 는
> nginx 자신의 런타임 변수(`$http_x_session`·`$request_id`·`$host`)까지 환경변수로 보고
> **빈 문자열로 치환**한다. `map  {` 처럼 인자가 사라져
> `invalid number of arguments in "map" directive` 로 실패하는데, **설정은 멀쩡하고 검증만
> 실패하는 가짜 경보**다(2026-07-20 실측). 치환 대상을 명시 한정해야 한다:
>
> ```bash
> envsubst '${LMS_PORT} ${LMS_UPSTREAM_SERVERS}' < tmpl > default.conf && nginx -t
> ```
>
> 런타임은 nginx 공식 이미지 entrypoint 가 정의된 env 목록으로 한정하므로 정상 동작한다.

# 성공 판정 (게이트)

1. `nginx -t` 통과 (기동 전 정적 검증) — `./run.sh --nginx-test`
2. 호스트 `curl http://127.0.0.1:8080/v1/models` → 200
3. cc 컨테이너 `curl http://gateway:8080/v1/models` → 200
4. **SSE 스트리밍**: `data:` 청크가 응답 완료 전에 순차 도착 — `./run.sh --sse` 가 청크별 도착 시각을 찍는다. 첫/마지막 시각이 벌어져야 ✅ (모두 같은 시각이면 버퍼링이 살아 있는 것 → 실패)
5. **대용량·장문 완주** — 504/413 없음
6. **재기동 내성**: `docker restart lms-1` 후 30초 내 게이트웨이가 502 없이 복구 (`zone`+`resolve` 동작) — `./run.sh --resilience`

## 실측 결과 (fg1, 2026-07-20) — 전 게이트 통과

| 게이트 | 결과 |
| :----- | :--- |
| 1 `nginx -t` | ✅ `test is successful` |
| 2 호스트→GW | ✅ 200 `gemma-4-e2b-it` |
| 3 cc→GW | ✅ 200 |
| 4 SSE | ✅ 112 청크가 **+1.31s ~ +2.36s** 에 분산 도착 |
| 5 대용량 | ✅ 90KB 본문(20,024 tok) → 200, 3.70s. 176KB(40k tok)는 nginx 통과 후 LMS 가 정당한 400(ctx 초과) — **413 아님 → `client_max_body_size 64m` 유효** |
| 6 재기동 내성 | ✅ 백엔드 ready 기준 **0s** 복구 |
| + `cc` 1턴 / 도구 | ✅ `PONG` / `STEP3_TOOL_OK` |
| + VRAM | ✅ 20.0% |

# 실패 시 진단 순서

| 증상 | 확인 |
| :--- | :--- |
| gateway 컨테이너가 재시작 루프 | `docker logs gateway` — `host not found in upstream` 이면 lms-1 보다 먼저 기동됨 + `resolve`/`zone` 누락 |
| 502 지속 | `docker exec gateway getent hosts lms-1` 로 이름 해석 확인. 해석되면 lms 바인딩(step2 게이트 1번) 재확인 |
| `/v1/models` 200 인데 `cc` 만 실패 | `client_max_body_size` 부족(413) 또는 `CLAUDE_MAX_OUTPUT_TOKENS` 과대 |
| 응답이 한꺼번에 도착 | `proxy_buffering off` 미적용 — 템플릿 전개 결과를 `docker exec gateway cat /etc/nginx/conf.d/default.conf` 로 확인 |
| 장문에서 504 | `proxy_read_timeout`·`API_TIMEOUT_MS` 상향, GPU 런타임이 CPU(avx2)로 선택되지 않았는지 `docker logs lms-1 \| grep runtime` 확인 |
