---
name: README
description: air-gap-claudeCode — 폐쇄망·오프라인 Claude Code 구동 Docker 환경 가이드
date: 2026-05-07
---

# 개요

**air-gap-claudeCode** — 폐쇄망(air-gap)·오프라인 환경에서 Claude Code 를 구동하기 위한 Docker 환경. 로컬 LLM 백엔드로 Ollama 또는 LM Studio(LMS)를 사용하여, 외부 네트워크 없이 모델 추론을 수행함. 여러 구성 중 선택해서 사용함.

| 디렉토리         | 구성                  | 용도                                                              |
| :--------------- | :-------------------- | :---------------------------------------------------------------- |
| `1.ollama_OneContainer` | 단일 컨테이너         | 빠른 시작·로컬 개발. Ollama + Claude Code가 한 컨테이너에 동거    |
| `2.ollama_TwoContainer` | 분리 컨테이너 2개     | 운영·다중 클라이언트. Ollama 서비스를 독립시켜 재시작·공유 용이   |
| `3.ollama_External`     | claude 컨테이너 1개   | 호스트/서버에 이미 설치된 외부 Ollama 에 claude 컨테이너만 연결 (일반 방식) |
| `4.1.lms_OneLLM`          | lms + claude 2개      | LM Studio(headless lms CLI) 단일 백엔드 + Claude Code 직결. `5.lms_MultiLLM`(GW+다중) 청사진 |
| `5.lms_MultiLLM`        | gateway + lms×N + claude | 게이트웨이(nginx) 단일 주소 경유로 N개 LMS 백엔드에 다세션 분산 (`--scale lms=N`). 수평 확장 |

공통 사전 요구사항:
* Docker / Docker Compose (v2 권장 — `.env` 자동 로드 + 틸드 확장 지원)
* 각 컨테이너 폴더의 `.env` 준비 (아래 참조)
* (Linux GPU 사용 시) NVIDIA Container Toolkit

## .env 설정

각 컨테이너 폴더에 독립된 `.env`를 두는 방식 (이전 루트 공용 `.env` + 심볼릭 링크 폐기).

```bash
# 1.ollama_OneContainer
cd 1.ollama_OneContainer
cp .env.org .env
vi .env          # OLLAMA_MODEL, OLLAMA_MOUNT, MOUNT_CODE_DIR 수정

# 2.ollama_TwoContainer
cd 2.ollama_TwoContainer
cp .env.org .env
vi .env

# 3.ollama_External
cd 3.ollama_External
cp .env.org .env
vi .env          # OLLAMA_HOST(외부 Ollama 주소), OLLAMA_MODEL 수정

# 4.1.lms_OneLLM
cd 4.1.lms_OneLLM
cp .env.org .env
vi .env          # LMS_MODEL, LMS_MODEL_MOUNT(모델 디렉토리) 수정

# 5.lms_MultiLLM
cd 5.lms_MultiLLM
cp .env.org .env
vi .env          # LMS_MODEL, GATEWAY_PORT, LMS_BACKEND_COUNT 수정 (기동 시 --scale lms=N)
```

* `.env.org` — 커밋된 템플릿 (KEY=VALUE 형식)
* `.env` — 사용자 복사본 (`.gitignore`로 커밋 금지)
* docker compose가 같은 폴더의 `.env`를 자동 로드하므로 별도 `--env-file` 옵션 불필요

# 1.ollama_OneContainer

## 용도

* 단일 머신에서 Ollama + Claude Code를 한 번에 띄우고 싶은 경우
* 컨테이너 1개만 관리하면 되므로 셋업·디버깅이 간결
* 외부에서 Ollama API를 별도로 공유할 필요 없는 1:1 환경

## 특징

* 베이스 이미지: `ollama/ollama` 위에 Node.js 22 + Claude Code + ubuntu 유저 추가
* Ollama 서버와 Claude CLI가 같은 컨테이너에서 실행 (`ANTHROPIC_BASE_URL=http://127.0.0.1:11434`)
* 호스트 포트 매핑: `11437 → 11434`
* 볼륨:
    - `~/df → /home/ubuntu/df` (작업 폴더)
    - `${OLLAMA_MOUNT} → /root/.ollama` (모델 저장, 토글 가능)
    - `claude-home → /home/ubuntu` (Claude 홈 영속화)

## 사용법

