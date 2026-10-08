# 모델 튜닝 — 로컬 LLM + Claude Code 를 실사용 가능하게

로컬 LLM 백엔드에서 Claude Code 를 쓸 때 손대는 축은 **두 개**다.

| 축 | 무엇 | 문서 |
| :--- | :--- | :--- |
| **요청 축소 (다이어트)** | claude 가 보내는 프롬프트(도구 스키마)를 줄임 — 20k→3k | [`info_promptDiet.md`](info_promptDiet.md) |
| **서버 튜닝 (이 문서)** | LMS 로드 파라미터로 VRAM·속도·컨텍스트를 맞춤 | 여기 |

둘은 독립이고 곱해진다. 다이어트로 **왕복당 prefill** 을 줄이고, 튜닝으로 **처리 속도·최대 길이**를 정한다.

> 실측 출처: fg1 (NVIDIA 16GB) + LM Studio + Claude Code. 상세 수치는
> `DeviceManagement/fg1/lms/context_128k_report.md`, `benchmark_lms_report.md`.

---

## 1. 튜닝 노브 (이 스택의 위치)

이 스택은 `entrypoint.lms.sh` 가 `lms load` 로 모델을 올린다. 노브는 전부 **`.env`** 에 있다.

| `.env` 변수 | 역할 | 주의 |
| :--- | :--- | :--- |
| `LMS_CONTEXT_LENGTH` | 컨텍스트 토큰 상한 | Claude Code 는 시스템+도구가 커서 **32768 이상** 필요(기본 8192 부족) |
| `LMS_GPU` | GPU offload 비율 (`max`/`off`/`0~1`) | VRAM<모델 환경에서 `max` 는 **CUDA OOM** — §3 |
| `LMS_PARALLEL` | 동시 예측 슬롯 | llmster 는 ctx 를 슬롯 수로 **분할**(4면 32k→8k). **반드시 1** (아니면 500) |
| `CLAUDE_MAX_OUTPUT_TOKENS` | 출력 상한 | 32k ctx 에 input+output 합산이 들어가야 함 |

`lms load` 에는 **KV 양자화 플래그가 없다**(§4-B). 위 4개가 이 스택에서 조절 가능한 전부다.

### CUDA 런타임 자동선택 함정 (이미 반영됨)

llmster 는 CUDA 백엔드를 설치해도 기본 SELECTED 가 **CPU(avx2)** 인 경우가 있다. 그러면
`LMS_GPU=max` 여도 CPU 로 추론해 대형 모델이 극도로 느려지고 504 가 난다. `entrypoint.lms.sh`
3.5절이 부팅 시 `lms runtime select <nvidia-cuda>` 로 자동 교정한다 — GPU 인데 느리면 여기부터 의심.

---

## 2. VRAM 예산 — offload 안전선

**병목은 RAM 이 아니라 VRAM 안에서 가중치·KV·prefill 연산 버퍼를 어떻게 나누냐다.**

핵심 함정: **KV 캐시는 로드 시 선할당되지만, prefill 연산 버퍼(batch)는 추론 시점에 추가로 필요**하다.
그래서 VRAM 을 꽉 채우면 **로드는 성공하고 짧은 요청도 통과하지만, 긴 프롬프트에서 CUDA OOM 크래시**한다.

fg1 16GB 실측 (gemma-4-26b, KV q8_0, 128k):

| `--gpu` | 레이어 | VRAM | 짧은 프롬프트 | 긴 프롬프트(110k) |
| :--- | ---: | ---: | :--- | :--- |
| 0.75 | 23 | 97% | 25 tok/s (빠름) | ❌ CUDA OOM 크래시 |
| **0.6** | 19 | 83% | 20 tok/s | ✅ 통과 |

→ **짧은 프롬프트 속도만 보고 offload 를 올리지 말 것.** 128k 에이전트 용도의 안전선은 VRAM **~83%**.
`LMS_GPU=max` 를 쓰려면 VRAM 이 모델보다 확실히 커야 한다(그때만 안전).

---

## 3. 128k 장문 — 두 경로

| 경로 | 방법 | 이 스택 |
| :--- | :--- | :--- |
| **A. 소형 모델** | KV 가 애초에 작음 | 개발 머신(16GB) 테스트용 (`gemma-4-e2b`, 백엔드당 ~3.95GB) |
| **B. 대형 모델 + KV q8_0** | KV 를 절반으로 양자화 | ❌ `lms load` 불가 + **A6000 에선 불필요** (아래) |

