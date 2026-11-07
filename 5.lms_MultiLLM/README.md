# 5.lms_MultiLLM

게이트웨이(nginx) 단일 주소 뒤에 LM Studio(**headless `lms` CLI**) 백엔드를 **N개** 두어, Claude Code 다세션이 하나의 주소로 여러 LMS 백엔드에 분산 접근하는 예제.
`4.1.lms_OneLLM`(직결 단일)의 최종 확장형이며, 거기서 실증된 **직결(변환 게이트웨이 불요, B1)** 을 계승하고 **분산 계층**만 추가한다.

> 설계 SSOT: [`_doc_arch/lms-multi-gateway-design.md`](../_doc_arch/lms-multi-gateway-design.md)
> 전체 예제 비교: 루트 [`README.md`](../README.md) · 청사진: [`4.1.lms_OneLLM`](../4.1.lms_OneLLM/README.md)

---

## 토폴로지

```
                         ┌──────────── docker network: lms ────────────┐
┌──────────────┐  :8080  │  ┌────────────┐      ┌──────────────────┐    │
│   claude     │ ──────► │  │  gateway   │ ───► │ lms (×N, --scale)│    │
│ (Claude Code)│         │  │  (nginx)   │ ─┐   │  lms server /v1  │    │
└──────────────┘         │  └────────────┘  └─► │  ... 복제본 N ... │    │
   단일 외부 주소         │   L7 분산(DNS RR)     └──────────────────┘    │
                         └──────────────────────────────────────────────┘
기동: lms(healthy) → gateway(healthy=/v1/models 프록시 OK) → claude
```

* 컨테이너 3종: `gateway`(분산) + `lms`(백엔드 풀, `--scale` 복제) + `claude`(클라이언트).
* **GUI 없음**: LM Studio 데스크톱 앱이 아니라 헤드리스 `lms` CLI. 제어는 `lms server`/`lms load`/`lms log stream` 와 `/v1` API.
* **변환 게이트웨이 아님**: nginx 는 순수 L7 패스스루 로드밸런서. claude→gateway→lms 전부 OpenAI `/v1` 직결(token=`lms`).

---

## 파일 구성

| 파일                      | 역할                                                                                                                 |
| :------------------------ | :------------------------------------------------------------------------------------------------------------------- |
| `Dockerfile.gateway`      | nginx L7 분산 게이트웨이 이미지 (`nginx:1.27` + curl)                                                                |
| `nginx.conf.template`     | 게이트웨이 설정(envsubst `${LMS_PORT}`): resolver + `upstream … resolve` + X-Session consistent hash, SSE(buffering off), 하단 주석에 이전 방식(변수 proxy_pass)   |
| `Dockerfile.lms`          | headless `lms` CLI 백엔드 이미지 (4.1.lms_OneLLM 그대로)                                                               |
| `entrypoint.lms.sh`       | LMS PID1: `lms daemon up`→`lms server start --bind 0.0.0.0`→`/v1/models` 폴링→`lms get`/`load`→`exec lms log stream` |
| `Dockerfile.claude`       | Claude Code 클라이언트 이미지 (게이트웨이 직결)                                                                      |
| `entrypoint.sh`           | claude PID1: `settings.json`(게이트웨이 URL) 생성 + 게이트웨이 대기                                                  |
| `docker-compose.yml`      | `gateway` + `lms`(무명·스케일) + `claude` 3서비스, 내부 네트워크, 기동 게이팅                                        |
| `docker-compose.gpu.yml`  | GPU override (lms 풀에 `nvidia`)                                                                                     |
| `docker-compose.code.yml` | 호스트 코드 폴더 마운트 override                                                                                     |
| `.env.org`                | 파라미터 템플릿 (`cp .env.org .env` 후 사용)                                                                         |
| `Dockerfile.small`        | `lms:small` — 저VRAM 멀티 백엔드 테스트용 경량 이미지 (gemma-4-e2b 128k 내장, 아래 절 참조)                          |
| `build.small.sh`          | `lms:small` 빌드 스크립트 (`build.small/models/` 에 gguf 필요 — git 미추적)                                          |
| `TEST.md`                 | 멀티 백엔드 검증 절차 (기동→로드/VRAM→분산→GENERATING 판별→40k needle→claude 종단)                                   |

