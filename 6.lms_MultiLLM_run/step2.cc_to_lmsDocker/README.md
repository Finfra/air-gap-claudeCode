---
name: README
description: step2 — docker cc → docker lms 직결. lms 이미지·모델 로드·컨테이너 간 DNS 검증
date: 2026-07-20
---

# 목적

```
[docker: claude] ──→ lms:1234 ──→ [docker: lms]  (사용자 정의 네트워크)
```

step1 에서 cc 가 정상임이 확정된 상태에서 **LMS 를 호스트에서 컨테이너로 바꾸는 것 하나만** 추가한다. 여기서 실패하면 원인은 lms 이미지 또는 `entrypoint.lms.sh`.

검증 대상:

* lms 이미지의 llmster 데몬 기동 → `lms server start --bind 0.0.0.0`
* **0.0.0.0 바인딩 실증** (loopback 전용으로 붙는 실측 사례 있음 — 컨테이너 내부 curl 은 성공하나 외부에서 못 붙는 조용한 고장)
* 폐쇄망 모델 로드: `LMS_SKIP_GET=1`(허브 접속 완전 생략) + 로컬 키 폴백
* JIT 로딩 비활성화(기본값 ctx 8192/parallel 4 로 임의 로드되는 사고 차단)
* 컨테이너 간 Docker DNS(`lms` 이름 해석)

# 구현 방법

## 구성 파일

| 파일                | 역할                                                 |
| :------------------ | :--------------------------------------------------- |
| `.env.org`          | 파라미터 템플릿                                      |
| `entrypoint.lms.sh` | lms 컨테이너 PID1 (`cf_old/entrypoint.lms.sh` 계승)  |
| `entrypoint.cc.sh`  | step1 판에서 `LMS_HOST` 기본값을 `lms` 로 전환 + 호스트 전용 진단 문구(`--add-host`·브릿지 IP) 제거 |
| `run.sh`            | 네트워크 생성 → lms 기동 → 헬스 폴링 → cc 기동. `--check`/`--logs`/`--stop`/`--status` |

`run.sh` 는 `cf_old/start.sh` 를 **백엔드 1개·게이트웨이 없음**으로 축약한 형태. 게이트웨이 관련 로직(nginx 템플릿, upstream 생성, 게이트웨이 헬스 폴링)은 이 단계에 넣지 않는다.

## 주요 파라미터 (`.env`)

| 키                   | 기본값                   | 비고                                                       |
| :------------------- | :----------------------- | :--------------------------------------------------------- |
| `LMS_MODEL`          | `gemma-4-e2b-it`         | **로컬 키**를 쓸 것(허브 키는 폴백 경로 유발 — 게이트 1-2). A6000 은 `gemma-4-31b-it-qat` |
| `LMS_IMAGE`          | `lms:small`              | 이름과 달리 31b-QAT + E2B 를 **둘 다** 내장(22GB) — 모델 키만 바꿔 양쪽 환경 대응 |
| `LMS_CONTEXT_LENGTH` | `32768`                  | Claude Code 시스템+도구 페이로드 대응 최소치               |
| `LMS_PARALLEL`       | `1`                      | **필수.** 슬롯 분할(ctx/슬롯수) 시 500 (`n_keep >= n_ctx`) |
| `LMS_GPU`            | `max`                    | e2b(4.4GB)는 전량 탑재 가능. 16GB GPU 에서 31b 를 쓸 때만 `0.6` 등 부분 offload |
| `LMS_SKIP_GET`       | `1`                      | 폐쇄망 필수. 허브 확인이 blackhole 방화벽에서 hang         |
| `LMS_MODEL_MOUNT`    | (빈값)                   | **빈값 = 마운트 없음**(이미지 내장 모델 사용). 빈 named volume 을 물리면 내장 모델이 가려진다 |
| `LMS_PUBLISH_PORT`   | (빈값)                   | 호스트 노출은 디버깅용 선택. 판정 기준은 cc 컨테이너에서의 접근 |
| `USE_GPU`            | `1`                      | 0=CPU 강제                                                 |

## 실행 절차