> ⚠️ **2026-07-18 정정.** 이전 판은 "경로 A(`gemma-4-e2b`)가 이 스택의 기본"이라 적었으나
> 사실이 아니다 — 반입 구성은 `google/gemma-4-31b-qat` 이다(`.env` 참조). `e2b` 는 16GB
> 개발 머신 검증용(`lms:small`)일 뿐이다. 아래는 그 전제로 다시 계산한 결과다.

### gemma-4 는 MQA 도 일반 GQA 도 아니다 — 5:1 sliding-window

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

**32k → 128k 증분이 fp16 기준 +1.9 GiB 에 불과하다.** (검증: SWA 미적용 가정으로 계산하면
prj55 의 실측 성공 사례가 카드 용량을 초과해 산술적으로 불가능해진다 — 즉 SWA 캡이 실제로
동작 중임이 역산으로 확인된다.)

31b 는 층 수를 확인하지 못해 **3~9 GB 대역**으로만 말할 수 있다(같은 gemma4 계열이므로 5:1
가정). 그래도 A6000 48GB 예산은 `가중치 18.85 + KV 3~9 + 연산버퍼 3~5 = 25~33GB (52~69%)`
로 83% 안전선 안이다.

**따라서 경로 B(KV q8_0)는 A6000 에서 이식할 이유가 없다.** q8_0 은 fg1(16GB)에서 *부족한
VRAM 을 쥐어짜기 위한* 수단이었고 속도 이득은 없었다(짧은 프롬프트에선 오히려 느림).
48GB 에는 쥐어짤 부족이 없다. 게다가 `lms load` 에 KV 양자화 플래그가 없어 lmstudio Python
SDK 를 경유해야 하는데, **SDK 경로는 `--parallel` 을 잃어 4로 고정**된다 — 32k 에서 이는
슬롯당 8k 가 되어 Claude Code 가 500 을 맞는다(§ 아래 표). 구현 예시는
`DeviceManagement/fg1/lms/load_model_q8.py`. **하지 말 것.**

### 컨텍스트 × parallel 안전 조합

| ctx | parallel | 슬롯당 | 결과 |
| ---: | ---: | ---: | :--- |
| 32,768 | 1 | 32k | ✅ **현재 구성** |
| 131,072 | 1 | 128k | ✅ (이 스택이 128k 로 갈 때의 모습) |
| 131,072 | 4 | 32k | ✅ prj55 실측 통과 (SDK 경로) |
| 32,768 | 4 | 8k | ❌ 500 (`n_keep >= n_ctx`) |
| 8,192 | 4 | 2k | ❌ 400 — JIT 기본값. `entrypoint.lms.sh` 가 JIT 를 끄는 이유 |

`entrypoint.lms.sh` 는 `--parallel ${LMS_PARALLEL}` 을 넘기고 `.env` 가 `1` 이므로,
**이 스택에서 컨텍스트 상향은 변수 하나만 바꾸는 일**이다(SDK 경로의 parallel 함정과 무관).

### 그런데 병목은 VRAM 이 아니라 prefill 지연이다

prj55 실측(fg1 16GB, 층 상당수가 CPU 상주라 A6000 과 직접 비교 불가):

* 110,716 토큰 → **TTFT 241초**, 생성 2.29 tok/s
* 30,000 토큰 → TTFT 55초, 6.45 tok/s
* 에이전트 루프는 **도구 호출마다 늘어난 대화 전체를 재prefill** 하므로 왕복 수에 비례해 누적

A6000 전량 offload 면 크게 개선되겠지만 **31b 의 A6000 prefill 은 아무도 측정한 적이 없다.**
`API_TIMEOUT_MS=600000`(600초) 기준으로, 생성 20 tok/s 를 가정해도 출력 8192 토큰이 410초를
먹어 prefill 에 190초밖에 안 남는다. **128k 로 올리려면 `API_TIMEOUT_MS` 도 함께 올려야 한다.**

### 결론 — 반입 시점 권고

**32k 유지.** VRAM 은 128k 를 감당하지만, 미측정 변수는 지연이고 그쪽이 실사용을 좌우한다.
`CLAUDE_DIET=1` 이면 프롬프트가 ~3k 라 대부분의 트래픽은 32k 근처도 가지 않는다.