---

## 빠른 시작

```bash
cp .env.org .env
vi .env                 # LMS_MODEL, GATEWAY_PORT 지정

# 최초 1회: 백엔드 1개로 모델 다운로드 (복제본 볼륨 공유 → 동시 다운로드 경합 회피)
docker compose up -d --build --scale lms=1

# 모델 적재 확인 후 스케일업 (백엔드 2개)
docker compose up -d --scale lms=2

# NVIDIA GPU 사용
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build --scale lms=2

# 호스트 코드 폴더 마운트 (선택; .env 의 MOUNT_CODE_DIR 필요)
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d --build --scale lms=2

# 컨테이너 접속 후 Claude Code 실행
docker exec -it claude bash
cc                      # alias = claude --dangerously-skip-permissions

# 분산/기동 로그
docker compose logs -f gateway
docker compose logs -f lms
```

---

## lms:small — 저VRAM 멀티 백엔드 테스트 (6.lms_MultiLLM_run 과 동일 패치)

16GB GPU 에서 대형 모델(예: gemma-4-31b, 단독 15.4GB)로는 멀티 백엔드가 불가능할 때,
**최대 컨텍스트(128k)를 쓸 수 있는 소형 모델을 내장한 `lms:small`** 로 분산을 검증한다.
`FROM lms:latest` 레이어 추가 방식이라 `lms:latest` 원본은 변경되지 않는다.
상세 스펙·실측치는 `6.lms_MultiLLM_run/README.md` 의 같은 절, 검증 데이터는
`_doc_work/report/lms-small-dispatch-verify_report.md` 참조.

```bash
./build.small.sh                     # lms:small 빌드 (6번 폴더의 모델 준비분 자동 재사용)
vi .env                              # 아래 4개 변경
#   LMS_IMAGE=lms:small
#   LMS_MODEL=google/gemma-4-e2b
#   LMS_CONTEXT_LENGTH=131072
#   CLAUDE_MAX_OUTPUT_TOKENS=32000
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --scale lms=2
```

* ⚠️ **`--build` 플래그 금지** — `docker compose up --build` 는 Dockerfile.lms 를
  다시 빌드해 `lms:small` 태그를 덮어쓴다. lms:small 은 `./build.small.sh` 로만 빌드.
* 실측 (2026-07-16, 16GB GPU): 백엔드당 VRAM ~3.95GB (128k ctx) → 2개 탑재 후 8.2GB 여유.
  40k 토큰 needle 테스트 통과, 두 백엔드 동시 생성 안정.
* 신규 named volume 은 이미지 내장 모델로 자동 프리팝 — air-gap 반입 후 모델 복사 불필요.

---

## .env 파라미터

| 변수                     | 기본값                          | 설명                                                                              |
| :----------------------- | :------------------------------ | :-------------------------------------------------------------------------------- |
| `LMS_MODEL`              | (모델 키)                       | 전 백엔드 공통 로드 모델. `lms ls` 의 소문자 hub 키. ANTHROPIC_MODEL 도 동일 전달 |
| `LMS_PORT`               | `1234`                          | 각 LMS 백엔드 OpenAI 포트 (내부 전용)                                             |
| `LMS_HEALTH_TRIES`       | `30`                            | `/v1/models` 헬스 폴링 최대 횟수(×2초)                                            |
| `LMS_CONTEXT_LENGTH`     | `32768`                         | 컨텍스트 토큰 상한 (에이전트 용도면 32768↑ 권장)                                  |
| `LMS_GPU`                | `max`                           | GPU offload 비율: `max`/`off`/`0~1`                                               |
| `LMS_MODEL_MOUNT`        | (빈값)                          | 빈값=named volume(`lms-models`, 복제본 공유) / 호스트 경로=모델 디렉토리 공유     |
| `GATEWAY_PORT`           | `8080`                          | 게이트웨이 외부 노출 포트(호스트). 컨테이너 내부는 8080 고정                      |
| `LMS_BACKEND_COUNT`      | `2`                             | 백엔드 수(참고용). 실제 스케일은 `--scale lms=N` 으로 지정                        |
| `API_TIMEOUT_MS`         | `600000`                        | claude↔게이트웨이 타임아웃(ms)                                                    |
| `GATEWAY_CONTAINER_NAME` | `gateway`                       |                                                                                   |
| `CLAUDE_CONTAINER_NAME`  | `claude`                        |                                                                                   |
| `LMS_NETWORK_NAME`       | `lms`                           | (lms 백엔드는 `--scale` 위해 container_name 미지정)                               |
| `COMPOSE_PROJECT_NAME`   | `air_gap_claude_code_lms_multi` | 다중 인스턴스 충돌 회피                                                           |
| `USER_UID` / `USER_GID`  | `1000`                          | 호스트 파일 권한 일치 (`id -u`/`id -g`)                                           |
| `TZ`                     | `Asia/Seoul`                    | 컨테이너 시각                                                                     |
| `MOUNT_CODE_DIR`         | (빈값)                          | code override 용 호스트 코드 경로                                                 |

