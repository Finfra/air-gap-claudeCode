---
name: README
description: 6.lms_MultiLLM_run — docker run 기반 폐쇄망 반입본. 단계적(step1~5) 검증 체계 인덱스
date: 2026-07-20
---

# 개요

`docker compose` 없이 **순수 `docker run`** 으로 LMS 백엔드 + nginx 게이트웨이 + Claude Code 클라이언트를 기동하는 폐쇄망(air-gap) 반입 폴더.

**2026-07 반입은 실패했음.** 실패 3대 증상:

| 증상                                | 계층                     |
| :---------------------------------- | :----------------------- |
| Windows 접속 스크립트(`.ps1`) 오동작 | 클라이언트(Windows)      |
| 반입 컨테이너의 시작 `run` 명령 미동작 | 기동 스크립트(`start.sh`) |
| 게이트웨이 경유 접근 실패            | nginx 게이트웨이         |

원인이 세 계층에 동시에 걸려 있어 **한 번에 전체 스택을 세우는 방식(`start.sh` 단일 실행)으로는 어디가 깨졌는지 분리 불가**. 따라서 이번 사이클은 **변수를 하나씩만 추가하는 단계적 검증**으로 재구성함. 이전 반입본 전체는 [cf_old/](cf_old/) 에 보존(참조용, 실행 금지).

설계 SSOT: [_doc_arch/airgap-staged-test-design.md](../_doc_arch/airgap-staged-test-design.md)

# 반입 실패의 주 원인 (CUDA 불일치) — v2 로 이관