air-gap 운영자가 이 순서로 측정한 뒤 판단할 것:

1. `nvidia-smi -L` — GPU 장수 확인 (`LMS_BACKEND_COUNT` 결정)
2. 현재 32k 로 로드 후 **VRAM MiB 기록** → 위 3~9GB 대역이 실제 숫자로 확정됨
3. **~30k 토큰 프롬프트 종단 시간 측정** ← 128k 가부의 실제 판정 기준 (fg1 55초와 비교)
4. 3이 충분히 빠를 때만 65536 으로 한 단계 올리고 VRAM ≤83% 재확인
5. ⚠️ **반드시 장문으로 테스트할 것** — 짧은 프롬프트만 보고 판단한 것이 97% OOM 을 낳았다
6. 컨텍스트를 올리면 `API_TIMEOUT_MS` 도 함께 상향

---

## 4. 추론 모델은 `/no_think` (Qwen3 등)

Qwen3 계열은 하이브리드 **추론 모델**이라 기본값이 "생각"을 한다. 사소한 질문에도 reasoning
토큰을 대량 소모한다. fg1 실측 (Qwen3-8B):

| 프롬프트 | reasoning 토큰 | 소요 |
| :--- | ---: | ---: |
| "1~5 출력 bash" | 431 | 27.5s |
| 같은 질문 + **`/no_think`** | 0 | **1.8s** |

수업 데모·대화형은 반응속도가 생명이니 프롬프트에 `/no_think` 를 기본으로 넣을 것. (Gemma·비추론
모델은 해당 없음.)

---

## 5. 수업용 소형 모델 선택 (8GB PC · Claude Code 동작)

윈도우 교실 PC(VRAM 8GB)에서 **Claude Code 에이전트가 실제로 도는** 작은 모델. 관문은 "tool_use
표기"가 아니라 **에이전트 루프(도구 호출→관찰→다음 호출)를 견디느냐** 다 — `devstral-small-2507`
이 바로 여기서 탈락(500)했으므로 **실측 전엔 보장 못 함**.

| 모델 | 파일(Q4) | 상태 | 비고 |
| :--- | ---: | :--- | :--- |
| **Qwen3-8B** (`qwen/qwen3-8b`) | 4.7GB | ✅ fg1 실측 통과 | API·에이전트·**실제 Bash 도구 호출** 통과. `--gpu 0.8`→VRAM 7.9GB/32k |
| Qwen2.5-Coder-7B | ~4.7GB | 미검증 | 코딩 수업 후보 |
| 4B 이하 | 2~3GB | 위험 | 단발은 되어도 멀티스텝 에이전트에서 형식 붕괴 |

**7~8B 가 에이전트 실질 하한선.** 8GB 카드는 7.9/8.0 으로 빠듯하니(디스플레이가 VRAM 을 먹음)
`--gpu 0.7` 로 낮추거나 ctx 를 16k 로 줄일 여유를 둘 것.

---

## 6. Windows VSCode Claude Code 확장 설정

> 호스트(Linux/Mac)용은 [`vscode-connect.sh`](vscode-connect.sh) / [`PATCH.md`](PATCH.md) 참조.
> **Windows 는 그 bash 스크립트가 네이티브로 안 돈다** — 아래 수동 절차 또는
> [`vscode-connect.ps1`](vscode-connect.ps1)(PowerShell 대응물) 을 쓸 것.

Claude Code 확장은 CLI 와 동일하게 **`%USERPROFILE%\.claude\settings.json`**
(= `C:\Users\<사용자>\.claude\settings.json`) 를 읽는다. 여기에 백엔드 주소·모델을 넣는다.

### 시나리오 두 가지

| | A. 각 PC 로컬 LM Studio | B. GPU 서버 게이트웨이 클라이언트 |
| :--- | :--- | :--- |
| 모델 구동 | 그 윈도우 PC 자신 | 원격 GPU 서버 |
| `ANTHROPIC_BASE_URL` | `http://localhost:1234` | `http://<서버IP>:8080` |
| 수업 적합 | 교실 PC 각자 소형 모델(§5) | PC 는 씬 클라이언트, 서버가 무거운 모델 |
| 사전 조건 | PC 에 LM Studio + 모델 로드 | 서버 `./start.sh`, 서버 방화벽 8080 개방 |

