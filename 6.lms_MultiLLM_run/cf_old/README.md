# 6.lms_MultiLLM_run

**5.lms_MultiLLM 을 순수 `docker run` 으로 이식한 판.** docker compose 가 없거나 추가 설치가 불가한 air-gap 시스템 대상.

이 폴더 하나만 대상 시스템으로 복사하면 `./start.sh` 로 5.lms_MultiLLM 과 동일한 토폴로지(claude → nginx gateway → LMS 백엔드 풀 N개)를 기동한다.

---

## 왜 6.lms_MultiLLM_run?

| 항목              | 5.lms_MultiLLM                     | 6.lms_MultiLLM_run                                                 |
| :---------------- | :--------------------------------- | :----------------------------------------------------------------- |
| 오케스트레이션    | `docker compose`                   | 순수 `docker run` (`start.sh`)                                     |
| 대상 환경         | 온라인 · docker compose 설치됨     | air-gap · compose 없음 · 추가 설치 불가                            |
| 이미지            | 로컬 `build` 로 준비               | 사전 `docker load -i *.tar` 로 반입                                |
| 백엔드 스케일     | `--scale lms=N`                    | `LMS_BACKEND_COUNT=N` (lms-1 … lms-N)                              |
| nginx 백엔드 분산 | Docker DNS RR (compose 서비스명)   | Docker DNS RR (`--network-alias lms`)                              |
| entrypoint 배포   | Dockerfile `COPY` 로 이미지에 굽힘 | 폴더의 스크립트를 `:ro` bind mount + `--entrypoint` 로 런타임 주입 |

## 왜 entrypoint 스크립트를 폴더에서 주입하는가

대상 air-gap 시스템의 `lms:latest` 는 **4.lms_OneLLM 판 Dockerfile 로 만들어진 이미지** 로 반입됨. 안에 구운 `entrypoint.lms.sh` 는 4 버전. 5.lms_MultiLLM 이 요구하는 게이트웨이 토폴로지 로직(claude 의 `GW_HOST/GW_PORT`)과 어긋날 수 있어, 스크립트 두 개를 이 폴더에 원본 그대로 두고 **컨테이너 기동 시 `-v ...:ro` + `--entrypoint`** 로 override 한다. 이미지 재빌드 없이 스크립트만 바꿔도 반영되는 이점도 있다.

* `entrypoint.lms.sh` — LMS 백엔드 PID1 (`lms daemon up` → `server start` → `/v1/models` 폴링 → 모델 로드 → `lms log stream`). 4·5 판이 실질적으로 동일하지만 안전 override.
* `entrypoint.sh` — claude 클라이언트 PID1. **여기가 실제로 4·5 판이 다른 부분** — 5 판은 `GW_HOST/GW_PORT` 로 게이트웨이에 직결.

---

## 폴더 구성

```
6.lms_MultiLLM_run/
├── start.sh              # 메인 기동 스크립트 (docker run 오케스트레이션)
├── entrypoint.lms.sh     # LMS 백엔드 PID1 (런타임 주입, CUDA 자동선택+LMS_PARALLEL 패치 포함)
├── entrypoint.sh         # claude 클라이언트 PID1 (5.판, 런타임 주입)
├── nginx.conf.template   # nginx 설정 템플릿 (:ro 마운트, ${LMS_PORT} envsubst)
├── .env                  # 검증 완료 working 설정 (그대로 사용 권장)
├── .env.org              # 파라미터 템플릿 (주석 상세)
├── _img/                 # 반입용 이미지 tar 모음 (git 미추적)
│   ├── lms-gateway.tar   # lms-gateway:latest — nginx 1.30.3 (~209MB)
│   ├── claude.tar        # claude:latest — Claude Code CLI (~720MB)
│   └── SHA256SUMS        # tar 무결성 검증 (_img/ 안에서 sha256sum -c SHA256SUMS)
├── vscode-connect.sh     # (Linux/mac) 호스트 VSCode 확장 → 게이트웨이 연결/해제 패치
├── vscode-connect.ps1    # (Windows) 위의 PowerShell 판 (-BaseUrl/-Model 인자)
├── lms-jinja-fix.sh      # Jinja 템플릿 오류 진단·우회 패치
├── PATCH.md              # 위 패치 2종 사용법
├── info_jinja_and_lms.md # jinja/GPU 문제 진단 기록
├── info_modelTuning.md   # 모델/컨텍스트 튜닝 기록 (KV quant·SWA 등)
├── info_promptDiet.md    # 프롬프트 다이어트 근거·측정
├── Dockerfile.small      # lms:small — 저VRAM 멀티 백엔드 테스트용 경량 이미지 (아래 절 참조)
├── build.small.sh        # lms:small 빌드 스크립트 (build.small/models/ 에 gguf 필요)
├── TEST.md               # 멀티 백엔드 검증 절차 (분산·판별·40k needle·claude 종단)
└── README.md
```

