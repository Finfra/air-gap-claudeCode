---
name: README
description: lms 이미지 CUDA 11 런타임 노출 오버레이 — libcudart.so.11.0 미해석(엔진 로드 실패) 해결
date: 2026-07-23
---

# 개요

`6.lms_MultiLLM_run` 반입 실패(`libcudart.so.11.0: cannot open shared object file`)의
**이미지 측 해결**. prj55#Issue9 가 지목한 "CUDA 11 런타임 부재"의 실제 정체는 *부재*가
아니라 *경로 미노출*이었다.

# 근본 원인 (fg1 에서 하드 증거로 확정, 2026-07-23)

`lms:latest`/`lms:small` 이미지 내부를 직접 확인한 결과:

| 확인 | 결과 |
| :--- | :--- |
| `libcudart.so.11.0` 존재? | ✅ 있음 — `/home/lms/.lmstudio/extensions/backends/vendor/linux-llama-cuda-vendor-v1/` (LM Studio 번들) |
| CUDA 백엔드 존재? | ✅ `llama.cpp-linux-x86_64-nvidia-cuda-avx2-2.23.1/libggml-cuda.so` (565MB) |
| `ldconfig -p` 에 cudart? | ❌ **없음** — vendor 디렉토리가 링커 검색 경로에 미등록 |

수정 전후 `ldd libggml-cuda.so`:

```
[수정 전]  libcudart.so.11.0 => not found        ← 엔진 로드 실패의 직접 원인
           libcublas.so.11   => not found
           libcuda.so.1      => not found

[수정 후]  libcudart.so.11.0 => .../vendor/linux-llama-cuda-vendor-v1/libcudart.so.11.0  ✅
           libcublas.so.11   => (해석됨)
           libcuda.so.1      => not found        ← 드라이버, --gpus 로 런타임 주입 (정상)
```

→ **호스트에 CUDA 11 을 설치할 필요가 없다.** 컨테이너는 호스트 ldconfig 를 상속하지
않고, nvidia-container-toolkit 은 드라이버(libcuda.so.1)만 주입하며 libcudart 는 주입하지
않는다. 필요한 CUDA 11 런타임은 이미 이미지 안에 있으므로, ldconfig 등록만으로 해결된다.

# 수정 내용

`Dockerfile.cuda11fix` — 베이스 이미지에 얇은 레이어 하나 추가:

1. vendor 디렉토리(libcudart.so.11* 위치)를 `/etc/ld.so.conf.d/lms-cuda11.conf` 에 등록
2. `ldconfig` 갱신
3. 빌드 시 `ldconfig -p | grep libcudart.so.11` 자체 검증 (실패 시 빌드 실패 = fail-loud)

USER root 로 수행(ldconfig 는 root 필요). entrypoint 는 런타임에 lms(비-root)로 돌아
ldconfig 를 못 하므로, 이미지 빌드 레이어에서 처리하는 것이 유일한 정공법이다.

# 사용

```bash
# 1) CUDA 정상화 — 얇은 레이어 (빠름, 베이스 재빌드/재다운로드 없음)
./build_cuda11fix.sh                 # lms:small → lms:small-cuda11fix
./build_cuda11fix.sh lms:latest      # lms:latest → lms:latest-cuda11fix

# 2) 반입용 슬림화 — E2B 제거, 31B 전용 (29.1GB → 22.2GB, DVD 7장 → 5장)
./build_slim31b.sh                   # lms:small-cuda11fix → lms:31b-cuda11fix

# step4 에서 교체 이미지 사용
cd ../step4.cc_gw_lms2
LMS_IMAGE=lms:31b-cuda11fix ./run.sh
```

## build_slim31b.sh — 왜 flatten 인가

