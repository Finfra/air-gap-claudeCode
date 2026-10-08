---
name: info_modelTuning
description: step5 기초 참고 — 서버측 LMS 로드 파라미터(VRAM·속도·컨텍스트) 튜닝. step4 .env 노브가 SSOT, Windows 는 손댈 것 없음
date: 2026-07-21
---

# 이 문서의 위치 (step5 관점)

로컬 LLM 백엔드에서 Claude Code 를 실사용 가능하게 만드는 축은 **두 개**다.

| 축 | 무엇 | 문서 | 조절 위치 |
| :--- | :--- | :--- | :--- |
| **요청 축소 (다이어트)** | claude 가 보내는 프롬프트(도구 스키마)를 줄임 — 20k→3k | [info_promptDiet.md](info_promptDiet.md) | 클라이언트 `settings.json` / 서버 entrypoint |
| **서버 튜닝 (이 문서)** | LMS 로드 파라미터로 VRAM·속도·컨텍스트를 맞춤 | 여기 | 서버 [step4.cc_gw_lms2/.env](step4.cc_gw_lms2/.env) |

둘은 독립이고 곱해진다. 다이어트로 **왕복당 prefill** 을 줄이고, 튜닝으로 **처리 속도·최대 길이**를 정한다.

> **step5 는 서버 스택을 손대지 않는다.** 이 문서의 튜닝은 전부 **서버(step4 `.env`)** 에서 끝난다.
> Windows 쪽에서 설정할 튜닝 노브는 없다 — Windows 는 `ANTHROPIC_BASE_URL` 로 게이트웨이만 가리킨다.
> 서버가 느리면 여기를, 클라이언트 연결이 안 되면 [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) 를 본다.
>
> 실측 출처: fg1 (NVIDIA 16GB) + LM Studio + Claude Code.

# 1. 튜닝 노브 (이 스택의 위치)

이 스택은 [step4.cc_gw_lms2/entrypoint.lms.sh](step4.cc_gw_lms2/entrypoint.lms.sh) 가 `lms load`
로 모델을 올린다. 노브는 전부 **[step4.cc_gw_lms2/.env](step4.cc_gw_lms2/.env)** 에 있다.

| `.env` 변수 | 역할 | 주의 |
| :--- | :--- | :--- |
| `LMS_MODEL` | 로드할 모델 키 | 16GB 검증 `gemma-4-e2b-it` / A6000 반입 `gemma-4-31b-it-qat`. **로컬 키**를 쓸 것(허브 키 아님) |
| `LMS_CONTEXT_LENGTH` | 컨텍스트 토큰 상한 | Claude Code 는 시스템+도구가 커서 **32768 이상** 필요(기본 8192 부족) |
| `LMS_GPU` | GPU offload 비율 (`max`/`off`/`0~1`) | VRAM<모델 환경에서 `max` 는 **CUDA OOM** — §2 |
| `LMS_PARALLEL` | 동시 예측 슬롯 | llmster 는 ctx 를 슬롯 수로 **분할**(4면 32k→8k). **반드시 1** (아니면 500) |
| `CLAUDE_MAX_OUTPUT_TOKENS` | 출력 상한 | 32k ctx 에 input+output 합산이 들어가야 함 |
| `LMS_BACKEND_COUNT` | 백엔드 컨테이너 수 | step4 의 핵심 변수(기본 2 = lms-1·lms-2) |

`lms load` 에는 **KV 양자화 플래그가 없다**(§3-B). 위가 이 스택에서 조절 가능한 전부다.

## CUDA 런타임 자동선택 함정 (이미 반영됨)

llmster 는 CUDA 백엔드를 설치해도 기본 SELECTED 가 **CPU(avx2)** 인 경우가 있다. 그러면
`LMS_GPU=max` 여도 CPU 로 추론해 대형 모델이 극도로 느려지고 504 가 난다.
[step4.cc_gw_lms2/entrypoint.lms.sh](step4.cc_gw_lms2/entrypoint.lms.sh) §3.5(약 101행)이 부팅 시
`lms runtime select <nvidia-cuda>` 로 자동 교정한다 — GPU 인데 느리면 [info_jinja_and_lms.md](info_jinja_and_lms.md) §3 부터 의심.