---

## 분산 방식 (nginx)

* **DNS resolve + 세션 고정(기본)**: `nginx.conf.template` 이 Docker 임베디드 DNS(`127.0.0.11`)와 `upstream lms_backends { hash $lms_session_key consistent; server lms:${LMS_PORT} resolve; }` 를 사용 → `lms` 서비스명이 `--scale` 복제본 IP 들로 해석되고, `X-Session` 헤더 기준으로 **세션↔백엔드 고정**(헤더 없는 요청은 `$request_id` 로 랜덤 분산). 백엔드 추가/제거가 `--scale` 만으로 반영됨(게이트웨이 설정 변경 불요).
* **least_conn 정적 upstream(대안)**: 연결 단위 분산이나 백엔드별 GPU 핀(1 GPU=1 백엔드)이 필요하면, 명시적 `lms-1..N` 서비스 + `upstream { least_conn; ... }` 로 전환. (템플릿 하단 주석은 이전 방식인 변수 proxy_pass 예시이며 least_conn 예시는 없음.) (백엔드 수가 compose 에 고정됨)
* **SSE 스트리밍**: `proxy_buffering off` + 타임아웃 600s 로 claude 토큰 스트림 보존.
* **기동 게이팅**: 게이트웨이 healthcheck=`/v1/models` 는 백엔드가 응답해야 200 → 모델 로드(최대 60s) 중 초기 502 동안 claude 기동을 막음.

---

## 알려진 한계 / 트레이드오프 (SSOT 리스크)

* **B1' — 에이전트 tool-use**: 8B 급은 claude 대화형 에이전트 루프에 부적합(환각 도구 호출 무한루프, Issue13 실증). 에이전트 용도면 더 큰/특화 모델(예: `qwen2.5-coder-32b-instruct`↑) 권장. 스모크/API 왕복엔 8B 로 충분.
* **B2 — 다중 모델 라우팅**: 본 예제는 전 백엔드 동일 모델 → model 필드 일치 → nginx 패스스루로 충분. 백엔드마다 다른 모델을 라우팅하려면 body 의 `model` 을 고쳐야 하므로 LiteLLM 격상 필요.
* **B4 — 분산 단위**: 동적 DNS RR 은 요청 단위지만, keepalive/긴 스트리밍 동안 커넥션이 한 백엔드에 사실상 핀될 수 있음. 엄밀한 least_conn 이 필요하면 정적 upstream 대안 사용.
* **B8 — 백엔드 동시성**: 단일 LMS 인스턴스의 요청 직렬/병렬 처리 특성은 미확인 → "동시 세션 ≤ 백엔드 수" 가정으로 운영 권고.
* **B9 — 게이트웨이 SPOF**: 게이트웨이 1개 장애 = 전체 다운. (HA 가 필요하면 게이트웨이 다중화는 별도 설계)

---

## air-gap(폐쇄망) 메모