`Dockerfile` 의 `RUN rm -rf <모델>` 은 상위 레이어에 **삭제 마커만** 남긴다. 하위 레이어에는
원본 4.2GB 가 그대로 남아 `docker save` 산출물이 전혀 줄지 않는다 → DVD 장수 그대로.
따라서 컨테이너 파일시스템을 `docker export | docker import` 로 **단일 레이어로 평탄화**해야
실제로 빠진다. 이미지 메타데이터(`USER`·`WORKDIR`·`ENV`·`ENTRYPOINT`)는 `--change` 로 재부여하며,
`ldconfig` 가 만든 `/etc/ld.so.cache` 는 파일시스템에 있으므로 **cuda11fix 효과는 그대로 보존**된다
(빌드 스크립트가 export 직전·import 직후 두 번 `ldconfig -p | grep libcudart.so.11` 로 확인).

빌드된 이미지는 v2 `entrypoint.lms.sh` 의 CUDA 프리플라이트(`ldconfig -p | grep
libcudart.so.11`)를 통과하므로 `LMS_REQUIRE_CUDA=1` 기본에서 정상 기동한다.

# 영구화(선택)

이 오버레이 대신 베이스 이미지에 영구 반영하려면, lms 베이스를 빌드하는
`Dockerfile.lms`(install.sh 설치 직후, USER root 구간)에 아래를 추가:

```dockerfile
USER root
RUN set -eux; \
    lib="$(find /home/lms/.lmstudio/extensions/backends/vendor -name 'libcudart.so.11*' -print -quit)"; \
    dir="$(dirname "$lib")"; \
    echo "$dir" > /etc/ld.so.conf.d/lms-cuda11.conf; \
    ldconfig
USER lms
```

# 검증 상태 (2026-07-23)

* ✅ 근본 원인 확정 — `lms:latest` throwaway 컨테이너에서 `ldd`/`ldconfig` 로 확인
* ✅ 수정 로직 검증 — ldconfig 등록 후 `libcudart.so.11.0`/`libcublas.so.11` 해석 성공
* ✅ **실제 오버레이 빌드 완료** — `lms:small-cuda11fix` 빌드(sha256:f5626d45…). 빌드 아티팩트
  내부 `ldd libggml-cuda.so` 로 `libcudart.so.11.0`·`libcublas.so.11`·`libcublasLt.so.11`
  전부 해석 확인(드라이버 `libcuda.so.1` 만 미해석 — `--gpus` 런타임 주입, 정상)
* ✅ **GPU 실기동 검증 완료 (2026-07-30, fg1)** — 아래 "실기동 검증" 절

# 실기동 검증 (2026-07-30, fg1 / RTX 16GB)

`entrypoint.lms.sh`(v2, `LMS_REQUIRE_CUDA=1`)를 물려 실제로 컨테이너를 띄우고 추론까지 확인함.

| 대상 | `lms:small-cuda11fix` (E2B) | `lms:31b-cuda11fix` (31B 슬림) |
| :--- | :--- | :--- |
| CUDA 프리플라이트 | ✅ 통과 | ✅ 통과 |
| 선택된 런타임 | `llama.cpp-linux-x86_64-nvidia-cuda-avx2@2.23.1` | 동일 |
| 모델 로드 | `gemma-4-e2b-it` 39.5s (4.11 GiB) | `google/gemma-4-31b-qat` (17.56 GiB) |
| offload | `LMS_GPU=max` (전량) | `LMS_GPU=0.6` (부분 — 16GB GPU 한계) |
| **VRAM 실점유** | **3,286 MiB** | **13,438 MiB** |
| chat completion | ✅ `CUDA_OK` (0.24s) | ✅ `CUDA_OK` (20s, 54 tok) |

* 16GB GPU 에서 31B(17.6GiB)는 전량 offload 가 불가능해 부분 offload 로 검증했다. 느린 것은
  VRAM 부족 탓이며 CUDA 경로 자체는 정상이다. **A6000(48GB) 반입 서버에서는 `LMS_GPU=max`.**
* `google/gemma-4-31b-qat` 는 **reasoning 토큰을 먼저 뱉는다** — 위 테스트에서 54 토큰 중 47 이
  reasoning 이었다. `max_tokens` 를 작게 주면 본문이 잘려 `content` 가 빈 문자열로 온다.
  클라이언트의 `CLAUDE_MAX_OUTPUT_TOKENS` 를 넉넉히(≥8192) 둘 것.
