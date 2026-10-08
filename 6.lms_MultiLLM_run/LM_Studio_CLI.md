---
title: LM Studio CLI (lms) 명령어 정리
description: LM Studio 터미널 CLI 도구 lms의 주요 커맨드 및 사용법 정리
tags:
  - LLM
  - LMStudio
  - CLI
  - lms
  - LocalLLM
  - DevTools

date: 2026-04-17
---

# 개요

* LM Studio에 번들된 터미널 CLI 도구 `lms` 레퍼런스
* 상위 문서: [[LM_Studio]] — 앱 전반 소개/양자화/시스템 요구사항
* 시나리오: [[LM_Studio_Ubuntu_Headless]] — GUI 없는 서버 환경 설치/운영

# 설치 및 초기화

LM Studio 0.2.22 이상 버전에 `lms`가 내장됨. 최초 사용 전 LM Studio를 한 번 이상 실행해야 함.

```bash
# Mac / Linux - PATH 등록
~/.lmstudio/bin/lms bootstrap

# 문제 시 대안
npx lmstudio install-cli
```

# 커맨드 그룹 전체 구조

현재 `lms` v0.0.47 기준 커맨드 구성:

| 그룹                  | 커맨드    | 설명                             |
| :-------------------- | :-------- | :------------------------------- |
| **Local models**      | `chat`    | 터미널에서 인터랙티브 채팅       |
|                       | `get`     | HuggingFace에서 모델 검색/다운로드 |
|                       | `load`    | 메모리에 모델 로드               |
|                       | `unload`  | 모델 언로드                      |
|                       | `ls`      | 디스크의 모델 목록               |
|                       | `ps`      | 현재 메모리에 로드된 모델 목록   |
|                       | `import`  | 외부 모델 파일 임포트            |
| **Serve**             | `server`  | 로컬 서버 관리                   |
|                       | `log`     | 메시지 로깅                      |
| **Runtime**           | `runtime` | 추론 런타임 관리/업데이트        |
| **Develop & Publish** | `clone`   | Hub에서 아티팩트 클론            |
|                       | `push`    | Hub에 업로드                     |
|                       | `dev`     | 플러그인 개발 서버 시작          |
|                       | `login`   | Hub 인증                         |

# 자주 쓰는 핵심 명령어

```bash
# 상태 확인
lms status

# 서버 제어
lms server start
lms server stop

# 모델 목록 (디스크)
lms ls
lms ls --json          # JSON 출력

# 로드된 모델 목록
lms ps
lms ps --json

# 모델 로드
lms load                           # 인터랙티브 선택
lms load openai/gpt-oss-20b --identifier="my-model-name"
lms load --gpu=max --context-length=8192

# 모델 언로드
lms unload
lms unload --all

# 터미널 채팅
lms chat
```

# 기동 절차 (daemon → load → serve)

원격/헤드리스 환경에서 외부 접속 가능한 상태까지 올리는 최소 3단계:

```bash
lms daemon up                              # 1. LM Studio 백그라운드 데몬 기동
lms server start --bind 0.0.0.0            # 3. 서버 기동 (모든 인터페이스 바인딩)
lms unload 
lms load google/gemma-4-31b-qat --context-length  32768           # 2. 모델을 메모리에 로드
```

| 단계  | 명령                                | 역할                                          |
| :-: | :-------------------------------- | :------------------------------------------ |
|  1  | `lms daemon up`                   | GUI 없이 LM Studio 백엔드 데몬 기동. 이후 CLI 명령 수신 가능 |
|  2  | `lms load <model-key>`            | 모델을 GPU/RAM에 적재. 미로드 상태에서 API 호출 시 실패       |
|  3  | `lms server start --bind 0.0.0.0` | OpenAI 호환 `/v1` 서버 기동. 기본 포트 `1234`         |

* `--bind 0.0.0.0`: 기본값(`127.0.0.1`)은 로컬 전용 → LAN 내 타 머신 접속 허용 시 필요함
* ⚠️ `0.0.0.0` 바인딩은 인증 없는 LLM 엔드포인트를 네트워크에 노출함. 신뢰 네트워크에서만 사용하고, 라우터 포트포워딩으로 WAN 에 열지 말 것. 인증 필요 시 아래 `LM_API_TOKEN` 절 참조
* 검증: `lms ps` (로드 확인) → `curl http://<host>:1234/v1/models` (서버 응답 확인)

# CUDA(NVIDIA) 환경 GPU 오프로드 설정

리눅스 + NVIDIA GPU 환경에서 VRAM 적재량을 제어하는 옵션.

```bash
lms load <model_key> --gpu max                        # 전 레이어를 GPU(VRAM)로
lms load <model_key> --gpu 0.8                        # 80%만 GPU (VRAM 빠듯할 때)
lms load <model_key> --gpu max --context-length 8192  # 오프로드 + 컨텍스트 동시 지정
lms server start --port 1234                          # 포트 지정 기동
```

## 옵션

| 옵션                       | 값                | 의미                                                       |
| :------------------------- | :---------------- | :--------------------------------------------------------- |
| `--gpu max`                | 전량              | 모든 레이어를 VRAM 에 올림. 최고 속도, VRAM 충분할 때        |
| `--gpu <0.0~1.0>`          | 비율              | 지정 비율만 GPU, 나머지는 CPU/RAM 오프로드 (하이브리드)      |
| `--gpu 0`                  | 없음              | CPU 전용 추론                                               |
| `--context-length <n>`     | 토큰 수           | 컨텍스트 윈도우. 클수록 KV 캐시가 VRAM 을 추가로 먹음        |
| `--port <n>`               | 포트              | 서버 포트 (기본 `1234`)                                     |