> `_img/` 하위 tar·SHA256SUMS 는 git 미추적 (매체 복사로만 전달). **air-gap 반입 시 이 폴더 전체를 복사**하면 외부 의존 없음 — 단, `lms:latest` 이미지(24.7GB)는 **기반입 완료 전제** (아래 사전 조건 2 참조).

---

## 사전 조건 (대상 air-gap 시스템)

1. **docker 엔진** 설치되어 있어야 함 (`docker` CLI 사용 가능). GPU 사용 시 **NVIDIA 드라이버 + `nvidia-container-toolkit`** 필요 (`--gpus all` 전제).
2. **LMS 백엔드 이미지 (`lms:latest`) — 기반입 완료 전제.** air-gap 호스트에 이미 로드돼 있어야 한다 (gemma-4-31b-qat 18GB GGUF + CUDA 런타임 내장, ~24.7GB). 이 폴더에는 포함하지 않는다. 확인:
   ```bash
   docker image inspect lms:latest >/dev/null && echo OK
   ```
3. **나머지 이미지 반입** — **tar 2종이 이 폴더 `_img/` 에 내장** (git 미추적, 매체 복사로만 전달):

   | tar                    | 이미지 (load 결과)                      | 크기   | 내용                                                               |
   | :--------------------- | :-------------------------------------- | :----- | :----------------------------------------------------------------- |
   | `_img/lms-gateway.tar` | `lms-gateway:latest` (+`:nginx-1.30.3`) | ~209MB | nginx **1.30.3** (2026-06 보안 픽스 포함, 2026-07-15 업그레이드본) |
   | `_img/claude.tar`      | `claude:latest`                         | ~720MB | Claude Code CLI v2.1.195 + Node 22                                 |

   ```bash
   # (air-gap 호스트에서, 이 폴더 안)
   (cd _img && sha256sum -c SHA256SUMS)   # 매체 손상 검증 (반입 직후)
   docker load -i _img/lms-gateway.tar
   docker load -i _img/claude.tar
   ```
   `.env` 의 `GATEWAY_IMAGE=lms-gateway:latest` 가 이미 맞춰져 있음. 태그가 다르면 `LMS_IMAGE=`/`GATEWAY_IMAGE=`/`CLAUDE_IMAGE=` 오버라이드.

4. **모델 파일 — 별도 반입 불필요.** 기반입 `lms:latest` 이미지에 `google/gemma-4-31b-qat` 내장. `LMS_MODEL_MOUNT` 빈값(named volume)이어도 이미지 내장본으로 동작.

### DVD 반입

폴더 총량 ~1GB (tar 2종 + 스크립트·문서) — **DVD 1장(4.7GB)에 통째로 들어간다.** 폴더 전체를 그대로 굽고, air-gap 측에서 통째로 복사 → `(cd _img && sha256sum -c SHA256SUMS)` 검증 후 진행.

### air-gap GPU 동작 검증 결과 (2026-07-15, 테스트 서버)

* `lms:latest` 이미지에 CUDA 엔진 **내장** 확인: `llama.cpp-linux-x86_64-nvidia-cuda-avx2-2.23.1` (다운로드 불필요 — fresh 컨테이너에서 확인).
* `entrypoint.lms.sh` 3.5절이 부팅 시 CUDA 런타임 자동 선택 → 테스트 서버(16GB GPU)에서 VRAM 15.4GB 오프로드 동작 확인.
* ⚠️ `LMS_GPU=max` 금지: VRAM(16GB) < 모델(18.85GB) 환경에서 통짜 할당 시도 → CUDA OOM. **빈값(자동)** 이 정답. VRAM 이 모델보다 큰 장비(예: A6000 48GB)는 자동으로 전량 오프로드됨.

---

## 사용법