```bash
cd 1.ollama_OneContainer

# Mac / Linux CPU 모드
docker compose up -d --build

# Linux + NVIDIA GPU
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build

# 호스트 코드 폴더 마운트 (선택)
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d --build

# 컨테이너 접속 (ubuntu 유저)
docker exec -it -u ubuntu claude bash

# 컨테이너 내부에서 Claude Code 실행
cc          # alias = claude --dangerously-skip-permissions
```

> 처음 한 번은 퍼미션 오류가 날 수 있음. 두 번째 실행부터 정상 동작.

# 2.ollama_TwoContainer

## 용도

* Ollama 서버를 독립 컨테이너로 운영하고 싶은 경우 (재시작·로그 분리, 모니터링 용이)
* 같은 Ollama를 여러 클라이언트(Claude Code 외 다른 도구)와 공유
* claude 컨테이너만 자주 빌드/교체하고 ollama는 유지하고 싶은 환경

## 특징

* `ollama` 컨테이너: `ollama/ollama` 이미지 그대로, `${OLLAMA_MODEL}` 자동 pull
* `claude` 컨테이너: `debian:bookworm-slim` 기반의 경량 Claude Code 전용 이미지
* 컨테이너 간 통신: `claude` → `http://ollama:11434` (Docker 네트워크 `ollama`)
* 호스트 포트 매핑: `11436 → ollama:11434`
* `claude` 컨테이너는 ollama healthcheck가 통과한 후 기동 (`depends_on: service_healthy`)
* 볼륨:
    - `~/df → /df` (ollama) / `~/df → /home/ubuntu/df` (claude)
    - `${OLLAMA_MOUNT} → /root/.ollama` (ollama 전용, 모델 저장, 토글 가능)
    - `claude-home → /home/ubuntu` (Claude 홈 영속화)

## 사용법

```bash
cd 2.ollama_TwoContainer

# Mac / Linux CPU 모드
docker compose up -d --build

# Linux + NVIDIA GPU
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build

# 호스트 코드 폴더 마운트 (선택)
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d --build

# 클라이언트 접속 (ubuntu 유저, 기본 유저)
docker exec -it claude bash

# 컨테이너 내부에서 Claude Code 실행
cc

# Ollama 단독 재시작 (claude 영향 없음)
docker compose restart ollama
```

# 3.ollama_External

## 용도

* 호스트(또는 원격 서버)에 **이미 Ollama가 설치·운영 중**인 환경 (systemd 등)에 Claude Code 컨테이너만 추가로 붙이는, 실무에서 가장 흔한 '일반 방식'
* Ollama를 컨테이너로 다시 띄우지 않으므로 모델·GPU·튜닝을 호스트 Ollama에 일임
* 여러 머신·팀이 공용으로 쓰는 중앙 Ollama 서버에 클라이언트만 늘리고 싶은 경우

## 특징

* 컨테이너 1개(`claude`)만 존재 — Ollama 컨테이너 없음
* `claude` 컨테이너: `debian:bookworm-slim` 기반 경량 Claude Code 전용 이미지 (`2.ollama_TwoContainer`의 `Dockerfile.claude`와 동일 계열)
* 외부 Ollama 연결: `ANTHROPIC_BASE_URL=http://${OLLAMA_HOST}:${OLLAMA_PORT_EXT}` (기본 `host.docker.internal:11434`)
* `extra_hosts: host.docker.internal:host-gateway` 로 Linux 호스트에서도 호스트 Ollama 해석 (macOS/Windows는 자동)
* 호스트 포트 매핑 없음 — 컨테이너가 Ollama를 노출하지 않음 (외부 Ollama가 이미 11434 제공)
* `entrypoint.sh`: 외부 Ollama 도달 확인(`nc`) + `settings.json` 동적 생성. 컨테이너 내부에서 `ollama serve`·모델 pull 하지 않음
* 모델은 **호스트에서 선(先) pull** 필요 (`ollama pull <model>`)
* 볼륨:
    - `~/df → /home/ubuntu/df` (작업 폴더)
    - `claude-home → /home/ubuntu` (Claude 홈 영속화)

> **호스트 Ollama 바인드 주의**: 컨테이너에서 접근하려면 호스트 Ollama가 `0.0.0.0`에 바인드되어야 함. systemd 사용 시 `Environment=OLLAMA_HOST=0.0.0.0` 설정 후 `systemctl restart ollama`. (기본 `127.0.0.1` 바인드면 컨테이너에서 연결 불가)