> **후속 진행은 [7.lms_MultiLLM_run_v2](../7.lms_MultiLLM_run_v2/README.md) 에서 한다.**
> step1~4 게이트는 여기서 통과했으나, **GPU 를 켜면 CUDA 런타임 불일치로 실제 기동이 실패**했다.
> 그 원인을 호스트 레벨에서 해결(**prj55#Issue9** — CUDA 11 런타임 설치)한 뒤 v2 에서 step4·step5 만 재수행한다.

GPU 활성화 시 LM Studio 추론 엔진 로드가 아래 에러로 실패했다:

```
Error: Failed to load LLM engine from path :
  /home/lms/.lmstudio/extensions/backends/llama.cpp-Linux-x86_64-nvidia-cuda-avx2-2.23.1/llm_cuda.node.
  'libcudart.so.11.0': cannot open shared object file: no such file or directory.
```

| 항목 | 내용 |
| :--- | :--- |
| 증상 | GPU 활성화 시 `llm_cuda.node` 로드 실패 → 추론 엔진 자체가 안 뜸 |
| 직접 원인 | CUDA 백엔드(`llama.cpp-...-nvidia-cuda-avx2-2.23.1`)가 **CUDA 11 런타임**(`libcudart.so.11.0`)을 요구 |
| 근본 원인 | 호스트/컨테이너에 CUDA 11 런타임 부재 (대개 CUDA 12 만 설치 → `libcudart.so.12` 만 존재) |
| 이 폴더의 한계 | `entrypoint.lms.sh` 3.5 가 CUDA 미해결 시 **경고 후 CPU 폴백** → 대형 모델 극도로 느려 504, 또는 위처럼 엔진 로드 자체 실패. 조용한 실패라 게이트로 안 잡힘 |
| 해결 위임 | **prj55#Issue9** — CUDA 11 런타임(`libcudart.so.11.0`) 설치. 완료 후 v2 진행 |
| v2 의 대응 | `entrypoint.lms.sh` 에 CUDA 프리플라이트(fail-loud) 추가 — `libcudart.so.11.0` 미해결 시 CPU 폴백 없이 중단. 상세: [v2 README](../7.lms_MultiLLM_run_v2/README.md) |

# 단계 인덱스

각 단계는 **직전 단계 성공(게이트 통과)이 전제**. 실패하면 다음 단계로 넘어가지 않음.

| 단계 | 경로 | 경로도 | 이 단계에서 추가로 검증되는 변수 |
| :--- | :--- | :----- | :------------------------------- |
| 1 | [step1.cc_to_lms/README.md](step1.cc_to_lms/README.md) | docker cc → **호스트 LMS** | cc 이미지·`ANTHROPIC_BASE_URL` OpenAI 직결·`host.docker.internal` 도달성 |
| 2 | [step2.cc_to_lmsDocker/README.md](step2.cc_to_lmsDocker/README.md) | docker cc → **docker lms** | lms 이미지·`entrypoint.lms.sh`·모델 로드·컨테이너 간 DNS |
| 3 | [step3.cc_gw_lms/README.md](step3.cc_gw_lms/README.md) | docker cc → **docker gateway** → docker lms | nginx upstream·SSE 스트리밍·타임아웃 |
| 4 | [step4.cc_gw_lms2/README.md](step4.cc_gw_lms2/README.md) | docker cc → gateway → **lms-1, lms-2** | consistent hash 세션 고정·GPU 분할·VRAM 한계 |
| 5 | [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) | **windows cc** → gateway → lms-1, lms-2 | 호스트 포트 publish·LAN 방화벽·Windows 설정 파일 |

# 대체 경로 — lms 실패 시 (fallback)

정규 경로(lms 백엔드)가 폐쇄망에서 동작하지 않을 때, 게이트웨이는 그대로 두고 **백엔드만
이미 떠 있는 `ollamawebui`(11434) 로 갈아끼우는** 대체 경로. lms/ollama 모두 OpenAI `/v1` 을
서빙하므로 게이트웨이 upstream 만 바꾸면 드롭인 교체가 성립함. cc 컨테이너 불필요.

| 경로 | 경로도 | 문서 |
| :--- | :----- | :--- |
| fallback | windows 클라이언트 → gateway → **ollamawebui:11434** | [fallback.gw_ollama/README.md](fallback.gw_ollama/README.md) |

# 반입 범위

폐쇄망으로 **반입하는 것**:

* **폴더**: 이 폴더(`6.lms_MultiLLM_run`) 전체 — step1~5 + 매뉴얼 + `bringin/`
* **이미지 (tar)**: [bringin/](bringin/README.md) 의 `export.sh` 가 step4/.env 기준으로 떠 준다.
    - `lms:small`(~29GB, **모델 gemma-4-e2b 내장**) — step4 백엔드 이미지 (`LMS_IMAGE`)
    - `lms-gateway:latest`(~213MB), `claude:latest`(~684MB) — step4 통과본
    - A6000·31b 반입이면 `LMS_IMAGE=lms:latest`(24.7GB, 31b 내장)로 바꿔 내보냄

각 `run.sh` 는 이미지가 **이미 `docker load` 돼 있다고 전제**한다(없으면 중단). 따라서 온라인에서
tar 로 떠서 매체로 옮겨 적재하는 절차가 별도로 필요하다 → **[bringin/README.md](bringin/README.md)**
(`export.sh`/`load.sh` + SHA256 무결성 + DVD 초과 시 분할). step1·step2 는 이미지 반입 대상이 아니라
**결함 위치를 좁히기 위한 진단 단계**.

> ⚠️ **DVD 크기 주의**: `lms:small` 단독 ~29GB 로 **DVD 1장(4.7GB)을 초과**한다. BD-R DL(50GB)
> 1장·외장 디스크·DVD 다장(자동 분할) 중 선택 — 상세·명령은 [bringin/README.md](bringin/README.md).

# Windows 클라이언트 정책 (변경)

* **`.ps1` 스크립트 폐기.** 이전 반입에서 PowerShell 실행 정책·인코딩(BOM)·JSON 병합 로직이 폐쇄망 Windows 에서 오동작하여 실패 원인 1순위였음.
* 대체: **설정 파일 + 사람이 읽고 따라 하는 매뉴얼**. Windows 쪽에서 실행되는 자동화 스크립트는 두지 않음. 상세는 [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md).

# 폴더 구조

```
6.lms_MultiLLM_run/
├── README.md                  # 이 파일 (단계 인덱스)
├── step1.cc_to_lms/           # 1. docker cc → 호스트 LMS
├── step2.cc_to_lmsDocker/     # 2. docker cc → docker lms
├── step3.cc_gw_lms/           # 3. + 게이트웨이
├── step4.cc_gw_lms2/          # 4. + 백엔드 2개
├── step5.win_gw_lms2/         # 5. + Windows 클라이언트 (파일 + 매뉴얼)
├── bringin/                   # 반입 아티팩트: export.sh(이미지→tar) / load.sh(단독망 적재)
├── fallback.gw_ollama/        # 대체. gateway → ollamawebui:11434 (lms 실패 시)
├── __img/                     # 문서용 스크린샷
└── cf_old/                    # 실패한 이전 반입본 (참조 전용, 실행 금지)
```