> ℹ️ **동봉된 `.env` 는 이미 폐쇄망 운영 구성**(`lms:latest`·`gemma-4-31b-qat`·백엔드 2개)이다.
> `.env.org` 와 실질 차이는 없으므로 `cp .env.org .env` 는 선택 사항 —
> `.env` 를 만졌다가 되돌리고 싶을 때의 복구 수단으로 쓰면 된다.
>
> ⚠️ **기동 전 확인할 것은 GPU 장수**: `LMS_BACKEND_COUNT` 는 GPU 1장당 1백엔드가 원칙이다.
> `start.sh` 가 `nvidia-smi` 로 GPU 수를 세어 백엔드를 GPU 0,1,2… 에 1:1 로 핀하고,
> 백엔드 > GPU 면 VRAM 초과 경로이므로 **기동을 중단**한다. GPU 1장 머신이면 `1` 로 낮출 것.

```bash
cd 6.lms_MultiLLM_run/
nvidia-smi -L               # ← GPU 장수 확인 후 LMS_BACKEND_COUNT 결정
# cp .env.org .env          # (선택) 기본값으로 되돌리고 싶을 때만
vi .env                     # LMS_MODEL, GATEWAY_PORT, LMS_BACKEND_COUNT 조정

./start.sh                  # 기본 (GPU 사용)
USE_GPU=0 ./start.sh        # CPU 강제

./start.sh --status         # 상태 확인
./start.sh --stop           # 정지 + 제거 (네트워크·볼륨 유지)

docker exec -it claude bash
cc                          # alias = claude --dangerously-skip-permissions
```

기동 확인:

```bash
curl -fsS http://127.0.0.1:8080/v1/models | jq .
docker logs -f gateway
docker logs -f lms-1
```

---

## .env 주요 파라미터

`.env.org` 는 5.lms_MultiLLM 과 동일 스키마. 추가로 6.판이 인식하는 것:

| 변수                       | 기본값               | 설명                                                                                                                                                                                                                                            |
| :------------------------- | :------------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LMS_BACKEND_COUNT`        | `2`                  | **실제 기동 개수** (lms-1..N). GPU 1장당 1개가 원칙 — `start.sh` 가 GPU 수를 세어 1:1 핀하고, 백엔드 > GPU 면 기동 중단                                                                                                                         |
| `LMS_PARALLEL`             | `1`                  | 동시 예측 슬롯. llmster 는 **컨텍스트를 슬롯 수로 분할**(기본 4 → 32k 가 슬롯당 8k). Claude Code 시스템 프롬프트 ~16k 초과 시 500 (`n_keep >= n_ctx`) — **반드시 1**                                                                            |
| `LMS_GPU`                  | `max`                | GPU offload. **A6000(48GB) 반입 환경은 `max`**(31b 18.85GB + 32k KV 전체 탑재). 16GB 급은 빈값(자동)/`0.x` — `max` 면 CUDA OOM. 로드 후 VRAM 사용률 **83% 이하** 유지(prefill 연산 버퍼가 추론 시점에 추가로 필요 — 97% 구성은 장문에서 크래시) |
| `LMS_CONTEXT_LENGTH`       | `32768`              | 컨텍스트 상한. Claude Code 시스템+도구 페이로드가 커서 32768 미만이면 동작 불가                                                                                                                                                                 |
| `CLAUDE_DIET`              | `1`                  | 프롬프트 다이어트. `1`=도구 4개(Read/Bash/Edit/Write)만 노출 → 프롬프트 19.4k→3.0k(-84%), 종단 **2.0배 단축**(이 스택 실측). `0`=전체 도구. ⚠️ `0` 이어도 `WebSearch`/`WebFetch` 는 항상 차단(폐쇄망)                                            |
| `LMS_SKIP_GET`             | `1`                  | `1` 이면 기동 시 `lms get`(허브 접속) 을 완전히 건너뜀. **완전 폐쇄망 권장** — 로컬 보유 모델만 사용                                                                                                                                            |
| `LMS_GET_TIMEOUT`          | `60`                 | `lms get` 상한(초). 폐쇄망 blackhole 방화벽에서 무한 대기 방지                                                                                                                                                                                  |
| `CLAUDE_MAX_OUTPUT_TOKENS` | `8192`               | Claude Code 출력 상한. 32k 컨텍스트에 input+output 합산이 들어가야 함                                                                                                                                                                           |
| `USE_GPU`                  | `1`                  | `1` = `--gpus all`, `0` = CPU                                                                                                                                                                                                                   |
| `LMS_IMAGE`                | `lms:latest`         | 반입한 이미지 태그와 다르면 오버라이드                                                                                                                                                                                                          |
| `GATEWAY_IMAGE`            | `lms-gateway:latest` | (`.env` 에 지정됨 — 폴더 tar 의 load 결과와 일치)                                                                                                                                                                                               |
| `CLAUDE_IMAGE`             | `claude:latest`      | 상동                                                                                                                                                                                                                                            |
| `MOUNT_CODE_DIR`           | (빈값)               | 지정 시 `$MOUNT_CODE_DIR → /home/ubuntu/code` 마운트                                                                                                                                                                                            |

---

## 아키텍처

```
                     ┌──── docker network: lms ─────────────────────────────┐
