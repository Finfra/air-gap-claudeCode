---
name: README
description: 7.lms_MultiLLM_run_v2 — 6.lms_MultiLLM_run 의 CUDA 정상화 재시도본. step4·step5 만 진행
date: 2026-07-23
---

# 개요

[6.lms_MultiLLM_run](../6.lms_MultiLLM_run/README.md) 의 **재시도본(v2)**. 6 의 단계적 검증에서
step1~4 게이트는 통과했으나, **GPU 활성화 시 CUDA 런타임 불일치**로 실제 반입 기동이 실패했다.
그 원인을 호스트 레벨에서 해결(**prj55#Issue9** — CUDA 11 런타임 설치)한 뒤 다시 세우는 판본이다.

* **소스는 6 과 거의 동일** — 단계 구조·스크립트·판정 기준을 그대로 계승한다.
* **step4·step5 만 진행** — step1~3(진단 단계)은 6 에서 이미 통과했으므로 재수행하지 않는다.
* **유일한 소스 차이**: `entrypoint.lms.sh` 3.5 단계에 **CUDA 런타임 프리플라이트(fail-loud)** 추가
  (아래 "6 대비 변경점" 참조).

# ✅ CUDA 정상화 — 이미지 측 해결(cuda11fix)로 우회됨

> 당초 전제였던 **prj55#Issue9(호스트 CUDA 11 런타임 설치)** 는 **이미지 측 해결로 우회**되었다.
> 근본 원인은 CUDA 11 런타임의 *부재*가 아니라 *경로 미노출*이었다 — 필요한 `libcudart.so.11.0`
> 은 이미 LM Studio 번들로 이미지 안에 있었고, `ldconfig` 검색 경로에 미등록이었을 뿐이다.
> 상세·하드 증거: [cuda11fix/README.md](cuda11fix/README.md).

* **해결본 이미지**: `lms:small-cuda11fix` — 베이스(`lms:small`)에 vendor 디렉토리를
  `ld.so.conf.d` 등록 + `ldconfig` 하는 얇은 레이어를 얹어 `libcudart.so.11.0` 을 노출한다.
  **호스트에 CUDA 11 을 설치할 필요가 없다**(컨테이너는 호스트 ldconfig 를 상속하지 않음).
* **반입본 = `lms:31b-cuda11fix`** (2026-07-30) — 위 해결본에서 E2B 를 뺀 **31B 전용 슬림본**
  (29.1GB → 22.2GB, DVD 7장 → 5장). 빌드: [cuda11fix/build_slim31b.sh](cuda11fix/build_slim31b.sh).
  내장 LLM 은 `google/gemma-4-31b-qat` 하나. 반입 절차·매체 구성: [_img/README.md](_img/README.md).
* **fg1 실증(2026-07-23)**: `lms:small-cuda11fix` 로 CUDA 프리플라이트 통과 · 엔진 로드 ·
  VRAM +2286MiB 점유 · chat completion `CUDA_OK`.
* **fg1 실증(2026-07-30, 슬림본)**: `lms:31b-cuda11fix` 로 프리플라이트 통과 ·
  `llama.cpp-linux-x86_64-nvidia-cuda-avx2@2.23.1` 선택 · 31B 부분 offload(`LMS_GPU=0.6`)
  **VRAM 13,438MiB 실점유** · chat completion `CUDA_OK`. (16GB GPU 라 부분 offload —
  A6000 반입 서버는 `LMS_GPU=max` 전량 offload)
* v2 의 `entrypoint.lms.sh` 는 `LMS_REQUIRE_CUDA=1`(기본)에서 `libcudart.so.11.0` 을 해석하지
  못하면 CPU 로 조용히 넘어가지 않고 **명시적으로 중단**한다 — 6 의 조용한 실패(엔진 로드 죽음)를
  재발시키지 않기 위함. cuda11fix 이미지는 이 프리플라이트를 통과한다.

전이 조건(달성): **cuda11fix 검증 완료** → 이 이미지를 `_img/` 로 반입해 step4·step5 진행.

# 6.lms_MultiLLM_run 반입 실패의 주 원인 (CUDA 불일치)

GPU 를 켜면 아래 에러로 LM Studio 추론 엔진 로드가 실패했다:

```
Error: Failed to load LLM engine from path :
  /home/lms/.lmstudio/extensions/backends/llama.cpp-Linux-x86_64-nvidia-cuda-avx2-2.23.1/llm_cuda.node.
  'libcudart.so.11.0': cannot open shared object file: no such file or directory.
```

| 항목 | 내용 |
| :--- | :--- |
| 증상 | GPU 활성화 시 `llm_cuda.node` 로드 실패 → 추론 엔진 자체가 안 뜸 |
| 직접 원인 | CUDA 백엔드(`llama.cpp-...-nvidia-cuda-avx2-2.23.1`)가 **CUDA 11 런타임**(`libcudart.so.11.0`)을 요구 |
| 근본 원인 | CUDA 11 런타임의 **부재가 아니라 경로 미노출** — `libcudart.so.11.0` 은 LM Studio 번들로 이미지 안에 있으나 vendor 디렉토리가 `ldconfig` 검색 경로에 미등록 |
| 6 의 한계 | `entrypoint.lms.sh` 3.5 가 CUDA 미해결 시 **경고 후 CPU 폴백** → 대형 모델 극도로 느려 504, 또는 위처럼 엔진 로드 자체 실패 |
| 해결 | **이미지 측 [cuda11fix](cuda11fix/README.md)** — vendor 디렉토리를 `ld.so.conf.d` 등록 + `ldconfig`. 호스트 CUDA 설치 불필요. (당초 위임처 prj55#Issue9 는 이 이미지 측 해결로 우회) |

> 상세 실패 맥락은 [6.lms_MultiLLM_run/README.md](../6.lms_MultiLLM_run/README.md) "반입 실패의 주 원인" 절에도 기록.

# 6 대비 변경점 (소스 차이)

| 파일 | 변경점 |
| :--- | :----- |
| `step4.cc_gw_lms2/entrypoint.lms.sh` | 3.5 단계에 **CUDA 프리플라이트** 추가 — CUDA 엔진 선택 전 `libcudart.so.11.0` 해석 가능 여부를 `ldconfig`/`ldd` 로 검사. 미해결이면 `LMS_REQUIRE_CUDA=1` 기본에서 **중단**(CPU 폴백 금지), 메시지에 prj55#Issue9 를 가리킴 |
| `step4.cc_gw_lms2/.env.org` | `LMS_REQUIRE_CUDA=1` 신규. CPU 강행이 필요하면 0 |
| `step5.win_gw_lms2/*` | 6 과 동일 (서버 스택은 step4 를 그대로 씀) |

그 외 `run.sh`·`entrypoint.cc.sh`·`nginx.conf.template`·`serve-lan.sh`·`settings.json.sample`·판정
게이트는 6 과 동일하다.

# air-gap 반입 (_img/ export → load)

step4·step5 가 쓰는 **이미지 3종을 `_img/` 로 반입**한다. step5 의 Windows 클라이언트가
붙는 서버 스택(gateway·lms-1·lms-2)은 step4 의 것을 그대로 쓰므로, 반입 이미지 = step4 가
기동하는 이미지 = `_img/` 에서 `docker load` 한 것으로 일치시킨다(6 은 `bringin/_img/` 였고,
7 은 이 폴더 직속 `_img/`).

| 이미지 | 태그 | 유래 |
| :--- | :--- | :--- |
| lms | `lms:31b-cuda11fix` | `lms:small-cuda11fix`([cuda11fix](cuda11fix/README.md) 오버레이)에서 E2B 제거한 31B 전용 슬림본. 모델 `google/gemma-4-31b-qat` 내장 (~22GB) |
| gateway | `lms-gateway:latest` | `5.lms_MultiLLM/Dockerfile.gateway` (step4 통과본) |
| claude | `claude:latest` | `6.lms_MultiLLM_run/_dockerfile/finfra/claude` (step4 통과본) |

```bash
# [온라인 호스트] 이미지 → _img/ (태그는 step4/.env → .env.org 에서 읽음)
./export.sh --list          # 대상·크기 확인 (save 안 함)
./export.sh                 # 기본 = DVD±R SL 분할 (MEDIA_BYTES=4.6GB → *.tar.partNN)
MEDIA_BYTES=0 ./export.sh   # 분할 안 함 (외장 디스크 등 단일 대용량 매체)

# [단독망 호스트] _img/ 검증 + docker load
./load.sh --verify          # SHA256 검증만
./load.sh                   # 검증 → (분할본 재조립) → docker load → 태그 확인
```

> **DVD 굽기 배치·단독망 연결까지의 전체 매뉴얼은 [_img/README.md](_img/README.md)** 에 있다.
> (디스크별 수록 파일, 재조립, `nvidia-container-toolkit` 전제, CUDA 판정, 클라이언트 접속)

> `export.sh`/`load.sh` 는 step4 의 `.env`(없으면 `.env.org`)에서 이미지 태그를 읽어
> `run.sh` 가 `docker image inspect` 하는 태그와 자동 일치시킨다. 어긋날 여지가 없다.
> 매체 초과 시 `_img/*.tar.partNN` 분할·`SHA256SUMS` 무결성 검증은 6 의 반입 패턴을 계승한다.

# 단계 인덱스 (step4·step5 만)

| 단계 | 경로 | 경로도 | 검증 변수 |
| :--- | :--- | :----- | :-------- |
| 4 | [step4.cc_gw_lms2/README.md](step4.cc_gw_lms2/README.md) | docker cc → gateway → **lms-1, lms-2** | **CUDA 런타임 정상 로드(v2 핵심)** + consistent hash 세션 고정 + GPU 분할 |
| 5 | [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) | **windows cc** → gateway → lms-1, lms-2 | 호스트 포트 publish·LAN·Windows 설정 파일 |

# 진행 절차 (단독망)

```bash
# 0) 반입 — _img/ 에서 3종 이미지 load (단독망)
./load.sh                             # SHA256 검증 → docker load → 태그 확인

# 0-1) 전제 — 컨테이너 안에서 CUDA 11 런타임 해석 확인 (cuda11fix 이미지면 통과)
docker run --rm --entrypoint bash lms:31b-cuda11fix -lc 'ldconfig -p | grep libcudart.so.11'
#    → libcudart.so.11.0 이 보여야 함

# 4) step4 — CUDA 정상 로드 + 다중 백엔드 분산
cd step4.cc_gw_lms2
cp .env.org .env && vi .env           # LMS_REQUIRE_CUDA=1 유지, LMS_GPU/백엔드 검토
./run.sh
./run.sh --check --distribute --affinity --spread --sse --resilience

# 5) step5 — Windows 클라이언트 (서버 스택은 step4 그대로)
cd ../step5.win_gw_lms2
./serve-lan.sh --check
# 이후 Windows 매뉴얼(step5 README) 수행
```

성공 판정 게이트는 각 step README 의 것을 그대로 따르되, **step4 게이트 1 에
"CUDA 엔진 로드 성공 + VRAM 실제 점유(nvidia-smi)"를 추가**로 요구한다 — 이것이 v2 의 존재 이유다.

# 폴더 구조

```
7.lms_MultiLLM_run_v2/
├── README.md                  # 이 파일
├── export.sh                  # [온라인] 이미지 3종 → _img/ (docker save + SHA256SUMS)
├── load.sh                    # [단독망] _img/ 검증 + docker load
├── _img/                      # 반입 산출물(*.tar.partNN·SHA256SUMS·MANIFEST) — git 미추적(*.tar*)
│   └── README.md              #   DVD 굽기 배치 + 단독망 반입·기동·클라이언트 접속 매뉴얼
├── cuda11fix/                 # lms 이미지 CUDA 11 런타임 노출 오버레이 (근본 원인·빌드)
│   ├── build_cuda11fix.sh     #   lms:small        → lms:small-cuda11fix (CUDA 정상화)
│   └── build_slim31b.sh       #   lms:small-cuda11fix → lms:31b-cuda11fix (31B 전용 슬림)
├── step4.cc_gw_lms2/          # 4. docker cc → gateway → lms-1, lms-2 (+ CUDA 프리플라이트)
└── step5.win_gw_lms2/         # 5. windows cc → gateway → lms-1, lms-2 (서버 스택은 step4 것)
```