# 2. VRAM 예산 — offload 안전선

**병목은 RAM 이 아니라 VRAM 안에서 가중치·KV·prefill 연산 버퍼를 어떻게 나누냐다.**

핵심 함정: **KV 캐시는 로드 시 선할당되지만, prefill 연산 버퍼(batch)는 추론 시점에 추가로 필요**하다.
그래서 VRAM 을 꽉 채우면 **로드는 성공하고 짧은 요청도 통과하지만, 긴 프롬프트에서 CUDA OOM 크래시**한다.

fg1 16GB 실측 (gemma-4-26b, KV q8_0, 128k):

| `LMS_GPU` | 레이어 | VRAM | 짧은 프롬프트 | 긴 프롬프트(110k) |
| :--- | ---: | ---: | :--- | :--- |
| 0.75 | 23 | 97% | 25 tok/s (빠름) | ❌ CUDA OOM 크래시 |
| **0.6** | 19 | 83% | 20 tok/s | ✅ 통과 |

→ **짧은 프롬프트 속도만 보고 offload 를 올리지 말 것.** 128k 에이전트 용도의 안전선은 VRAM **~83%**.
`LMS_GPU=max` 를 쓰려면 VRAM 이 모델보다 확실히 커야 한다(그때만 안전).

> step4 의 `.env` 는 `LMS_ALLOW_GPU_OVERSUBSCRIBE` 로 백엔드 수 > GPU 수를 가드한다.
> ex) A6000(48GB) + 31b ×2 ≈ 44GB(92%) 는 83% 안전선 초과 → 승인 금지. (→ [step4.cc_gw_lms2/README.md](step4.cc_gw_lms2/README.md))

# 3. 128k 장문 — 두 경로

| 경로 | 방법 | 이 스택 |
| :--- | :--- | :--- |
| **A. 소형 모델** | KV 가 애초에 작음 | 개발 머신(16GB) 검증용 (`gemma-4-e2b-it`, 백엔드당 ~4.4GB) |
| **B. 대형 모델 + KV q8_0** | KV 를 절반으로 양자화 | ❌ `lms load` 불가 + **A6000 에선 불필요** (아래) |

> 반입 구성은 `gemma-4-31b-it-qat` 이다([step4.cc_gw_lms2/.env](step4.cc_gw_lms2/.env)).
> `e2b` 는 16GB 개발 머신 검증용(`lms:small`)일 뿐이다.

## gemma-4 는 MQA 도 일반 GQA 도 아니다 — 5:1 sliding-window

GGUF 메타데이터 실측(`gemma-4-26b-a4b` 기준):

```
block_count = 30 · head_count = 16
head_count_kv           = [8,8,8,8,8,2, 8,8,8,8,8,2, ...]   (5:1 반복)
sliding_window_pattern  = [T,T,T,T,T,F, ...]   sliding_window = 1024
key/value_length = 512 (full-attn) · 256 (SWA)
```

**30개 층 중 25개가 1024 토큰 sliding window 라 컨텍스트가 늘어도 KV 가 커지지 않는다.**
전체 컨텍스트를 쥐는 층은 5개뿐이고 그마저 KV 헤드가 2개다. 즉 이 아키텍처는 장문 KV 가
구조적으로 싸다. 계산 결과(26b 기준):

| 컨텍스트 | KV fp16 | KV q8_0 |
| ---: | ---: | ---: |
| 32,768 | 0.82 GiB | 0.44 GiB |
| 65,536 | 1.45 GiB | 0.77 GiB |
| 131,072 | **2.70 GiB** | 1.43 GiB |

**32k → 128k 증분이 fp16 기준 +1.9 GiB 에 불과하다.**

31b 는 층 수를 확인하지 못해 **3~9 GB 대역**으로만 말할 수 있다(같은 gemma4 계열이므로 5:1
가정). 그래도 A6000 48GB 예산은 `가중치 18.85 + KV 3~9 + 연산버퍼 3~5 = 25~33GB (52~69%)`
로 83% 안전선 안이다.