* 현 구현은 **온라인 빌드 전제**: `Dockerfile.gateway` 가 `nginx:1.27` 풀, `Dockerfile.lms` 가 `install.sh` 로 `lms` 설치, entrypoint 가 `lms get` 으로 모델 다운로드.
* 폐쇄망 반입은 docker `commit`+`save`+`compose` 파이프라인(외부망 빌드 → 매체 → 폐쇄망 load). 게이트웨이(nginx) 이미지도 함께 반입해야 함(`docker pull` 불가).
* `Dockerfile.lms` 에 오프라인 COPY 대안이 주석으로 보존됨. 모델은 디렉토리/매니페스트 구조까지 재현 필요(gguf 복사만으로는 `lms load` 불가, B6).
* **버전 핀**: jinja chat template 회귀 회피를 위해 LM Studio/llmster 버전 고정 권장(검증 시 llmster `0.0.18`), 게이트웨이 `nginx:1.27` 핀.
  (보안 참고: 1.27 은 EOL — 환경 변경 최소화를 위해 핀은 유지하고, nginx 보안 업데이트는 빌드본 컨테이너 안에서 업그레이드→`commit`→`save` 한 반입 tar 로만 적용. 적용본: `6.lms_MultiLLM_run/lms-gateway.tar` = nginx 1.30.3, Issue15)

### ⚠️ 반입 전 반드시 알아야 할 4가지

1. **`docker export` 가 아니라 `docker save` 를 쓴다.** `commit` 으로 만든 이미지는 `docker save`(레이어+메타데이터 보존) → `docker load` 로 복구해야 `ENV`·`ENTRYPOINT`·healthcheck 가 살아난다. `docker export`/`import` 는 컨테이너 FS 를 평탄화하며 이 메타데이터를 **잃어버려** entrypoint 가 동작하지 않는다.
2. **이미지가 3종이다.** `lms-gateway`(nginx) + `lms`(백엔드) + `claude`. `docker pull` 불가하므로 **셋 다** 반입해야 한다.
3. **`commit` 은 볼륨 데이터를 담지 않는다.** 모델(`lms-models`)·claude 홈(`claude-home`)이 named volume 에 있어 commit 만으로는 모델이 빠진다 → 볼륨을 **따로 tar** 해야 폐쇄망에서 재다운로드 없이 동작한다.
4. **`lms` 백엔드는 `--scale` 무명 복제다.** 복제본은 같은 이미지+같은 볼륨을 공유하므로 commit 은 **복제본 1개만** 하면 된다. 복구 시 기동은 반드시 `--scale lms=N --no-build`.

### A. 온라인(빌드) 머신 → `~/export` 로 추출

```bash
mkdir -p ~/export
cd .../5.lms_MultiLLM

# 1) 실행 중 컨테이너를 이미지로 commit (compose의 image: 이름과 일치하도록 태깅)
#    lms 복제본 중 아무거나 1개만 commit (전부 동일 이미지+공유 볼륨)
docker ps --format '{{.Names}}' | grep lms          # 복제본 실제 이름 확인
docker commit gateway                       lms-gateway:latest
docker commit air_gap_claude_code_lms_multi-lms-1 lms:latest
docker commit claude                        claude:latest

# 2) 이미지 저장 (save, 3개 한 파일로)
docker save -o ~/export/images.tar lms-gateway:latest lms:latest claude:latest

# 3) 볼륨 데이터 백업 (commit 에 안 담기므로 필수) — 실제 볼륨명 먼저 확인
docker volume ls | grep lms_multi
VOL_M=air_gap_claude_code_lms_multi_lms-models
VOL_H=air_gap_claude_code_lms_multi_claude-home

docker run --rm -v $VOL_M:/data -v ~/export:/backup alpine \
  tar czf /backup/lms-models.tar.gz  -C /data .
docker run --rm -v $VOL_H:/data -v ~/export:/backup alpine \
  tar czf /backup/claude-home.tar.gz -C /data .

# 4) compose + env 동봉
cp docker-compose.yml docker-compose.gpu.yml docker-compose.code.yml .env ~/export/
```

추출 결과 `~/export/`: `images.tar`, `lms-models.tar.gz`, `claude-home.tar.gz`, `docker-compose*.yml`, `.env`
→ 이 폴더 전체를 매체(USB 등)로 폐쇄망에 반입.

### B. air-gap 서버 (`~/export` 에 파일 있음) → 복구