┌──────────┐  :8080  │  ┌─────────┐    ┌──────────────────────────────────┐ │
│  claude  │ ──────► │  │ gateway │──► │ lms-1 (alias:lms)  entrypoint.lms│ │
│ (5.판    │         │  │ (nginx) │──► │ lms-2 (alias:lms)  entrypoint.lms│ │
│  entry)  │         │  └─────────┘──► │ ...                              │ │
└──────────┘         │   L7 분산        └──────────────────────────────────┘ │
                     └──────────────────────────────────────────────────────┘
   entrypoint.sh :ro 주입                       entrypoint.lms.sh :ro 주입
   (GW_HOST/GW_PORT)                            (동일 폴더의 스크립트 override)
```

- `lms-1..N` 은 모두 `--network-alias lms` 로 붙어 있어 nginx 안 `resolver 127.0.0.11` + `proxy_pass http://lms:${LMS_PORT}` 가 라운드로빈으로 분산 (5.판과 동일 원리).
- claude 는 nginx 게이트웨이 단일 주소(`http://gateway:8080`)로 직결. 변환 프록시 없음(순수 OpenAI /v1 패스스루).

---

## lms:small — 저VRAM 멀티 백엔드 테스트 이미지 (2026-07-16 실측 검증)

16GB GPU 에서 `gemma-4-31b-qat`(단독 15.4GB 점유)로는 멀티 백엔드가 불가능하므로,
**컨텍스트를 최대(128k)로 쓸 수 있는 소형 모델을 내장한 `lms:small`** 로 멀티 LLM 을 검증한다.
`FROM lms:latest` 레이어 추가 방식이라 **`lms:latest` 원본은 바이트 하나 변경되지 않는다.**

* **모델**: `google/gemma-4-e2b` (4.6B, Q4_K_M 3.2GB + mmproj 0.9GB)
  * `context_length` **131072 (128k)** — KV 헤드 1개(MQA) + sliding window 512 라 128k 풀 컨텍스트도 KV 캐시가 극소
  * 실측 VRAM: **백엔드 1개당 ~3.95GB** (128k ctx, `--gpu max`) → 16GB GPU 에 **2개 탑재 후 8.2GB 여유** (3개도 가능 추정)
* **빌드**: `./build.small.sh` (모델 gguf 는 `build.small/models/…` 에 필요 — git 미추적, 온라인 머신에서 `lms get -y google/gemma-4-e2b` 후 `docker cp` 로 준비)
* **신규 볼륨 프리팝**: 이미지에 모델이 내장돼 있어, 새 named volume 을 `/home/lms/.lmstudio/models` 에 마운트하면 docker 가 자동 복사 — air-gap 반입 후 별도 모델 복사 불필요
* **.env 전환** (현재 커밋된 `.env` 가 이 구성):
  ```bash
  LMS_IMAGE=lms:small
  LMS_MODEL=google/gemma-4-e2b
  LMS_CONTEXT_LENGTH=131072
  LMS_GPU=max              # 주의: 빈값(자동)이면 CPU 로드 되는 경우 있음 — small 은 max 고정
  LMS_BACKEND_COUNT=2
  LMS_MODEL_MOUNT=lms-models-small
  CLAUDE_MAX_OUTPUT_TOKENS=32000   # 128k ctx 라 Claude Code 기본치 그대로 허용
  ```
* **검증 결과 (2026-07-16)**: 2 백엔드 로드(각 128k ctx) → nginx 라운드로빈 분산 확인 →
  **40,046 토큰** needle 테스트 통과(11.7s prefill, 정확 회수) → claude 컨테이너 `claude -p` 응답 정상.