## 사용법

```bash
cd 3.ollama_External

# 외부 Ollama(호스트) 연결 — GPU override 불필요 (GPU는 호스트 Ollama 소관)
docker compose up -d --build

# 호스트 코드 폴더 마운트 (선택)
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d --build

# 컨테이너 접속 (ubuntu 유저, 기본 유저)
docker exec -it claude bash

# 컨테이너 내부에서 Claude Code 실행
cc          # alias = claude --dangerously-skip-permissions

# 원격 서버 Ollama 사용 시: .env 에서 OLLAMA_HOST=<서버IP> 로 변경 후 재기동
```

# 4.1.lms_OneLLM

> Ollama 가 아닌 **LM Studio(LMS)** 백엔드 예제. `5.lms_MultiLLM`(게이트웨이 + 다중 LLM)으로 가기 위한 **중간 검증 단계**이며, 설계 SSOT 는 [_doc_arch/lms-multi-gateway-design.md](_doc_arch/lms-multi-gateway-design.md).

## 용도

* Ollama 의 추론 속도·동시성 한계를 LM Studio 백엔드로 대체 검증하는 첫 단계
* LMS(headless `lms` CLI) 컨테이너 1개 + Claude Code 컨테이너 1개로 "LMS 가 Claude Code 와 직결로 말이 통하는가"를 단일 경로에서 확인
* 다음 단계 `5.lms_MultiLLM`(게이트웨이 + 백엔드 N개)의 청사진

## 특징

* 컨테이너 2개(`lms`, `claude`) — `2.ollama_TwoContainer` 구조 계승 (`lms` 가 `ollama` 자리 대체)
* **headless `lms` CLI** 구동 — LM Studio GUI 데스크톱 앱이 아님. `lms server`/`lms load`/`lms log stream` 와 OpenAI 호환 `/v1` 로만 제어 (Docker 기반이라 GUI 없음)
* **변환 게이트웨이 없음 (직결)**: `ANTHROPIC_BASE_URL=http://lms:1234` + `ANTHROPIC_AUTH_TOKEN=lms` 로 claude CLI 가 LMS OpenAI 엔드포인트에 직접 동작 (prj81 검증)
* `entrypoint.lms.sh` 시퀀스: `http-server-config.json`(0.0.0.0 바인딩) 주입 → `lms server start` → `/v1/models` 헬스 폴링 → `lms load ${LMS_MODEL}` → `exec lms log stream`(PID1)
* `lms` healthcheck(`/v1/models`) 통과 후에야 `claude` 가 기동 (`depends_on: service_healthy`)
* 모델 저장소 토글: `LMS_MODEL_MOUNT` (빈값=named volume `lms-models` / 호스트 경로=기존 LM Studio 모델 디렉토리 공유)
* GPU 는 `docker-compose.gpu.yml` override 로 활성화 (`runtime: nvidia`)

> **실기동 검증됨(온라인+GPU)**: build→up→모델 다운로드(Llama-3.1-8B GGUF)→GPU 로드→크로스컨테이너 추론 왕복까지 동작 확인. LMS 는 OpenAI `/v1` 뿐 아니라 **Anthropic `/v1/messages` 도 네이티브 지원**(변환 GW 불요 실증). 단 `claude` 대화형 에이전트 루프는 8B 급 tool-use 한계로 부적합 — 에이전트 용도는 더 큰/특화 모델 필요. 상세는 폴더 [README](4.1.lms_OneLLM/README.md).
>
> **air-gap 주의**: 현 구현은 **온라인 빌드 전제**(`install.sh` 로 `lms` 설치, `lms get` 으로 모델 다운로드). 폐쇄망은 docker `export`+`compose` 반입 파이프라인으로 전환하며, `Dockerfile.lms` 에 오프라인 COPY 대안이 주석으로 보존됨.
>
> **폴더 이력 (2026-07-17)**: 온라인·fg1 운영판(구 `4.lms_OneLLM`)은 air-gap 이 아니어서 `~/_git/__all/dockers/4.lms_OneLLM` 로 이전. 본 저장소에는 air-gap 원본 `4.1.lms_OneLLM`(구 `4.1.lms_OneLLM_for_air-gap`)만 유지.

## 사용법