```bash
cd ~/export

# 1) 이미지 로드 (lms-gateway, lms, claude 한 번에 등록)
docker load -i images.tar

# 2) 볼륨 생성 + 데이터 복원
VOL_M=air_gap_claude_code_lms_multi_lms-models
VOL_H=air_gap_claude_code_lms_multi_claude-home
docker volume create $VOL_M
docker volume create $VOL_H

docker run --rm -v $VOL_M:/data -v ~/export:/backup alpine \
  tar xzf /backup/lms-models.tar.gz  -C /data
docker run --rm -v $VOL_H:/data -v ~/export:/backup alpine \
  tar xzf /backup/claude-home.tar.gz -C /data

# 3) 빌드 없이 로드된 이미지로 기동 (--no-build + --scale 가 핵심)
docker compose up -d --no-build --scale lms=2
#   GPU 사용 시:
#   docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --no-build --scale lms=2

# 4) 확인
docker compose ps               # lms(×N) healthy → gateway healthy → claude
docker compose logs -f gateway  # 백엔드 분산/프록시 로그
docker exec -it claude claude --dangerously-skip-permissions   # cc 는 bash 별칭이라 docker exec 로 직접 호출 불가
```

> `--no-build` 가 빠지면 compose 가 `build:` 섹션 때문에 폐쇄망에서 재빌드를 시도하다 실패한다. `--scale lms=N` 의 N 은 추출 머신과 같은 수(또는 GPU 자원에 맞춰)로 지정한다.

### 검증 포인트

| 항목         | 확인 내용                                                                             |
| :----------- | :------------------------------------------------------------------------------------ |
| 기동 게이팅  | `lms`(×N) `healthy` → `gateway` `healthy`(`/v1/models` 200) → `claude` 순서로 올라옴  |
| 모델 키 일치 | `.env` 의 `LMS_MODEL` 과 복원한 모델 디렉토리가 일치해야 전 백엔드 자동 로드          |
| 볼륨 공유    | 복제본이 `lms-models` 한 볼륨을 공유 → 모델 1벌만 복원하면 모든 백엔드가 사용         |
| UID/GID      | `USER_UID/GID` 가 폐쇄망 호스트와 다르면 볼륨 권한 문제 → 추출 전 `.env` 에서 맞출 것 |

### `save` vs `export` 요약

|              | `docker save` / `load`          | `docker export` / `import`    |
| :----------- | :------------------------------ | :---------------------------- |
| 대상         | 이미지(레이어 전체)             | 컨테이너 FS(평탄화)           |
| 메타데이터   | `ENV`·`ENTRYPOINT`·`CMD` 보존 ✅ | 소실 ❌ (수동 `--change` 필요) |
| 볼륨 데이터  | 미포함 (둘 다 별도 tar)         | 미포함 (둘 다 별도 tar)       |
| 본 예제 권장 | **이것 사용**                   | 비권장                        |

---

## 부록: 멀티모델 번들 이미지 (모델 내장형 단일 tar)

위 A/B 절차는 모델을 named volume 에 두고 **이미지 tar + 볼륨 tar 를 따로** 반입한다.
이와 달리 **번들 이미지**는 여러 모델을 **이미지 레이어에 직접 구워**, 반입 산출물이
**`docker save` tar 단 하나**가 되도록 한 방식이다. 모델 교체 시 재빌드(재다운로드)가
필요하지만, 매체 1개로 끝나 폐쇄망 반입이 단순하다. (예: A6000 48GB 단일 GPU 운용)

**수록 모델** (Q4_K_M, 한 컨테이너에 내장):

| 모델 키                  | 크기     | 아키텍처         |
| :----------------------- | :------- | :--------------- |
| `google/gemma-4-31b-qat` | 18.85 GB | gemma4 31B (QAT) |
| `qwen/qwen3-coder-30b`   | 18.63 GB | qwen3moe 30B-A3B |
| `zai-org/glm-4.7-flash`  | 18.13 GB | 30B A3B (MoE)    |

(+ `text-embedding-nomic-embed-text-v1.5` 84 MB 동봉) → 이미지 **~61 GB**, tar **~61 GB**.