* 31b 구성으로 복귀: `cp .env.org .env` 후 `./start.sh` — 동봉 `.env`/`.env.org` 둘 다 31b·`lms:latest` 운영 기본값이므로, 위 lms:small 설정으로 바꿔 쓴 경우에만 필요하다.

---

## 백업 / 복구 (2026-07-18 실측 검증)

폐쇄망에는 `alpine` 등을 pull 할 수 없으므로 **이미 반입한 `claude:latest` 이미지**로 수행한다
(`tar`·`gzip` 내장 확인됨). `lms:latest` 로 대체해도 동일하게 동작한다.

### 무엇을 백업하나

| 대상                      | 내용                                                                  | 백업 필요성                                                                            |
| :------------------------ | :-------------------------------------------------------------------- | :------------------------------------------------------------------------------------- |
| **`claude-home` 볼륨**    | `/home/ubuntu` — Claude Code 설정·대화 이력·컨테이너 안에서 만든 파일 | **필수.** 유일하게 재생성 불가한 사용자 데이터                                         |
| `.env` (호스트 파일)      | 기동 파라미터                                                         | **필수.** 텍스트라 그냥 복사                                                           |
| 모델 볼륨 (`lms-models*`) | GGUF 모델                                                             | 보통 불필요 — `lms:latest`/`lms:small` 이미지에서 자동 프리팝됨. 별도 반입 모델만 대상 |

> ⚠️ `--user root` 필수. `claude:latest` 는 비루트(ubuntu)로 실행되어 볼륨에 쓰지 못하고,
> 복구 시 `tar: Cannot utime: Operation not permitted` 로 실패한다.
> 백업/복구 전에는 `./start.sh --stop` 으로 정지해 일관된 스냅샷을 뜰 것.

### 백업

```bash
cd 6.lms_MultiLLM_run/
./start.sh --stop                      # 일관성 위해 정지

docker run --rm --user root \
  -v claude-home:/data -v "$PWD":/backup --entrypoint sh claude:latest \
  -c 'tar czf /backup/claude-home.tgz -C /data .'

cp .env .env.backup                    # 설정도 함께 보관
ls -lh claude-home.tgz
```

모델 볼륨까지 뜨려면 (`.env` 의 `LMS_MODEL_MOUNT` 값으로 교체 — 기본 `lms-models`):

```bash
docker run --rm --user root \
  -v lms-models:/data -v "$PWD":/backup --entrypoint sh claude:latest \
  -c 'tar czf /backup/lms-models.tgz -C /data .'
```

### 복구

```bash
./start.sh --stop
docker volume rm claude-home 2>/dev/null; docker volume create claude-home

docker run --rm --user root \
  -v claude-home:/data -v "$PWD":/backup --entrypoint sh claude:latest \
  -c 'tar xzf /backup/claude-home.tgz -C /data'

cp .env.backup .env                    # 필요 시 설정 복원
./start.sh
```

검증 — 내용과 소유권(`1000:1000`)이 함께 복원되어야 한다:

```bash
docker run --rm --user root -v claude-home:/data --entrypoint sh claude:latest \
  -c 'ls -la /data && stat -c "%u:%g %n" /data/.claude'
#   기대: uid:gid 가 1000:1000 (ubuntu). root 소유면 컨테이너가 설정을 못 씀
```

### 재기동 / 이미지 교체

* **설정만 바꿀 때**: `.env` 수정 후 `./start.sh` — 컨테이너는 `docker rm -f` 후 재생성되지만
  볼륨은 유지되므로 대화 이력·설정은 보존된다.
* **claude CLI 갱신본 반입 시**: 새 tar 를 `docker load` → 태그가 같으면(`claude:latest`)
  `./start.sh` 만 다시 실행. `claude-home` 볼륨은 그대로라 사용자 데이터 유지.
* **완전 초기화**: `./start.sh --stop` 후 `docker volume rm claude-home lms-models`
  (⚠️ 대화 이력 소실 — 위 백업 선행 권장).

---

## 5.판 대비 제약

