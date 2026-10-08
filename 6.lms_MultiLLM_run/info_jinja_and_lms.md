---
name: info_jinja_and_lms
description: step5 기초 참고 — Jinja 오류 vs GPU offload 미동작 구분. Windows 접속 실패로 오진하기 전 서버측(step4 스택)에서 먼저 확인할 것
date: 2026-07-21
---

# 이 문서의 위치 (step5 관점)

step5 는 클라이언트를 Windows 로 바꾸는 것 **하나만** 검증한다. 서버 스택(lms-1·lms-2·gateway)은
[step4.cc_gw_lms2/README.md](step4.cc_gw_lms2/README.md) 의 것을 그대로 쓴다. 따라서 **아래 두 문제는
step4 단계에서 이미 해소돼 있어야 하는 서버측 전제**다.

> Windows 에서 응답이 느리거나 오류가 나면 `settings.json` 부터 의심하기 쉽지만, 원인이 서버측 이
> 두 문제(Jinja·GPU offload)인 경우 클라이언트를 아무리 고쳐도 소용없다. **먼저 서버에서 배제**하라 —
> `curl.exe http://<서버IP>:8080/v1/models` 가 되는데 실제 대화만 느리다면 여기부터 본다.

결론부터: **처음엔 "Jinja 오류"로 의심했으나, 실측 결과 실제 병목은 "GPU offload 미동작(CPU 추론)"** 이었다.

# 0. 운영 제약 (중요)

* **보안망** — 사용 모델은 **Google(gemma) 계열만**. 중국계 모델(**Qwen, GLM/zai-org**) 금지.
  ([step4.cc_gw_lms2/.env](step4.cc_gw_lms2/.env) 의 `LMS_MODEL` 이 SSOT.)
* 따라서 외부 참고 문서의 "검증된 모델로 전환"(qwen3-coder 등)은 **적용 불가**. gemma 계열 자체를
  잘 돌게 만드는 것이 목표.
* 배포 타깃 GPU: **A6000 48GB**. (검증 호스트 `fg1` 은 **16GB** GPU 로, 31b 가 VRAM 에 다 안
  들어가는 별도 변수 존재 — 아래 참조. 그래서 16GB 검증은 `gemma-4-e2b-it`, A6000 반입은
  `gemma-4-31b-it-qat`.)

# 1. 두 문제를 구분하라

| # | 문제 | 증상 | 이번 스택에서 |
| :- | :--- | :--- | :--- |
| A | **Jinja 템플릿 오류** | `500 ... "Error rendering prompt with jinja template: Cannot perform operation ~ on undefined values"` | 특정 모델(lmstudio-community nemotron 등)에서 발생하는 **별개** 이슈 |
| B | **GPU offload 미동작** | 단순 추론도 수십 초~타임아웃(`504 Gateway Time-out`), 응답 없음 | **gemma-4-31b-qat 이 느렸던 실제 원인** |

> ⚠️ gemma-4-31b-qat 이 느렸던 건 Jinja 가 아니라 **B(=CPU 추론)** 때문이었다. Jinja 오류
> 메시지는 gemma 에서 관측되지 않았다(추론이 끝나지 않아 애초에 응답 자체가 없었음).

# 2. 문제 A — Jinja 템플릿 오류 (참고용)

* 원인: 모델의 embedded **Jinja chat template** 이 Claude Code 의 `tools`/`system` 페이로드를
  렌더하지 못함. `~`(문자열 결합)를 undefined 값에 수행하다 실패.
* 해결책
  1. **검증된 모델 사용** — 보안 제약상 중국계 제외 → Google 계열만: `google/gemma-4-26b-a4b`
     (문서 검증) 또는 `google/gemma-4-31b-qat`(A6000 반입 모델).
  2. **prompt template 편집** (문제 모델을 꼭 써야 할 때) — `| string` 필터 제거
     (`{{ tool | string }}` → `{{ tool }}`) 또는 템플릿 통째 교체. GUI 가 확실하며,
     헤드리스(`lms load`)엔 템플릿 override 플래그가 **없다**.
     → **수동 복구 실행 절차(GUI 편집 / 헤드리스 config 주입 / 붙여넣을 gemma+tools 템플릿)**:
     [info_jinja_manual_setup.md](info_jinja_manual_setup.md) (검증 모델로도 안 될 때의 최후 수단).
* 진단 도구: [lms-jinja-fix.sh](lms-jinja-fix.sh) `probe` (tools 포함 요청 → 오류 문자열 탐지).
  이 스크립트는 [step4.cc_gw_lms2/.env](step4.cc_gw_lms2/.env) 를 읽어 게이트웨이(`:8080`) 경유로 진단한다.

> gemma-4-31b-qat 의 Jinja 적합성은 B(성능) 때문에 tools 요청이 완주하지 못하면 확인이 안 된다.
> **B 해결 후(A6000) tools 포함 요청으로 재검증** 필요.

# 3. 문제 B — GPU offload 미동작 (실제 원인)

## 진단 과정

1. gemma-4-31b-qat 로 단순 요청(`max_tokens 10`, tools 없음)도 **60s 타임아웃, 응답 없음**.
   → tools/Jinja 무관, **기본 추론 자체가 느림**.
2. `nvidia-smi` — 컨테이너에서 GPU 는 보이나, **18GB 모델이 로드된 상태인데 VRAM 사용 0 MiB**.
   → 모델이 **CPU(RAM)에서 실행** 중 = 31b CPU 추론 = 사실상 사용 불가 속도.