```bash
cd 4.1.lms_OneLLM
cp .env.org .env
vi .env          # LMS_MODEL, LMS_MODEL_MOUNT 지정

# 기본(CPU 가정) 기동
docker compose up -d --build

# NVIDIA GPU 사용
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build

# 호스트 코드 폴더 마운트 (선택)
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d --build

# 컨테이너 접속 (ubuntu 유저, 기본 유저)
docker exec -it claude bash

# 컨테이너 내부에서 Claude Code 실행
cc          # alias = claude --dangerously-skip-permissions

# 모델 수동 로드(자동 로드 실패 시)
docker exec -it lms lms load <model>
```

## 테스트 모델 권장 (context ≥128k)

| 모델 | 크기 | context | 용도 |
| :--- | :--- | :--- | :--- |
| `Phi-3.5-mini-instruct` | 3.8B | 128k | 스모크(연결·기동) — 가장 빠른 왕복 |
| `Llama-3.1-8B-Instruct` | 8B | 128k | 범용 안정 기준선 |
| `DeepSeek-Coder-V2-Lite` | 16B MoE | 160k | 코딩 검증 (MoE 로 빠름) |

# 5.lms_MultiLLM

> `4.1.lms_OneLLM`(직결 단일)의 **최종 확장형** — 게이트웨이(nginx) 단일 주소 뒤에 LMS 백엔드를 N개 두어 다세션을 분산. 설계 SSOT 는 [_doc_arch/lms-multi-gateway-design.md](_doc_arch/lms-multi-gateway-design.md), 폴더 상세는 [5.lms_MultiLLM/README.md](5.lms_MultiLLM/README.md).

## 용도

* Claude Code 세션이 늘어도 **접근 주소는 게이트웨이 하나**로 고정하고, 뒤에서 백엔드를 늘려 동시성·처리량을 확보
* 단일 LMS 의 직렬 처리 한계를 **수평 확장**(`--scale lms=N`)으로 해소
* `4.1.lms_OneLLM` 에서 검증된 직결(변환 GW 불요, B1)을 그대로 계승하고 분산 계층만 추가

## 특징

* 컨테이너 3종: `gateway`(nginx L7 분산) + `lms`(백엔드 풀, `--scale` 다중 복제) + `claude`(클라이언트)
* **변환 게이트웨이 아님** — nginx 는 순수 L7 패스스루 로드밸런서. claude→게이트웨이→LMS 모두 OpenAI `/v1` 직결 (token=`lms`)
* 백엔드 디스커버리: Docker 임베디드 DNS(127.0.0.11) + 변수 `proxy_pass` → `--scale lms=N` 복제본을 **매 요청 라운드로빈** 분산 (least_conn 정적 upstream 은 `nginx.conf.template` 주석 대안)
* **SSE 스트리밍 보존**: `proxy_buffering off` + 타임아웃 600s (claude 토큰 스트림 깨짐 방지)
* **기동 게이팅**: 게이트웨이 healthcheck=`/v1/models`(백엔드 응답 시에만 200) → `claude` 는 게이트웨이 healthy 후 기동 (모델 로드 중 초기 502 차단)
* 전 백엔드 동일 `LMS_MODEL` 로드 → model 필드 일치 → nginx 패스스루로 충분 (다중 모델 라우팅이 필요하면 LiteLLM 격상)
* 외부 노출은 게이트웨이 1포트(`GATEWAY_PORT`)만. LMS 백엔드는 내부 네트워크 전용