> ⚠️ **핵심**: 모델을 **VOLUME 이 아닌 컨테이너 RW 레이어**에 받아야 `commit` 에 담긴다.
> 따라서 다운로드 컨테이너에는 **모델 볼륨을 마운트하지 않는다**. (`Dockerfile.lms` 는
> `/home/lms/.lmstudio/models` 를 VOLUME 으로 선언하지 않으므로, 볼륨만 안 붙이면 레이어에 쌓인다.)

### P. 패키징 (온라인 빌드 머신)

```bash
IMG=lms:latest                 # 기존 lms 백엔드 이미지 (Dockerfile.lms 산출물)
C=lms-bundle

# 1) 볼륨 미마운트 컨테이너 — 모델이 컨테이너 RW 레이어에 쌓이도록 (entrypoint 는 sleep 으로 대체)
docker run -d --name $C --entrypoint sleep $IMG infinity

# 2) 데몬 기동 + 모델 다운로드 (Q4_K_M). 느릴 수 있으니 백그라운드 권장.
docker exec $C bash -lc '
  export PATH=$HOME/.lmstudio/bin:$PATH
  lms daemon up; until lms daemon status >/dev/null 2>&1; do sleep 1; done
  lms get -y --gguf google/gemma-4-31b-qat
  lms get -y --gguf qwen/qwen3-coder-30b@q4_k_m
  lms get -y --gguf zai-org/glm-4.7-flash@q4_k_m
  lms ls                       # 3개 모두 Local 로 보이면 완료
'

# 3) 이미지로 굽기 — ENTRYPOINT 원복 필수 (2)에서 sleep 으로 덮었으므로)
docker commit --change 'ENTRYPOINT ["/usr/local/bin/entrypoint.lms.sh"]' \
  $C air-gap-lms-bundle:latest

# 4) 단일 tar 로 export (save 사용, export 아님)
mkdir -p ~/_exports
docker save air-gap-lms-bundle:latest -o ~/_exports/air-gap-lms-bundle.tar

# 5) 정리
docker rm -f $C
```

> ⚠️ **번들만으로는 `cc` 가 안 돈다.** 번들은 LMS 백엔드+모델일 뿐이다. `cc` 실행 본체인
> **`claude` 이미지**(와 게이트웨이 토폴로지를 쓸 경우 **`lms-gateway`**)도 함께 반입해야 한다.
> `docker pull` 이 안 되므로 같이 save 한다(소형, ~0.9 GB).

```bash
# claude + gateway 이미지 동봉 (Dockerfile.claude/gateway 빌드 산출물)
docker save -o ~/_exports/air-gap-claude-gateway.tar claude:latest lms-gateway:latest
# compose·env·nginx 설정도 동봉
cp docker-compose.yml docker-compose.gpu.yml .env nginx.conf.template ~/_exports/
```

**반입물 정리** (`~/_exports/`):

| 파일                                                 | 내용                            |
| :--------------------------------------------------- | :------------------------------ |
| `air-gap-lms-bundle.tar` (~58 GB)                    | LMS 백엔드 + 모델 3종 (내장)    |
| `air-gap-claude-gateway.tar` (~0.9 GB)               | `claude` + `lms-gateway` 이미지 |
| `docker-compose*.yml`, `.env`, `nginx.conf.template` | 기동 설정                       |

모델이 이미지에 내장되어 **볼륨 별도 tar 는 불필요**하다.

### I. import (폐쇄망 A6000 머신)

```bash
# 1) 이미지 로드 (3종: bundle, claude, gateway)
docker load -i air-gap-lms-bundle.tar          # air-gap-lms-bundle:latest
docker load -i air-gap-claude-gateway.tar      # claude:latest, lms-gateway:latest
```

#### 방법 ① 게이트웨이 없이 직결 (단일 백엔드 — 권장)

단일 A6000 은 한 번에 1모델이라 분산(게이트웨이)이 무의미하다. claude 가 LMS 에 직접 붙는다.