3. `lms runtime ls` — **CUDA 백엔드는 설치돼 있으나 SELECTED 는 CPU(avx2)**:
   ```
   llama.cpp-linux-x86_64-avx2@2.23.1               ✓   ← CPU 선택됨
   llama.cpp-linux-x86_64-nvidia-cuda-avx2@2.23.1       ← CUDA 미선택
   ```
4. 추가 변수: 검증 호스트 `fg1` GPU 는 **16380 MiB(16GB)** — gemma-4-31b-qat(18.85GB)이
   **16GB 에 다 안 들어감**. (타깃 A6000 48GB 에선 여유롭게 적재.)

## 근본 원인

* **(주)** llmster 가 CUDA 런타임을 설치해도 **기본 SELECTED 가 CPU(avx2)** 라, `LMS_GPU=max`
  여도 CPU 로 추론.
* **(부)** fg1 의 16GB VRAM < 모델 18.85GB → CUDA 를 선택해도 전량 offload 불가(부분).
  A6000 48GB 에선 해당 없음. (16GB 검증은 그래서 `gemma-4-e2b-it` 로 한다.)

## 해결 (이미 step4 에 반영됨)

이 스택은 [step4.cc_gw_lms2/entrypoint.lms.sh](step4.cc_gw_lms2/entrypoint.lms.sh) 가 **부팅 시
GPU 런타임을 자동 선택**한다(§3.5, 약 101행). `LMS_GPU!=off` 이고 GPU 가 감지되면 `lms runtime ls`
에서 CUDA 엔진을 찾아 `lms runtime select` 한다. CUDA 미설치면 경고 후 CPU 로 계속한다.

`entrypoint.lms.sh` 는 컨테이너에 **bind-mount(`:ro`) 로 주입**되므로, 이미지 재빌드/재반입 없이
`step4.cc_gw_lms2/run.sh` 재기동만으로 반영된다.

수동으로 즉시 반영하려면(실행 중 컨테이너):

```bash
lms runtime ls                                   # 설치된 엔진 확인
lms runtime select llama.cpp-linux-x86_64-nvidia-cuda-avx2   # CUDA 선택
lms unload --all && lms load <model> --gpu max   # 모델 재로드해야 반영
```

> 운영 정책상 **재기동(`run.sh`)으로 반영 권장**. VRAM ≥ 모델 크기여야 전량 offload 가능하며,
> 16GB 급에선 `LMS_GPU` 를 부분값으로 주거나 더 작은 양자화가 필요하다(→ [info_modelTuning.md](info_modelTuning.md) §2).

# 4. 진단 명령 모음

컨테이너 이름은 step4 기준 **lms-1** / **lms-2**.

```bash
# GPU 가 실제로 쓰이는지 (모델 로드 상태에서 VRAM > 0 이어야 정상)
docker exec lms-1 nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader

# 선택된 추론 엔진 (CUDA 여야 함)
docker exec lms-1 bash -lc 'export PATH=$HOME/.lmstudio/bin:$PATH; lms runtime ls'

# 로드 상태 / 컨텍스트
docker exec lms-1 bash -lc 'export PATH=$HOME/.lmstudio/bin:$PATH; lms ps'

# 추론 속도/Jinja 진단 (tools 포함) — 게이트웨이 경유
./lms-jinja-fix.sh probe gemma-4-e2b-it
```

# 5. 체크리스트 (A6000 반입 서버, step5 공개 전에)

step5 로 Windows 를 붙이기 **전에** 서버에서 이 목록을 통과시켜야 한다. 여기서 실패하면
Windows 에서도 절대 안 된다.

- [ ] `step4.cc_gw_lms2/run.sh` 로 기동 (`entrypoint.lms.sh` GPU 런타임 자동선택 반영본)
- [ ] `nvidia-smi` — 모델 로드 후 **VRAM 사용 > 0**(0 이면 여전히 CPU)
- [ ] `lms runtime ls` — **CUDA 엔진 SELECTED**
- [ ] 단순 추론(`max_tokens 10`) **1~2초 내 응답**
- [ ] `./lms-jinja-fix.sh probe <모델>` — **tools 포함 요청 정상**(Jinja 오류 없음)
- [ ] `step4.cc_gw_lms2/run.sh --check` 전 게이트 통과
- [ ] 정상이면 [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) 절차로 게이트웨이 LAN 공개

> 요약: **느림의 원인은 Jinja 가 아니라 GPU offload 미동작(CPU 추론)**. CUDA 런타임 선택 +
> 충분한 VRAM(A6000 48GB)이면 gemma 단일 모델로 정상 동작한다. (Jinja 적합성은 GPU 정상화 후 재검증.)

# 관련

* [info_modelTuning.md](info_modelTuning.md) — LMS 로드 파라미터(VRAM·속도·컨텍스트) 튜닝
* [info_promptDiet.md](info_promptDiet.md) — 요청 축소(도구 스키마 제거)
* [lms-jinja-fix.sh](lms-jinja-fix.sh) — Jinja 진단·검증 모델 로드
* [info_jinja_manual_setup.md](info_jinja_manual_setup.md) — Jinja 템플릿 **수동 설정 매뉴얼**(자동 우회 실패 시)
* [step4.cc_gw_lms2/README.md](step4.cc_gw_lms2/README.md) — 서버 스택(2백엔드 분산)
* [step5.win_gw_lms2/README.md](step5.win_gw_lms2/README.md) — Windows 클라이언트 연결
* 폐기된 이전 반입본: [cf_old/](cf_old/) (참조 전용, 실행 금지)
