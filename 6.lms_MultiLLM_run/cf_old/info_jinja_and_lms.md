# info — Jinja 오류 & LMS 성능(GPU offload) 정리

`6.lms_MultiLLM_run` 스택에서 Claude Code ↔ LM Studio 연동 중 확인한 문제와 원인·해결을 정리한다.
결론부터: **처음엔 "Jinja 오류"로 의심했으나, 실측 결과 실제 병목은 "GPU offload 미동작(CPU 추론)"** 이었다.

---

## 0. 운영 제약 (중요)

* **보안망** — 사용 모델은 **`google/gemma-4-31b-qat` 만**. 중국계 모델(**Qwen, GLM/zai-org 제외**).
* 따라서 참고 문서의 "검증된 모델로 전환"(qwen3-coder 등)은 **적용 불가**. gemma-4-31b-qat 자체가
  잘 돌게 만드는 것이 목표.
* 배포 타깃 GPU: **A6000 48GB**. (검증에 쓴 현재 호스트 `fg1` 은 **16GB** GPU 로, 31B 가 VRAM 에
  다 안 들어가는 별도 변수 존재 — 아래 참조.)

---

## 1. 두 문제를 구분하라

| # | 문제 | 증상 | 이번 스택에서 |
| :- | :--- | :--- | :--- |
| A | **Jinja 템플릿 오류** | `500 ... "Error rendering prompt with jinja template: Cannot perform operation ~ on undefined values"` | 특정 모델(lmstudio-community nemotron 등)에서 발생하는 **별개** 이슈 |
| B | **GPU offload 미동작** | 단순 추론도 수십 초~타임아웃(`504 Gateway Time-out`), 응답 없음 | **gemma-4-31b-qat 이 느렸던 실제 원인** |

> ⚠️ gemma-4-31b-qat 이 느렸던 건 Jinja 가 아니라 **B(=CPU 추론)** 때문이었다. Jinja 오류
> 메시지는 gemma 에서 관측되지 않았다(추론이 끝나지 않아 애초에 응답 자체가 없었음).

---

## 2. 문제 A — Jinja 템플릿 오류 (참고용)

* 원인: 모델의 embedded **Jinja chat template** 이 Claude Code 의 `tools`/`system` 페이로드를
  렌더하지 못함. `~`(문자열 결합)를 undefined 값에 수행하다 실패.
* 참고 문서: `jm4:/Users/nowage/_doc/3.Resource/_LLM/Tools/LM_Studio_Ubuntu_Headless.md`
* 해결책
  1. **검증된 모델 사용** — 보안 제약상 중국계 제외 → Google 계열만: `google/gemma-4-26b-a4b`
     (문서 검증) 또는 `google/gemma-4-31b-qat`(본 스택 필수 모델).
  2. **prompt template 편집** (문제 모델을 꼭 써야 할 때) — `| string` 필터 제거
     (`{{ tool | string }}` → `{{ tool }}`) 또는 템플릿 통째 교체. GUI 가 확실하며,
     헤드리스(`lms load`)엔 템플릿 override 플래그가 **없다**.
* 진단 도구: [`lms-jinja-fix.sh`](lms-jinja-fix.sh) `probe` (tools 포함 요청 → 오류 문자열 탐지).

> 현재 gemma-4-31b-qat 의 Jinja 적합성은 **미확정** — B(성능) 때문에 tools 요청이 완주하지
> 못해 확인이 안 됐다. **B 해결 후(A6000) tools 포함 요청으로 재검증** 필요.

---

## 3. 문제 B — GPU offload 미동작 (실제 원인)

### 진단 과정

1. gemma-4-31b-qat 로 단순 요청(`max_tokens 10`, tools 없음)도 **60s 타임아웃, 응답 없음**.
   → tools/Jinja 무관, **기본 추론 자체가 느림**.
2. `nvidia-smi` — 컨테이너에서 GPU 는 보이나, **18GB 모델이 로드된 상태인데 VRAM 사용 0 MiB**.
   → 모델이 **CPU(RAM)에서 실행** 중 = 31B CPU 추론 = 사실상 사용 불가 속도.
3. `lms runtime ls` — **CUDA 백엔드는 설치돼 있으나 SELECTED 는 CPU(avx2)**:
   ```
   llama.cpp-linux-x86_64-avx2@2.23.1               ✓   ← CPU 선택됨
   llama.cpp-linux-x86_64-nvidia-cuda-avx2@2.23.1       ← CUDA 미선택
   ```