```bash
docker network create lmsnet

# LMS 백엔드 — 모델이 이미지에 내장됨. ⚠️ 모델 볼륨을 마운트하지 말 것(내장 모델을 가림)
docker run -d --name lms --network lmsnet --gpus all \
  -e LMS_MODEL=qwen/qwen3-coder-30b \
  -e LMS_CONTEXT_LENGTH=262144 -e LMS_GPU=max \
  air-gap-lms-bundle:latest
#   LMS_MODEL 지정 시 entrypoint 가 부팅에 해당 모델 자동 로드.
#   (lms get 은 허브 접속 시도 → 내장돼 있으면 경고 후 통과, load 는 성공)

docker exec lms lms ls        # 3개 모두 Local 확인

# claude — 게이트웨이 대신 lms:1234 직결 (GW_HOST/GW_PORT 로 주소 지정)
docker run -it --name claude --network lmsnet \
  -e GW_HOST=lms -e GW_PORT=1234 \
  -e ANTHROPIC_MODEL=qwen/qwen3-coder-30b \
  claude:latest claude --dangerously-skip-permissions
```

모델 교체는 LMS 에서 직접:

```bash
docker exec lms lms unload --all
docker exec lms lms load zai-org/glm-4.7-flash --yes --gpu max --context-length 131072
# claude 쪽 모델명도 맞추려면 ANTHROPIC_MODEL 바꿔 재기동
```

#### 방법 ② 게이트웨이 포함 (compose 토폴로지 유지)

```bash
docker tag air-gap-lms-bundle:latest lms:latest   # compose 의 lms 서비스 image 와 이름 일치
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --no-build --scale lms=1
```

> ⚠️ **compose 의 볼륨 마운트 주의.** `docker-compose.yml` 의 `lms` 서비스는 `lms-models`
> named volume 을 `/home/lms/.lmstudio/models` 에 마운트한다 → **이미지에 구운 모델을 가린다**(빈 볼륨이면 `No models loaded`). 번들을 compose 로 쓰려면 `lms` 서비스의 해당 **volumes 마운트를 제거**해야 한다. 번거로우면 단일 백엔드에선 **방법 ①** 을 쓴다.

> **A6000 48GB 운용 메모**
> * **동시 로드 불가** — 3개 중 1개만 VRAM 에 올린다(JIT). 30B Q4(가중치 ~18 GB) 로드 시 나머지 ~30 GB 가 KV 캐시 여유.
> * **컨텍스트 상한** = 모델 지원 한도 ∩ KV 캐시 VRAM 여유. 위 `--context-length` 는 *시도값* 이며, 로드 실패(OOM)면 절반씩 낮춘다. (qwen3-coder 는 대용량 컨텍스트, gemma-4·glm 은 보통 128K 급 — 정확한 한도는 모델 카드 확인.)
> * **모델 키 일치** — claude 의 `ANTHROPIC_MODEL` 과 LMS 에 로드된 모델 키가 같아야 한다.

### 번들 방식 vs 볼륨 분리 방식

|             | 번들 이미지 (부록 P/I)      | 볼륨 분리 (A/B)           |
| :---------- | :-------------------------- | :------------------------ |
| 반입 산출물 | **tar 1개**                 | images.tar + 볼륨 tar(들) |
| 모델 교체   | 재빌드(재다운로드) 필요     | 볼륨 tar 만 교체          |
| 다중 모델   | 한 이미지에 N개 내장        | 한 볼륨에 N개             |
| 적합한 상황 | 매체 단순화·**고정 모델셋** | 모델 갱신이 잦은 경우     |

> `save`/`load` 사용 이유, `commit` 의 메타데이터·볼륨 주의점은 위 [`save` vs `export` 요약](#save-vs-export-요약) 과 동일하다.

---

## 검증 상태

* ✅ `docker compose config` (기본 / +gpu / +code) 3종 통과
* ✅ `bash -n entrypoint.lms.sh entrypoint.sh`
* ✅ nginx 템플릿 envsubst 전개 후 `nginx -t` 성공 (`$lms_pool`/`$host` 보존, `${LMS_PORT}`→1234)
* ⏸️ 실 다중 백엔드 `up --scale` — GPU·온라인 LMS·모델 다운로드 의존 → GPU 호스트에서 별도 검증
* 상세: [`_doc_work/report/lms-multi-llm_report.md`](../_doc_work/report/lms-multi-llm_report.md)
