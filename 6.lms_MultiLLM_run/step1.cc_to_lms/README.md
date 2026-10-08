---
name: README
description: step1 — docker cc → 호스트 LMS 직결. cc 컨테이너와 OpenAI /v1 직결만 격리 검증
date: 2026-07-20
---

# 목적

```
[docker: claude] ──→ host.docker.internal:1234 ──→ [호스트 LM Studio]
```

**cc(Claude Code) 컨테이너 하나만 변수로 둔다.** LMS 는 호스트에 이미 설치·검증된 것을 그대로 쓰므로, 여기서 실패하면 원인은 100% cc 쪽(이미지·환경변수·네트워크 탈출)임.

검증 대상:

* `claude:latest` 이미지가 폐쇄망에서 기동되는가 (외부망 호출 없이)
* `ANTHROPIC_BASE_URL` 이 OpenAI `/v1` 백엔드를 직접 가리키는 구성(변환 게이트웨이 없음)이 성립하는가
* 컨테이너 → 호스트 도달 경로(`host.docker.internal`)가 Linux 에서 열리는가

검증 대상 **아님**: lms 이미지, 게이트웨이, 다중 백엔드, Windows.

# 구현 방법

## 구성 파일

| 파일               | 역할                                                                                    |
| :----------------- | :-------------------------------------------------------------------------------------- |
| `.env.org`         | 파라미터 템플릿 → `cp .env.org .env` 후 수정                                            |
| `entrypoint.cc.sh` | cc 컨테이너 PID1. `~/.claude/settings.json` 생성 + 백엔드 헬스 대기 + 프롬프트 다이어트 |
| `run.sh`           | `docker run` 1개만 수행. `--stop`/`--status` 서브커맨드                                 |

`cf_old/entrypoint.sh` 를 기반으로 하되 **게이트웨이 대기 로직을 LMS 직결로 치환**한다(`GW_HOST/GW_PORT` → `LMS_HOST/LMS_PORT`). X-Session affinity shim 은 이 단계에서 불필요하므로 넣지 않는다(단일 백엔드).

## 주요 파라미터 (`.env`)

| 키                         | 기본값                    | 비고                                         |
| :------------------------- | :------------------------ | :------------------------------------------- |
| `LMS_HOST`                 | `host.docker.internal`    | 호스트 LMS 주소                              |
| `LMS_PORT`                 | `1234`                    |                                              |
| `LMS_MODEL`                | (호스트에 로드된 모델 키) | `curl host:1234/v1/models` 로 확인한 실제 키 |
| `CLAUDE_MAX_OUTPUT_TOKENS` | `8192`                    | 컨텍스트 초과 500 방지                       |
| `CLAUDE_DIET`              | `1`                       | 도구 4개만 노출 (프롬프트 -84%)              |
| `MOUNT_CODE_DIR`           | (빈값)                    | 호스트 코드 폴더 마운트(선택)                |

## 실행 절차

```bash
cd step1.cc_to_lms
cp .env.org .env && vi .env

# 0) 사전 조건 — 호스트 LMS 가 0.0.0.0 바인딩으로 떠 있어야 함
curl -s http://127.0.0.1:1234/v1/models | head

# 1) 기동
./run.sh

# 2) 컨테이너 → 호스트 도달 확인
docker exec claude curl -fsS http://host.docker.internal:1234/v1/models

# 3) Claude Code 1턴 대화
docker exec -it claude bash
cc          # alias = claude --dangerously-skip-permissions
```

> **Linux 주의**: `host.docker.internal` 은 Docker Desktop 전용 이름. Linux 서버에서는
> `run.sh` 가 `--add-host=host.docker.internal:host-gateway` 를 붙인다. 그래도 안 되면
> `.env` 의 `LMS_HOST` 를 `docker network inspect bridge` 로 확인한 게이트웨이 IP(보통
> `172.17.0.1`)로 바꾼다.
>
> **호스트 LMS 바인딩**: LM Studio 가 `127.0.0.1` 로만 LISTEN 하면 컨테이너에서 절대
> 닿지 않는다. `lms server start --bind 0.0.0.0` 로 재기동 후 `ss -tlnp | grep 1234` 확인.

# 성공 판정 (게이트)

아래 3개를 **모두** 만족해야 step2 로 진행:

1. `docker exec claude curl -fsS http://$LMS_HOST:$LMS_PORT/v1/models` → HTTP 200 + 모델 목록
2. 컨테이너 안에서 `cc` 실행 → 프롬프트 1턴 응답 수신 (에러·타임아웃 없음)
3. `docker logs claude` 에 외부망(api.anthropic.com 등) 접속 시도 로그 없음

# 실패 시 진단 순서

| 증상                    | 확인                                                                                        |
| :---------------------- | :------------------------------------------------------------------------------------------ |
| curl 자체가 안 나감     | `docker exec claude getent hosts host.docker.internal` — 이름 해석 실패면 `--add-host` 누락 |
| 연결 거부(refused)      | 호스트 LMS 바인딩이 loopback 전용 — `--bind 0.0.0.0` 재기동                                 |
| 200 인데 `cc` 가 500    | 모델 컨텍스트 부족 — 호스트 LMS 를 `--context-length 32768 --parallel 1` 로 재로드          |
| `cc` 가 model not found | `.env` 의 `LMS_MODEL` 이 `/v1/models` 의 실제 키와 불일치                                   |