> **모델 공유 주의**: `--scale` 복제본이 `lms-models` 볼륨을 공유하므로, 최초 1회는 `--scale lms=1` 로 모델을 받은 뒤 스케일업 권고(동시 `lms get` 다운로드 경합 회피). air-gap 은 모델 디렉토리를 사전 마운트.
>
> **에이전트 한계(B1')**: 8B 급은 tool-use 한계로 claude 대화형 에이전트 루프에 부적합(Issue13 실증). 에이전트 용도면 더 큰/특화 모델 권장.

## 사용법

```bash
cd 5.lms_MultiLLM
cp .env.org .env
vi .env          # LMS_MODEL, GATEWAY_PORT 지정

# 기본 기동 (백엔드 2개)
docker compose up -d --build --scale lms=2

# NVIDIA GPU 사용
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build --scale lms=2

# 호스트 코드 폴더 마운트 (선택)
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d --build --scale lms=2

# 컨테이너 접속 후 Claude Code 실행
docker exec -it claude bash
cc               # alias = claude --dangerously-skip-permissions

# 백엔드 분산 확인 (게이트웨이 → 복제본 로그)
docker compose logs -f gateway
docker compose logs -f lms
```

> ⚠️ 실제 다중 백엔드 `up --scale` 동작은 GPU·온라인 LMS 설치·모델 다운로드에 의존하여 GPU 호스트에서 별도 검증이 필요함(현 단계는 `compose config`·`bash -n`·nginx `-t` 정적 검증까지 완료).

# 모드 비교 요약

| 항목                | 1.ollama_OneContainer                                          | 2.ollama_TwoContainer                                          | 3.ollama_External                                              | 4.1.lms_OneLLM                                                   | 5.lms_MultiLLM                                                 |
| :------------------ | :------------------------------------------------------------- | :------------------------------------------------------------- | :------------------------------------------------------------- | :------------------------------------------------------------- | :------------------------------------------------------------- |
| 백엔드              | Ollama                                                         | Ollama                                                         | Ollama (외부)                                                  | **LM Studio (headless lms CLI)**                              | **LM Studio ×N (게이트웨이 분산)**                            |
| 컨테이너 수         | 1                                                              | 2 (`ollama`, `claude`)                                         | 1 (`claude` — Ollama는 호스트)                                 | 2 (`lms`, `claude`)                                            | 2+N (`gateway`, `lms`×N, `claude`)                            |
| 백엔드 접근 (내부)  | `http://127.0.0.1:11434`                                       | `http://ollama:11434`                                          | `http://host.docker.internal:11434` (`OLLAMA_HOST` 변수화)     | `http://lms:1234` (`LMS_PORT` 변수화)                         | `http://gateway:8080` → `lms:1234` ×N (nginx 분산)            |
| 프로토콜            | Anthropic 직결                                                 | Anthropic 직결                                                 | Anthropic 직결                                                 | OpenAI `/v1` 직결 (변환 GW 없음, token=`lms`)                 | OpenAI `/v1` 직결 (nginx L7 패스스루, 변환 없음)             |
| 베이스 이미지       | `ollama/ollama` (확장)                                         | `ollama/ollama` + `debian:bookworm-slim`                       | `debian:bookworm-slim` (claude만)                              | `debian:bookworm-slim` ×2 (lms·claude)                        | `nginx:1.27` + `debian:bookworm-slim`(lms·claude)            |
| 백엔드 구동 주체    | 컨테이너                                                       | 컨테이너                                                       | 호스트/원격 서버 (선설치)                                      | 컨테이너                                                      | 컨테이너 (N개)                                               |
| 백엔드 단독 재시작  | 불가 (claude까지 같이 내려감)                                  | 가능                                                           | 해당 없음 (호스트가 관리)                                      | 가능                                                          | 가능 (복제본 단위)                                          |
| 모델 저장소 토글    | `OLLAMA_MOUNT` (공유: `~/.ollama` / 격리: `ollama-models`)     | 동일                                                           | 해당 없음 (호스트 Ollama 소관)                                 | `LMS_MODEL_MOUNT` (공유: 호스트 / 격리: `lms-models`)         | `LMS_MODEL_MOUNT` (복제본 전체 볼륨 공유)                    |
| GPU 토글            | `docker-compose.gpu.yml`                                       | `docker-compose.gpu.yml`                                       | 해당 없음 (호스트 소관)                                        | `docker-compose.gpu.yml`                                       | `docker-compose.gpu.yml` (lms 풀에 적용)                    |
| 코드 폴더 마운트    | `MOUNT_CODE_DIR` + `docker-compose.code.yml`                   | 동일                                                           | 동일                                                           | 동일                                                          | 동일                                                        |
| 확장/동시성         | 수직 (GPU 1)                                                   | 수직                                                          | 호스트 의존                                                   | 수직 (단일 백엔드)                                          | **수평 (`--scale lms=N`)**                                   |

# 마운트 옵션

## 모델 저장소 토글 (`OLLAMA_MOUNT`)

`.env`의 `OLLAMA_MOUNT` 값으로 모델 디렉토리(`/root/.ollama`)의 호스트측 위치를 전환함.

| 값                         | 동작                                                                                     |
| :------------------------- | :--------------------------------------------------------------------------------------- |
| `~/.ollama` (기본)         | 호스트 모델 디렉토리 공유. 호스트에서 `ollama pull`한 모델을 컨테이너에서도 그대로 사용  |
| `ollama-models`            | docker named volume에 격리. 컨테이너만의 깨끗한 저장소. 호스트와 분리                    |
| 그 외 절대 경로 / volume명 | 임의 경로 또는 임의 named volume                                                         |

docker compose는 값이 `/`, `~`, `.`로 시작하면 bind mount, 그 외 식별자는 named volume으로 자동 분기함.

## 호스트 코드 마운트 (`MOUNT_CODE_DIR`)

호스트의 코드 폴더를 컨테이너 내 `/home/ubuntu/code`로 마운트하는 옵션. `docker-compose.code.yml` override로 분리되어 있어 필요한 경우에만 적용함.

```bash
# .env에 설정
MOUNT_CODE_DIR=~/code

# 실행 시 override 추가
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d
```

`MOUNT_CODE_DIR`이 비어 있으면 override 파일을 적용하지 않으면 됨 (기본 `docker-compose.yml`만 사용).

# 모델 설정

## 사용 가능 모델 예시

| 모델            | 용도      | 비고             |
| :-------------- | :-------- | :--------------- |
| qwen3-coder:30b | 코딩 특화 |                  |
| qwen3.5:35b     | 코딩 특화 |                  |
| qwen3.5:30b     | 코딩 특화 |                  |
| gemma4:26b      | 기본 모델 | 21.26 GB Mem 필요 |
| gemma4:31b      | 기본 모델 |                  |

## `.env` 로 통일 관리

```bash
# .env
OLLAMA_MODEL=gemma4:26b
```

| 적용 대상                | 동작                              |
| :----------------------- | :-------------------------------- |
| ollama 컨테이너 시작 시  | `ollama pull ${OLLAMA_MODEL}`     |
| claude 컨테이너 환경변수 | `ANTHROPIC_MODEL=${OLLAMA_MODEL}` |
| claude settings.json     | 컨테이너 시작 시 동적 생성        |

## 모델 전환

```bash
# 방법 1: .env 수정 후 재시작
vi .env   # OLLAMA_MODEL=qwen3-coder:30b
docker compose up -d

# 방법 2: 일회성 오버라이드
OLLAMA_MODEL=qwen3-coder:30b docker compose up -d

# 방법 3: 컨테이너 내에서 직접 지정 (이미 pull된 모델만)
claude --model qwen3-coder:30b
```

## qwen3 모델 사용 시 주의

qwen3 계열은 현재 작업 디렉토리를 자동 인식하지 못할 수 있음. 첫 프롬프트에서 명시:

```
현재 작업 폴더는 /home/ubuntu/df 입니다. 여기서 작업해주세요.
```

# 환경변수 (자동 주입)

| 변수                                       | 값                          | 설명                                            |
| :----------------------------------------- | :-------------------------- | :---------------------------------------------- |
| `ANTHROPIC_BASE_URL`                       | 모드별 자동 설정            | Ollama API 엔드포인트                           |
| `ANTHROPIC_AUTH_TOKEN`                     | `ollama`                    | 인증 토큰 (더미)                                |
| `ANTHROPIC_MODEL`                          | `.env`의 `OLLAMA_MODEL`     | 기본 사용 모델                                  |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1`                         | 불필요 트래픽 차단                              |
| `OLLAMA_MOUNT`                             | `.env` 값                   | 모델 저장소 위치 (호스트 경로 또는 named volume)|
| `MOUNT_CODE_DIR`                           | `.env` 값 (선택)            | 호스트 코드 폴더 경로 (override 적용 시)        |
| `OLLAMA_FLASH_ATTENTION`                   | `1` (기본)                  | Flash Attention on/off                          |
| `OLLAMA_KV_CACHE_TYPE`                     | `q8_0` (기본)               | KV cache 양자화 (`f16`/`q8_0`/`q4_0`)           |
| `OLLAMA_NUM_GPU`                           | `999` (기본)                | GPU 레이어 수                                   |
| `OLLAMA_CONTEXT_LENGTH`                    | `100000` (기본)             | 컨텍스트 길이                                   |
| `TZ`                                       | `Asia/Seoul` (기본)         | 컨테이너 내 타임존 (`date`, git commit, 로그)   |
| `COMPOSE_PROJECT_NAME`                     | 모드별 기본값               | docker compose 프로젝트명 (충돌 회피)            |
| `COMPOSE_FILE`                             | (미설정)                    | 콜론 구분 yml 자동 포함 (예: `docker-compose.yml:docker-compose.gpu.yml`) |
| `CLAUDE_CONTAINER_NAME` / `OLLAMA_CONTAINER_NAME` | `claude`/`ollama`     | 컨테이너 이름 (다중 인스턴스 시 변경)           |
| `OLLAMA_PORT`                              | `11437`/`11436`             | 호스트 측 노출 포트                             |
| `USER_UID` / `USER_GID`                    | `1000` (기본)               | 컨테이너 ubuntu 유저 UID/GID (Dockerfile build) |

# 다중 인스턴스 운영

같은 호스트에서 두 모드를 동시에 띄우거나 여러 카피를 운영하려면 `.env`에서 충돌 가능 변수만 다르게 설정:

```bash
# 인스턴스 A (.env)
COMPOSE_PROJECT_NAME=air_gap_claude_code_one_a
CLAUDE_CONTAINER_NAME=claude_a
OLLAMA_PORT=11437

# 인스턴스 B (.env, 다른 폴더 복사본)
COMPOSE_PROJECT_NAME=air_gap_claude_code_one_b
CLAUDE_CONTAINER_NAME=claude_b
OLLAMA_PORT=11447
```

2.ollama_TwoContainer는 추가로 `OLLAMA_CONTAINER_NAME`, `OLLAMA_NETWORK_NAME`도 분리.

# UID/GID 매핑 (Linux 호스트 + 코드 마운트)

`MOUNT_CODE_DIR`로 호스트 코드 폴더를 마운트할 때 컨테이너↔호스트 권한 일치를 위해 UID/GID 맞춤:

```bash
# 호스트 UID/GID 확인
id -u    # ex) 1001
id -g    # ex) 1001

# .env 수정
USER_UID=1001
USER_GID=1001

# 이미지 재빌드 (build args 변경 반영 필수)
docker compose build --no-cache
docker compose up -d
```

* macOS Docker Desktop은 자동 위임으로 1000 그대로도 OK
* Linux 호스트는 코드 마운트 시 권한 사고 방지 위해 반드시 일치 권장

# 트러블슈팅

## .env 누락 시

`docker compose up` 실행 시 변수 미정의 경고:

```bash
cd 1.ollama_OneContainer  # 또는 2.ollama_TwoContainer
cp .env.org .env
```

## Claude Code 가 Ollama에 연결되지 않을 때

```bash
# 환경변수 확인
docker exec claude bash -c 'echo $ANTHROPIC_BASE_URL'

# Ollama 연결 테스트 (1.ollama_OneContainer)
docker exec claude curl -s http://127.0.0.1:11434/api/tags

# Ollama 연결 테스트 (2.ollama_TwoContainer)
docker exec claude curl -s http://ollama:11434/api/tags
```

## GPU 가 적용되지 않을 때 (Linux + NVIDIA)

기본 `docker compose up -d` 만 실행하면 [docker-compose.gpu.yml](1.ollama_OneContainer/docker-compose.gpu.yml) override 가 빠져 컨테이너가 **CPU 추론으로 떨어진다**. NVIDIA Container Toolkit 이 설치되어 있어도 마찬가지 — compose 가 GPU yml 을 읽지 않으면 디바이스가 컨테이너로 전달되지 않음.

### 진단

```bash
# 1) 컨테이너에 GPU 디바이스 요청이 박혔는지
docker inspect claude --format '{{json .HostConfig.DeviceRequests}}'
#   기대: [{"Driver":"nvidia","Count":-1,"Capabilities":[["gpu"]]}]
#   null → GPU 미적용

# 2) 모델이 어디서 도는지
docker exec claude ollama ps
#   PROCESSOR 컬럼이 "100% GPU" 여야 정상 ("100% CPU" 면 미적용)

# 3) 호스트에서 ollama 프로세스 GPU 사용 확인
nvidia-smi
```

### 해결 — gpu.yml 포함해 재생성

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --force-recreate
```

`--force-recreate` 필수: `DeviceRequests` 는 **컨테이너 생성 시점에만** 박히므로 `docker compose restart` 나 단순 `up -d` 로는 반영되지 않는다 (이미 실행 중이면 noop).

### 영구 자동화 — `COMPOSE_FILE` env

매번 `-f` 두 번 지정이 번거로우면 `.env` 끝에 추가:

```bash
# .env
COMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml
```

이후 `docker compose up -d` 만으로 GPU override 자동 포함. 코드 마운트까지 같이 쓰려면 콜론으로 추가:

```bash
COMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml:docker-compose.code.yml
```

> NVIDIA 없는 머신과 `.env` 를 공유한다면 머신별로 분리할 것 (GPU 없는 호스트에서 기동 실패함).

### alias `dcu = docker-compose up` 사용 시 주의

alias 가 이미 `up` 까지 포함하면 `-f` 옵션을 끼울 자리가 없다 — `-f` 는 `up` **앞** 글로벌 위치에 와야 하기 때문. alias 를 그대로 쓰려면 위 `COMPOSE_FILE` env 방법이 유일한 해법.

```bash
# ✗ 동작 안 함 — `up` 뒤에 -f 가 오면 잘못된 위치
dcu -f docker-compose.gpu.yml -d

# ✓ alias 우회해서 풀 명령
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --force-recreate

# ✓ COMPOSE_FILE 설정 후 alias 그대로
export COMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml
dcu -d --force-recreate
```

## CUDA OOM 에러 발생 시

* 대형 모델(qwen3-coder:30b, 18GB)은 16GB VRAM에서 CPU/GPU 분할 로드됨
* 양쪽 모드 모두 `.env`에 다음 변수가 외부화되어 yml 수정 없이 조정 가능:
    - `OLLAMA_FLASH_ATTENTION=1` — Flash Attention 활성화
    - `OLLAMA_KV_CACHE_TYPE=q8_0` — KV cache 8bit 양자화 (VRAM 절감 균형, 기본)
        - `f16`: 양자화 없음, 정확도 우선 (24GB+ VRAM)
        - `q4_0`: 4bit 양자화, VRAM 최소 (8~12GB VRAM, 품질 일부 희생)
    - `OLLAMA_NUM_GPU=999` — 전체 레이어 GPU 로드
    - `OLLAMA_CONTEXT_LENGTH=100000` — 100K context
* 여전히 OOM 시: `OLLAMA_FLASH_ATTENTION=0` 또는 `OLLAMA_KV_CACHE_TYPE=q4_0`로 폴백

## 모델 전환이 느릴 때

* Ollama는 모델 전환 시 기존 모델 언로드 → 새 모델 로드를 수행
* VRAM 16GB 제약으로 대형 모델 동시 로딩 불가
* 빠른 전환이 필요하면 소형 모델(7B~14B) 사용 권장

# 파일 구조

```
air-gap-claudeCode/
├── 1.ollama_OneContainer/
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── docker-compose.gpu.yml       # GPU override
│   ├── docker-compose.code.yml      # NEW: 코드 마운트 override
│   ├── entrypoint.sh
│   ├── .env.org                     # NEW: 커밋된 템플릿
│   └── .env                         # NEW: 사용자 복사본 (.gitignore)
├── 2.ollama_TwoContainer/
│   ├── Dockerfile.claude
│   ├── docker-compose.yml
│   ├── docker-compose.gpu.yml       # GPU override
│   ├── docker-compose.code.yml      # NEW: 코드 마운트 override
│   ├── test-setup.sh
│   ├── .env.org                     # NEW: 커밋된 템플릿
│   └── .env                         # NEW: 사용자 복사본 (.gitignore)
├── LICENSE                          # MIT
└── README.md
```

각 컨테이너 폴더가 독립된 `.env`를 보유함 (docker compose 자동 로드). 루트의 공용 `env`/`.env`와 심볼릭 링크는 폐지됨.

# 라이선스

이 저장소는 [MIT License](LICENSE) 로 배포함. Copyright (c) 2026 Finfra Co., Ltd. (https://finfra.kr)

* 소스·Docker 구성·스크립트·문서 전부 MIT 단일 적용 — 별도 상표·배포본 약관 없음
* 컨테이너가 기동 시 내려받는 서드파티 구성요소(Ollama·LM Studio·Claude Code·각 LLM 모델)는 **각자의 라이선스**를 따르며 본 저장소 라이선스에 포함되지 않음
* 문의: finfra@gmail.com