**따라서 경로 B(KV q8_0)는 A6000 에서 이식할 이유가 없다.** q8_0 은 fg1(16GB)에서 *부족한
VRAM 을 쥐어짜기 위한* 수단이었고 속도 이득은 없었다. 게다가 `lms load` 에 KV 양자화 플래그가
없어 Python SDK 를 경유해야 하는데, **SDK 경로는 `--parallel` 을 잃어 4로 고정**된다 — 32k 에서
슬롯당 8k 가 되어 Claude Code 가 500 을 맞는다(아래 표). **하지 말 것.**

## 컨텍스트 × parallel 안전 조합

| ctx | parallel | 슬롯당 | 결과 |
| ---: | ---: | ---: | :--- |
| 32,768 | 1 | 32k | ✅ **현재 구성** (step4 `.env` 기본) |
| 131,072 | 1 | 128k | ✅ (이 스택이 128k 로 갈 때의 모습) |
| 131,072 | 4 | 32k | ✅ 실측 통과 (SDK 경로) |
| 32,768 | 4 | 8k | ❌ 500 (`n_keep >= n_ctx`) |
| 8,192 | 4 | 2k | ❌ 400 — JIT 기본값. `entrypoint.lms.sh` 가 JIT 를 끄는 이유 |

`entrypoint.lms.sh` 는 `--parallel ${LMS_PARALLEL}` 을 넘기고 `.env` 가 `1` 이므로,
**이 스택에서 컨텍스트 상향은 `LMS_CONTEXT_LENGTH` 하나만 바꾸는 일**이다.

## 그런데 병목은 VRAM 이 아니라 prefill 지연이다

fg1 16GB 실측:

* 110,716 토큰 → **TTFT 241초**, 생성 2.29 tok/s
* 30,000 토큰 → TTFT 55초, 6.45 tok/s
* 에이전트 루프는 **도구 호출마다 늘어난 대화 전체를 재prefill** 하므로 왕복 수에 비례해 누적

A6000 전량 offload 면 크게 개선되겠지만 **31b 의 A6000 prefill 은 아무도 측정한 적이 없다.**
`API_TIMEOUT_MS=600000`(600초) 기준으로, 생성 20 tok/s 를 가정해도 출력 8192 토큰이 410초를
먹어 prefill 에 190초밖에 안 남는다. **128k 로 올리려면 `API_TIMEOUT_MS` 도 함께 올려야 한다**
(서버 `.env` 와 Windows `settings.json` 양쪽).

## 결론 — 반입 시점 권고

**32k 유지.** VRAM 은 128k 를 감당하지만, 미측정 변수는 지연이고 그쪽이 실사용을 좌우한다.
`CLAUDE_DIET=1` 이면 프롬프트가 ~3k 라 대부분의 트래픽은 32k 근처도 가지 않는다.

air-gap 운영자가 이 순서로 측정한 뒤 판단할 것:

1. `nvidia-smi -L` — GPU 장수 확인 (`LMS_BACKEND_COUNT` 결정)
2. 현재 32k 로 로드 후 **VRAM MiB 기록** → 위 3~9GB 대역이 실제 숫자로 확정됨
3. **~30k 토큰 프롬프트 종단 시간 측정** ← 128k 가부의 실제 판정 기준 (fg1 55초와 비교)
4. 3이 충분히 빠를 때만 65536 으로 한 단계 올리고 VRAM ≤83% 재확인
5. ⚠️ **반드시 장문으로 테스트할 것** — 짧은 프롬프트만 보고 판단한 것이 97% OOM 을 낳았다
6. 컨텍스트를 올리면 `API_TIMEOUT_MS` 도 함께 상향

# 4. 추론 모델은 `/no_think` (참고 — 보안망에선 미사용)

Qwen3 계열 같은 하이브리드 **추론 모델**은 기본값이 "생각"을 하여 사소한 질문에도 reasoning
토큰을 대량 소모한다(fg1 실측 Qwen3-8B: "1~5 출력 bash" 431 reasoning 토큰·27.5s →
`/no_think` 시 0 토큰·1.8s). **단, 보안망 정책상 중국계 추론 모델은 금지**이고 gemma 계열은
비추론 모델이라 해당 없음. 이 항목은 타 환경 참고용으로만 남긴다.

# 5. 소형 모델 하한선 (참고)