* **동시 모델 다운로드 경합**: `LMS_MODEL_MOUNT` 을 named volume 으로 두면 모든 백엔드가 같은 볼륨을 공유. 최초 1회는 `LMS_BACKEND_COUNT=1` 로 시작해 모델을 채운 뒤 늘리기 권장.
* **healthcheck**: docker HEALTHCHECK 대신 `start.sh` 안의 능동 폴링으로 대체. 컨테이너 스스로는 healthy 상태 라벨을 갖지 않음.
* **부팅 후 자동 기동**: 3개 컨테이너 모두 `--restart unless-stopped` 이며, `docker.service` 가 enable 돼 있으면 이것으로 충분하다 — 별도 systemd 유닛 등록 불필요(prj55 fg1/lms 에서 확인된 결론). 확인: `systemctl is-enabled docker`.

---

## Multi-GPU 배치 (자동 — 2026-07-18 구현)

`start.sh` 가 `nvidia-smi -L` 로 GPU 수를 세어 백엔드를 **GPU 1장당 1개씩 1:1 로 핀**한다
(`--gpus "device=K"`). 수동 편집이 필요했던 이전 판과 달리 별도 조치가 없다.

| 시나리오                  | 동작                                                                                                                   |
| :------------------------ | :--------------------------------------------------------------------------------------------------------------------- |
| GPU N장 + 백엔드 N개      | `lms-1→GPU0`, `lms-2→GPU1` … 자동 핀. **권장 구성**                                                                    |
| GPU N장 + 백엔드 M<N개    | 앞쪽 GPU 부터 사용, 나머지 GPU 는 유휴                                                                                 |
| GPU 1장 + 백엔드 2개 이상 | **기동 중단** — 같은 GPU 다중 적재는 VRAM 초과 경로(31b ×2 ≈ 50~66GB > 48GB). `.env` 의 `LMS_BACKEND_COUNT` 를 낮출 것 |
| 초과 구독을 감수          | `LMS_ALLOW_GPU_OVERSUBSCRIBE=1 ./start.sh` — 경고 후 강행(GPU 순환 배치)                                               |
| GPU 미감지 / `USE_GPU=0`  | `--gpus all` 또는 CPU 로 폴백                                                                                          |

기동 로그에 배치 결과가 찍힌다:

```
[*] 감지된 GPU: 2장 / 백엔드: 2개
  [+] lms-1 기동 (GPU 0)
  [+] lms-2 기동 (GPU 1)
```

반입 후 확인 절차:

```bash
nvidia-smi -L                            # GPU 장수 → LMS_BACKEND_COUNT 결정
./start.sh
docker exec lms-1 lms ps                 # 백엔드별 모델 로드 확인
docker exec lms-2 lms ps
nvidia-smi                               # GPU 별 VRAM 분산 + 사용률 ≤83% 확인
for i in 1 2 3 4; do curl -sS -X POST http://127.0.0.1:8080/v1/messages \
  -H 'Content-Type: application/json' -H 'x-api-key: lms' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"google/gemma-4-31b-qat","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' & done; wait
                                         # 동시 4요청 → 분산 확인
```

> ⚠️ VRAM 사용률은 **장문 프롬프트로** 확인할 것. KV 는 로드 시 선할당되지만 prefill 연산
> 버퍼는 추론 시점에 추가로 잡힌다 — 짧은 프롬프트만 통과시키고 41k 에서 죽은 사례가 있다.

---

## 호스트 VSCode Claude Code 확장으로 접속