> 컨테이너 이름은 `.env` 기준 **lms** / **cc-step2** 이다(`CLAUDE_CONTAINER_NAME`).
> 단계별로 이름을 분리해 둔 것이므로 다른 단계의 컨테이너와 혼동하지 말 것.

```bash
cd step2.cc_to_lmsDocker
cp .env.org .env && vi .env

# 0) 이미지 확인
docker image inspect lms:small claude:latest >/dev/null && echo OK

# 1) 기동
./run.sh

# 2) 게이트 자동 판정 (1·1-2·2·3·5)
./run.sh --check

# 3) 수동 확인 — 바인딩 (핵심)
docker logs lms | grep -E 'bind OK|loopback'
docker exec cc-step2 curl -fsS http://lms:1234/v1/models    # ← 컨테이너 '밖'에서 접근

# 4) 모델 실제 로드 여부
#    lms 는 PATH 에 없으므로 로그인 셸 + PATH 지정이 필요하다
docker exec lms sh -lc 'PATH=$HOME/.lmstudio/bin:$PATH lms ps'

# 5) Claude Code 1턴 (게이트 4)
docker exec -it cc-step2 bash
cc

#    비대화형으로 판정만 할 때
docker exec cc-step2 bash -lc 'claude --dangerously-skip-permissions -p "Reply with exactly: PONG"'
```

# 성공 판정 (게이트)

`./run.sh --check` 가 1·1-2·2·3·5 를 자동 판정한다(4 는 수동).

1. `docker logs lms` 에 `[lms] bind OK — 0.0.0.0:1234` 출력
2. `docker exec cc-step2 curl http://lms:1234/v1/models` → 200 (**cc 컨테이너에서** 접근되어야 함. lms 내부 curl 성공은 판정 근거가 아님)
3. `docker exec lms lms ps` 에 모델이 `LMS_CONTEXT_LENGTH` 로 로드되어 표시
4. `cc` 1턴 응답 성공
5. GPU 사용 시 `nvidia-smi` VRAM 사용률 **≤ 83%** (로드 후. 초과 시 장문 프롬프트에서 CUDA OOM)

**1-2. 허브 키 폴백 없음** — `docker logs lms` 에 `허브 키 로드 실패` 가 없어야 한다.
`LMS_MODEL` 에 허브 키(`google/gemma-4-e2b`)를 쓰면 `lms load` 가 1회 실패한 뒤 폴백으로 겨우
로드된다. 동작은 하지만 기동이 느려지고 로그가 실패로 오염되므로 반입본에 남기지 않는다.
`.env` 에는 `lms ls` 가 보여주는 **로컬 키**(`gemma-4-e2b-it`)를 쓸 것.

## 실측 결과 (fg1, 2026-07-20) — 전 게이트 통과

| 게이트        | 결과                              |
| :------------ | :-------------------------------- |
| 1 bind OK     | ✅ `0.0.0.0:1234`                  |
| 1-2 폴백 없음 | ✅                                 |
| 2 cc→lms 200  | ✅ `gemma-4-e2b-it`                |
| 3 모델 로드   | ✅ 4.41GB · ctx 32768 · parallel 1 |
| 4 `cc` 1턴    | ✅ `PONG`                          |
| 5 VRAM        | ✅ 3,284/16,380 MiB = 20.0%        |

# 실패 시 진단 순서

| 증상                                    | 확인                                                                                                                           |
| :-------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------- |
| lms 로그에 `loopback 전용으로 바인딩됨` | `--bind 0.0.0.0` 미반영 — 컨테이너 재기동, 반복되면 `lms server stop && lms server start --port 1234 --bind 0.0.0.0` 수동 재현 |
| 기동이 수 분 hang                       | `LMS_SKIP_GET=0` 상태에서 허브 접속 — `1` 로 변경                                                                              |
| 모델 로드 실패                          | 허브 키 ≠ 로컬 키. `docker exec lms lms ls` 로 실제 키 확인 후 `.env` 반영                                                     |
| `cc` 가 500                             | `LMS_PARALLEL` 이 1 이 아님, 또는 `LMS_CONTEXT_LENGTH` < 32768                                                                 |
| 장문에서만 크래시                       | VRAM 83% 초과 — `LMS_GPU` 부분 offload 또는 ctx 축소                                                                           |