4. 추가 변수: 현재 호스트 `fg1` GPU 는 **16380 MiB(16GB)** — gemma-4-31b-qat(18.85GB)이
   **16GB 에 다 안 들어감**. (타깃 A6000 48GB 에선 여유롭게 적재.)

### 근본 원인

* **(주)** llmster 가 CUDA 런타임을 설치해도 **기본 SELECTED 가 CPU(avx2)** 라, `--gpu max`
  여도 CPU 로 추론.
* **(부)** fg1 의 16GB VRAM < 모델 18.85GB → CUDA 를 선택해도 전량 offload 불가(부분).
  A6000 48GB 에선 해당 없음.

### 해결

1. **CUDA 런타임 선택** (핵심):
   ```bash
   lms runtime ls                                   # 설치된 엔진 확인
   lms runtime select llama.cpp-linux-x86_64-nvidia-cuda-avx2   # CUDA 선택
   # 이후 모델 재로드해야 반영: lms unload --all && lms load <model> --gpu max
   ```
2. **VRAM ≥ 모델 크기** — A6000 48GB 는 gemma-4-31b-qat(18.85GB) 전량 offload 가능.
   16GB 급에선 `--gpu` 를 부분값으로 주거나 더 작은 양자화 필요.

### 적용 (path 패치 — 이미지 재반입 불필요)

`6.lms_MultiLLM_run` 은 `entrypoint.lms.sh` 를 **런타임 bind-mount(`:ro`) 로 주입**하므로,
이 파일만 고치면 이미지 재빌드/재반입 없이 다음 `./start.sh` 부터 반영된다.

* [`entrypoint.lms.sh`](entrypoint.lms.sh) 에 **GPU 런타임 자동 선택 로직 추가**(3.5 단계):
  `LMS_GPU!=off` 이고 GPU 감지되면 `lms runtime ls` 에서 CUDA 엔진을 찾아 `lms runtime select`.
  CUDA 미설치면 경고 후 CPU 로 계속.

> ⚠️ 현재 실행 중인 `lms-1`(반입 불가 셋팅)은 **건드리지 않았다**. 위 수정은 파일에만 반영돼
> 있으며, **다음 스택 재기동 시** 적용된다. (실행 중 컨테이너에 즉시 반영하려면 별도로
> `lms runtime select` 후 모델 재로드가 필요하지만, 운영 정책상 재기동으로 반영 권장.)

---

## 4. 진단 명령 모음

```bash
# GPU 가 실제로 쓰이는지 (모델 로드 상태에서 VRAM > 0 이어야 정상)
docker exec <lms컨테이너> nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader

# 선택된 추론 엔진 (CUDA 여야 함)
docker exec <lms컨테이너> bash -lc 'export PATH=$HOME/.lmstudio/bin:$PATH; lms runtime ls'

# 로드 상태 / 컨텍스트
docker exec <lms컨테이너> bash -lc 'export PATH=$HOME/.lmstudio/bin:$PATH; lms ps'

# 추론 속도/Jinja 진단 (tools 포함) — 게이트웨이 경유
./lms-jinja-fix.sh probe google/gemma-4-31b-qat
```

---

## 5. 결론 / 체크리스트 (A6000 배포 시)

- [ ] `entrypoint.lms.sh` 의 GPU 런타임 자동 선택 반영된 스택으로 기동 (`./start.sh`)
- [ ] `nvidia-smi` — gemma 로드 후 **VRAM ≈ 19GB 사용**(0 이면 여전히 CPU)
- [ ] `lms runtime ls` — **CUDA 엔진 SELECTED**
- [ ] 단순 추론(`max_tokens 10`) **1~2초 내 응답**
- [ ] `./lms-jinja-fix.sh probe google/gemma-4-31b-qat` — **tools 포함 요청 정상**(Jinja 오류 없음)
- [ ] 정상이면 `./vscode-connect.sh on` 으로 VSCode 확장 연결

> 요약: **느림의 원인은 Jinja 가 아니라 GPU offload 미동작(CPU 추론)**. CUDA 런타임 선택 +
> 충분한 VRAM(A6000 48GB)이면 gemma-4-31b-qat 단일 모델로 정상 동작할 것으로 기대된다.
> (Jinja 적합성은 GPU 정상화 후 재검증.)

---

## 참고

* 원 문서: `jm4:/Users/nowage/_doc/3.Resource/_LLM/Tools/LM_Studio_Ubuntu_Headless.md`
* 패치 사용법: [`PATCH.md`](PATCH.md) (`vscode-connect.sh`, `lms-jinja-fix.sh`)
* 스택 구조: [`README.md`](README.md)