Claude Code 에이전트가 실제로 도는 관문은 "tool_use 표기"가 아니라 **에이전트 루프(도구
호출→관찰→다음 호출)를 견디느냐** 다. 실측상 **7~8B 가 에이전트 실질 하한선**이며 4B 이하는
멀티스텝에서 형식이 붕괴한다. 보안망에서는 gemma 계열 중 크기를 골라 이 하한을 지킬 것.

# 6. Windows 클라이언트 설정 (step5 — 수동 절차)

> ⚠️ **이전의 `vscode-connect.sh` / `vscode-connect.ps1` 자동 스크립트는 폐기됐다.**
> PowerShell 실행 정책·인코딩(BOM)·JSON 병합 로직이 폐쇄망 Windows 에서 오동작하여 실패
> 원인 1순위였다. step5 는 **설정 파일 원본 + 사람이 따라 하는 매뉴얼**로 대체한다.
> 폐기본은 [cf_old/vscode-connect.ps1](cf_old/vscode-connect.ps1) 에 보존(참조 전용, 실행 금지).

Claude Code(CLI·VSCode 확장 공통)는 **`%USERPROFILE%\.claude\settings.json`**
(= `C:\Users\<사용자>\.claude\settings.json`) 를 읽는다. step5 는 여기에 서버 게이트웨이 주소·모델을 넣는다.

## 튜닝과의 접점 — Windows 에 넣는 값은 4개뿐

이 문서의 서버 튜닝(ctx·GPU·parallel)은 **Windows 와 무관**하다. Windows `settings.json` 에서
튜닝과 연관된 값은 다음뿐이며, 모두 서버 `.env` 와 **숫자를 맞춰야** 한다:

| Windows `settings.json` 키 | 맞출 서버측 값 | 이유 |
| :--- | :--- | :--- |
| `model` | `.env` `LMS_MODEL` (의 `/v1/models` id) | 모델 키 불일치 시 요청 실패 |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `.env` `CLAUDE_MAX_OUTPUT_TOKENS`(8192) | ctx 안에 input+output 합산 |
| `API_TIMEOUT_MS` | `.env` `API_TIMEOUT_MS`(600000) | 로컬 추론 느림 → 10분. ctx 올리면 함께 상향 |
| `permissions.deny` | 서버 다이어트와 동일 목록 | 프롬프트 축소 (→ [info_promptDiet.md](info_promptDiet.md)) |

원본·치환 절차는 [step5.win_gw_lms2/settings.json.sample](step5.win_gw_lms2/settings.json.sample)
과 [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) 가 SSOT. 서버측 LAN 공개·설정값
출력은 [step5.win_gw_lms2/serve-lan.sh](step5.win_gw_lms2/serve-lan.sh) 가 담당한다.

## Windows 함정 (튜닝 관점)

* **응답이 매우 느림** — 서버 튜닝 문제일 수 있다. 세션마다 다른 백엔드로 흩어져 재prefill
  중이면 [step4.cc_gw_lms2/README.md](step4.cc_gw_lms2/README.md) 의 affinity(`run.sh --affinity`)를 재확인.
  GPU offload 미동작이면 [info_jinja_and_lms.md](info_jinja_and_lms.md) §3.
* **모델 미로드 시 JIT 400** — 서버가 모델을 안 올린 상태로 요청받으면 LM Studio 가 기본
  `ctx 8192/parallel 4`(슬롯당 2048)로 JIT 로드해 400 이 난다. 다이어트(3k)로도 못 넘으니
  **서버에서 모델 선로드 필수**([info_promptDiet.md](info_promptDiet.md) §5).
* **긴 응답 타임아웃** — Windows `API_TIMEOUT_MS` 가 서버 ctx 대비 짧으면 장문에서 끊긴다.

# 관련

* [info_promptDiet.md](info_promptDiet.md) — 요청 축소(도구 스키마 제거)
* [info_jinja_and_lms.md](info_jinja_and_lms.md) — LMS jinja 템플릿 이슈 / GPU offload
* [lms-jinja-fix.sh](lms-jinja-fix.sh) — Jinja 진단·검증 모델 로드
* [step4.cc_gw_lms2/.env](step4.cc_gw_lms2/.env) — 튜닝 노브 SSOT
* [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) — Windows 연결 매뉴얼