* `--gpu max` / `--gpu=max` 둘 다 통함 (등호 유무 무관)
* VRAM 부족 시 로드 실패 또는 극단적 속도 저하 → `--gpu 0.8` → `0.6` 순으로 낮춰가며 조정
* **컨텍스트가 VRAM 을 먹는다**: 모델 가중치가 들어가도 `--context-length` 를 키우면 KV 캐시 때문에 OOM 날 수 있음. 둘을 함께 튜닝할 것

## 검증

```bash
lms ps            # 로드된 모델 / 오프로드 상태 확인
nvidia-smi        # VRAM 점유로 실제 GPU 사용 여부 확인
```

* `lms ps` 는 LM Studio 가 보고하는 값 → `nvidia-smi` 로 실제 VRAM 점유를 교차 확인해야 오프로드가 정말 GPU 로 갔는지 확실함
* `nvidia-smi` 상 점유가 거의 0 이면 CPU 폴백 상태 — CUDA 런타임 확인 필요 (`lms runtime` 그룹)
* 실시간 감시: `nvidia-smi -l 1` (1초 간격) 또는 `watch -n 1 nvidia-smi`

# 추론 런타임(엔진) 확인 및 변경

`lms runtime` 그룹으로 설치된 추론 엔진(llama.cpp/MLX 등) 목록 확인·선택 가능. GPU 오프로드 안 먹거나 CPU 폴백 의심 시 우선 점검 대상.

```bash
lms runtime ls              # 설치된 엔진 목록 (SELECTED 열에 ✓)
lms runtime select <alias>  # 엔진 전환 (alias는 ls 출력의 LLM ENGINE 값)
lms runtime select --latest # 해당 계열 최신 버전으로 선택
lms runtime remove          # 설치된 런타임 확장팩 제거
lms runtime update          # 런타임 확장 업데이트
lms runtime get             # 런타임 확장 다운로드/목록
lms runtime survey          # 선택된 엔진 기준 하드웨어 서베이
```

## 출력 예시 (플랫폼별 엔진 다름)

**Linux + NVIDIA CUDA (fg1)**:

```
LLM ENGINE                                        SELECTED    MODEL FORMAT
llama.cpp-linux-x86_64-avx2@2.24.0                                GGUF
llama.cpp-linux-x86_64-nvidia-cuda-avx2@2.24.0       ✓            GGUF
llama.cpp-linux-x86_64-vulkan-avx2@2.24.0                         GGUF
```

**macOS Apple Silicon (jm4)**:

```
LLM ENGINE                                         SELECTED    MODEL FORMAT
llama.cpp-mac-arm64-apple-metal-advsimd@2.25.2        ✓            GGUF
mlx-llm-mac-arm64-apple-metal-advsimd@1.10.1          ✓            MLX
```

* 같은 `MODEL FORMAT`(GGUF/MLX) 내에서만 SELECTED 배타적으로 보임 — GGUF용 1개 + MLX용 1개처럼 포맷별 각각 선택 가능
* CUDA 환경은 `nvidia-cuda` 접미 엔진이 `✓`인지 확인. `avx2`(CPU) 만 선택돼 있으면 GPU 오프로드 안 됨 → `lms runtime select llama.cpp-linux-x86_64-nvidia-cuda-avx2@<version>` 로 전환

## 엔진 변경 절차

```bash
lms runtime ls                                          # 1. alias 확인
lms runtime select llama.cpp-linux-x86_64-nvidia-cuda-avx2@2.24.0  # 2. 전환
lms runtime ls                                           # 3. SELECTED ✓ 이동 확인
lms unload --all && lms load <model_key> --gpu max       # 4. 재로드 (전환 전 로드분은 구 엔진 유지)
```

* 버전 미지정 시 `select --latest` 로 같은 계열 최신판 선택 가능
* 엔진 전환은 **이후 로드되는 모델**부터 적용됨 — 이미 메모리에 로드된 모델은 재로드해야 새 엔진으로 동작

# 모델 제거

`lms` CLI에 모델 삭제 명령 없음 (chat/get/load/unload/ls/ps/import 뿐 — CLI commit 4ecb9cd 기준 확인). 디스크에서 제거하려면 두 가지 방법 사용.

```bash
# 1. 파일 직접 삭제
lms ls                                        # 모델 키 확인 (publisher/repo 형태)
rm -rf ~/.lmstudio/models/<publisher>/<repo>  # 해당 모델 폴더 삭제
```

* 2. GUI: LM Studio 앱 → My Models(📁) → 모델 우클릭 → Delete
* 주의: `lms unload`는 메모리에서만 내림 — 디스크 파일은 남음
* 삭제 후 앱 모델 목록은 자동 갱신됨

# 로그 스트리밍 (v0.3.26+)

v0.3.26부터 `lms log stream`에 신규 옵션 추가됨:

```bash
lms log stream --source server          # HTTP API 서버 로그
lms log stream --source model --filter output    # 모델 출력만
lms log stream --source model --filter input,output  # 입출력 모두
lms log stream --json                   # JSON 형식 출력
lms log stream --stats                  # tok/sec 등 통계
```

* `lms log stream --source server` 동작 확인함 (2026-07-16). 서버 상태 명령(`lms status`/`lms server status`)은 클라이언트 접속 목록을 보여주지 않으므로, 실제 요청 활동 확인은 본 명령으로 대체함

# 인증이 필요한 환경

`LM_API_TOKEN` 환경변수를 설정하면 CLI가 자동으로 Bearer 토큰으로 사용함:

```bash
export LM_API_TOKEN="your-token"
lms server start
```
# References
* [LM_Studio](LM_Studio.md)
* [LM_Studio_Ubuntu_Headless](LM_Studio_Ubuntu_Headless.md)
* 