컨테이너 내부 `cc` 대신, **호스트에서 실행하는 VSCode 의 Claude Code 확장**을 이 스택의
게이트웨이에 붙일 수 있다. 확장은 CLI 와 동일하게 `settings.json`(전역: Linux/mac `~/.claude/`,
Windows `%USERPROFILE%\.claude\`)을 읽으므로, 거기에 `ANTHROPIC_BASE_URL`·`ANTHROPIC_AUTH_TOKEN`·
`model` 을 넣으면 된다. 이를 자동화한 것이 OS 별 두 스크립트 — **`vscode-connect.sh`**(Linux/mac)·
**`vscode-connect.ps1`**(Windows) — 이며 둘 다 되돌리기 가능(넣은 키만 제거).

* **접속 대상 주소**: 같은 호스트면 `http://127.0.0.1:${GATEWAY_PORT}`, **다른 머신(Windows 등)에서는
  `http://<GPU호스트IP>:${GATEWAY_PORT}`**. `start.sh` 는 게이트웨이 포트를 `0.0.0.0` 으로 publish 하므로
  (`-p ${GATEWAY_PORT}:8080`) LAN 에서 바로 접근된다.
* ⚠️ **게이트웨이/LMS `/v1` 는 무인증**(토큰 `lms` 는 형식상). **신뢰 LAN·폐쇄망 전제** — 외부 노출 금지.
  원격 접속이 안 되면 GPU 호스트 방화벽에서 `${GATEWAY_PORT}` 인바운드 허용 확인.

### Linux / macOS — `vscode-connect.sh`

```bash
./start.sh                    # 먼저 스택 기동 (gateway :8080 노출)

./vscode-connect.sh on        # ~/.claude/settings.json 병합(백업 후) → 게이트웨이 연결
./vscode-connect.sh status    # 현재 설정 + 게이트웨이 모델 목록
./vscode-connect.sh off       # 우리가 넣은 키만 제거 → Anthropic 복귀

# 적용 후 VSCode: 명령팔레트 → 'Developer: Reload Window'
```

* 넣는 값: `ANTHROPIC_BASE_URL=http://127.0.0.1:${GATEWAY_PORT}`, `ANTHROPIC_AUTH_TOKEN=lms`,
  `model=${LMS_MODEL}` (기존 키는 보존, 최초 실행 시 `settings.json.bak` 백업).
* **원격/다른 머신에서 접속**: `LMS_HOST=<GPU호스트IP> ./vscode-connect.sh on`.
* **워크스페이스로 한정**(전역 오염 회피): `CLAUDE_SETTINGS=.claude/settings.local.json ./vscode-connect.sh on`.

> ⚠️ **전역 설정을 바꾼다.** 기본 대상이 `~/.claude/settings.json` 이라, 적용하면 호스트의
> 모든 Claude Code(CLI·확장)가 로컬 LMS 로 향한다. 실제 Anthropic 로 되돌리려면 `off`
> (또는 `cp ~/.claude/settings.json.bak ~/.claude/settings.json`). 프로젝트에만 적용하려면
> 위 `CLAUDE_SETTINGS=` 워크스페이스 옵션을 쓸 것.

### Windows — `vscode-connect.ps1`

Windows 의 VSCode Claude Code 확장은 `%USERPROFILE%\.claude\settings.json` 을 읽는다. `.sh` 와
동일 키를 병합하는 PowerShell 판(5.1+, `jq` 불필요·BOM 없는 UTF-8 기록·최초 1회 `.bak` 백업)이
**`vscode-connect.ps1`** 이다. `.sh` 와 달리 `.env` 를 읽지 않고 **`-BaseUrl`·`-Model` 을 인자로 받는다**.

```powershell
# 실행정책에 막히면 앞에 -ExecutionPolicy Bypass
powershell -ExecutionPolicy Bypass -File .\vscode-connect.ps1 -Action on `
  -BaseUrl http://<GPU호스트IP>:8080 -Model google/gemma-4-e2b   # 게이트웨이 접속(원격)
#   -BaseUrl http://localhost:1234                                # (참고) 로컬 LM Studio 직결 시

.\vscode-connect.ps1 -Action status    # 현재 설정 + 게이트웨이 모델 목록
.\vscode-connect.ps1 -Action off        # 우리가 넣은 키만 제거 → Anthropic 복귀

# 적용 후 VSCode: 명령팔레트(Ctrl+Shift+P) → 'Developer: Reload Window'
```

* 넣는 값은 `.sh` 와 동일: `ANTHROPIC_BASE_URL`·`ANTHROPIC_AUTH_TOKEN=lms`·`API_TIMEOUT_MS`·
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`·`model`. `-Model` 은 게이트웨이가 서빙하는 키와 일치해야 함
  (`vscode-connect.ps1 -Action status` 로 목록 확인).
* `-Settings <경로>` 로 대상 파일 변경 가능(워크스페이스 `.claude\settings.local.json` 로 한정 시).
* 전역 설정을 바꾸는 것은 `.sh` 와 동일 — `off` 또는 `Copy-Item settings.json.bak settings.json` 로 원복.

> 참고: 학생 Windows PC 에 **로컬로 LM Studio 를 설치**해 각자 실습하는 수업용 절차는 jm4 Obsidian
> `3.Resource/_LLM/Tools/LM_Studio_Windows_ClaudeCode_수업.md` 참조(네이티브 설치 → `localhost:1234` 직결).



# Cf : lms 컨테이너 단독망내에서 시작 절차. 