### settings.json 내용 (두 시나리오 공통 형식)

```jsonc
{
  "model": "qwen/qwen3-8b",                         // 로드한 모델 키
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:1234",  // A: localhost:1234 / B: http://<서버IP>:8080
    "ANTHROPIC_AUTH_TOKEN": "lms",                  // 더미 토큰(값 무관, 존재만 하면 됨)
    "API_TIMEOUT_MS": "600000",                     // 로컬 추론 느림 → 10분(필수)
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1" // 비-Anthropic 엔드포인트 잡음 차단
  }
}
```

### 수동 절차 (PowerShell)

```powershell
# 1) 폴더 생성 + 파일 편집
mkdir "$env:USERPROFILE\.claude" -Force
notepad "$env:USERPROFILE\.claude\settings.json"   # 위 JSON 붙여넣기 (BASE_URL 시나리오에 맞게)

# 2) VSCode 재시작: 명령팔레트(Ctrl+Shift+P) → "Developer: Reload Window"

# 3) 확인 — 백엔드가 응답하는지 (시나리오 A)
curl.exe http://localhost:1234/v1/models          # 시나리오 B 는 http://<서버IP>:8080/v1/models
```

또는 [`vscode-connect.ps1`](vscode-connect.ps1) 로 자동 병합(기존 키 보존·되돌리기 가능):

```powershell
# 시나리오 A (로컬 LM Studio)
.\vscode-connect.ps1 -Action on -BaseUrl http://localhost:1234 -Model qwen/qwen3-8b
# 시나리오 B (원격 게이트웨이)
.\vscode-connect.ps1 -Action on -BaseUrl http://192.168.0.4:8080 -Model google/gemma-4-e2b
.\vscode-connect.ps1 -Action status
.\vscode-connect.ps1 -Action off        # 우리가 넣은 키만 제거 → Anthropic 복귀
```

### Windows 함정

* **`localhost` vs 서버 IP** — 시나리오 B 는 `localhost` 가 아니라 **GPU 서버의 LAN IP**. 서버 쪽
  `start.sh` 는 게이트웨이를 `0.0.0.0:8080` 으로 노출하지만, **서버 OS 방화벽에서 8080 인바운드
  허용**이 별도로 필요하다(리눅스 `ufw allow 8080`, 클라우드면 보안그룹).
* **로컬 LM Studio 는 네트워크 바인딩 확인** — 시나리오 A 라도 확장이 다른 프로세스로 접근하면
  LM Studio 설정에서 "Serve on Local Network"(0.0.0.0 바인드)가 켜져야 할 수 있다. 같은 PC
  `localhost` 면 대개 문제 없음.
* **PowerShell 실행 정책** — `.ps1` 이 막히면 `powershell -ExecutionPolicy Bypass -File .\vscode-connect.ps1 ...`.
* **재시작 필수** — settings.json 을 바꾼 뒤 반드시 "Developer: Reload Window". 안 하면 이전 설정 유지.
* **경로 백슬래시** — `%USERPROFILE%` 는 `C:\Users\<사용자>`. WSL 안(`\\wsl$`)이 아니라 **윈도우
  네이티브 홈**이다. VSCode 를 WSL 원격으로 열었다면 그 리눅스 홈(`~/.claude`)을 봐야 하니 혼동 주의.
* **모델 미로드 시 JIT 400** — 서버가 모델을 안 올린 상태로 요청받으면 LM Studio 가 기본
  `ctx 8192/parallel 4`(슬롯당 2048)로 JIT 로드해 400 이 난다. 다이어트(3k)로도 못 넘으니
  **모델 선로드 필수**([`info_promptDiet.md`](info_promptDiet.md) §5).

---

## 관련

* [`info_promptDiet.md`](info_promptDiet.md) — 요청 축소(도구 스키마 제거)
* [`info_jinja_and_lms.md`](info_jinja_and_lms.md) — LMS jinja 템플릿 이슈
* [`vscode-connect.ps1`](vscode-connect.ps1) — Windows VSCode 연결 스크립트
* `DeviceManagement/fg1/lms/context_128k_report.md` — 128k·KV q8_0·offload 안전선 원본 실측
* `DeviceManagement/fg1/lms/load_model_q8.py` — KV q8_0 SDK 로더(경로 B 이식 시 참조)
