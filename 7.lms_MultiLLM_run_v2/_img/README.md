---
name: README
description: air-gap 반입 이미지(_img) — DVD 분할 굽기부터 단독망 기동·클라이언트 접속까지 전체 매뉴얼
date: 2026-07-30
---

# 이 폴더가 무엇인가

폐쇄망(air-gap) 서버에 넣을 **docker 이미지 3종의 반입본**. 온라인 호스트에서 만든
`docker save` tar 를 DVD 크기로 쪼개 둔 것이며, 단독망에서 [`../load.sh`](../load.sh) 로
다시 합쳐 `docker load` 한다.

> 폐쇄망에는 인터넷이 없으므로 **모델도 이미지 안에 이미 들어 있다.** 별도 모델 반입은 불필요하다.

| 이미지 태그 | 역할 | 내장물 |
| :--- | :--- | :--- |
| `lms:31b-cuda11fix` | LLM 백엔드 (LM Studio, OpenAI 호환 `/v1`) | `google/gemma-4-31b-qat` (17.6GiB) + CUDA 11 런타임 노출 수정 |
| `lms-gateway:latest` | nginx 게이트웨이 (세션 고정·SSE·타임아웃) | — |
| `claude:latest` | Claude Code 클라이언트 컨테이너 | — |

# 왜 이 lms 이미지인가 (CUDA)

이전 반입([6.lms_MultiLLM_run](../../6.lms_MultiLLM_run/README.md))은 GPU 를 켜면 아래로 죽었다:

```
'libcudart.so.11.0': cannot open shared object file: no such file or directory
```

원인은 CUDA 11 런타임의 *부재*가 아니라 *경로 미노출*이었다. `libcudart.so.11.0` 은 LM Studio
번들로 이미지 안에 이미 있었고, 그 vendor 디렉토리가 `ldconfig` 검색 경로에 등록돼 있지
않았을 뿐이다. `lms:31b-cuda11fix` 는 그 등록을 이미지 레이어에서 마친 판본이라
**단독망 호스트에 CUDA 11 을 따로 설치할 필요가 없다.**

fg1 실기동 검증(2026-07-30): 프리플라이트 통과 · `llama.cpp-linux-x86_64-nvidia-cuda-avx2@2.23.1`
선택 · **VRAM 13,438MiB 실점유** · chat completion `CUDA_OK`. 상세: [../cuda11fix/README.md](../cuda11fix/README.md).

# 수록 파일

| 파일 | 크기 (바이트) | 내용 |
| :--- | ---: | :--- |
| `lms_31b-cuda11fix.tar.part00` | 4,600,000,000 | `lms:31b-cuda11fix` 조각 1/5 |
| `lms_31b-cuda11fix.tar.part01` | 4,600,000,000 | 조각 2/5 |
| `lms_31b-cuda11fix.tar.part02` | 4,600,000,000 | 조각 3/5 |
| `lms_31b-cuda11fix.tar.part03` | 4,600,000,000 | 조각 4/5 |
| `lms_31b-cuda11fix.tar.part04` | 3,818,157,056 | 조각 5/5 (재조립 시 총 22,218,157,056) |
| `lms-gateway_latest.tar` | 218,200,576 | `lms-gateway:latest` (분할 없음) |
| `claude_latest.tar` | 695,686,144 | `claude:latest` (분할 없음) |
| `SHA256SUMS` | — | 위 7개 파일의 SHA-256 |
| `MANIFEST.txt` | — | tar → 이미지 태그 대응 |
| `README.md` | — | 이 문서 |

합계 ≈ **23.1GB** (2026-07-30 생성).

* `*.tar.partNN` — DVD 1장을 넘는 tar 를 순서대로 쪼갠 조각. **개별 조각은 tar 가 아니다.**
  전부 모아 `cat` 으로 이어붙여야 원본이 된다(→ `load.sh` 가 자동 수행).
* `SHA256SUMS` — 매체 손상 검증용. **조각 단위** 체크섬이다.
* `MANIFEST.txt` — `tar 파일명 → 이미지 태그` 대응. `load.sh` 가 로드 후 태그 검증에 쓴다.

# 1부 — 온라인 측: 굽기

## 1-1. 산출물 만들기

```bash
cd 7.lms_MultiLLM_run_v2
./export.sh --list          # 대상·크기·필요 매체 수 확인 (save 안 함)
./export.sh                 # 기본 = DVD±R SL 분할 (MEDIA_BYTES=4,600,000,000)
```

* 분할 크기는 `MEDIA_BYTES` 로 바꾼다. DVD 물리 용량은 4,707,319,808B 이고 ISO9660/UDF
  오버헤드와 함께 굽는 문서·스크립트 몫이 필요해 **4.6GB** 를 기본으로 잡았다.
* 다른 매체를 쓰면: `MEDIA_BYTES=25000000000 ./export.sh`(BD-R SL 25GB → 1장),
  `MEDIA_BYTES=0 ./export.sh`(분할 없음, 외장 디스크).
* 이미지 태그는 [`../step4.cc_gw_lms2/.env.org`](../step4.cc_gw_lms2/.env.org) 에서 읽는다.
  즉 **반입한 tar 의 태그 = step4 `run.sh` 가 찾는 태그** 로 자동 일치한다.

## 1-2. 디스크 배치

DVD±R SL 물리 용량은 4,707,319,808B 다. 위 파일을 **6장**에 나눠 담는다.

| 디스크 | 수록 파일 | 점유 |
| :--- | :--- | ---: |
| 1 | `lms_31b-cuda11fix.tar.part00` | 4.60GB |
| 2 | `lms_31b-cuda11fix.tar.part01` | 4.60GB |
| 3 | `lms_31b-cuda11fix.tar.part02` | 4.60GB |
| 4 | `lms_31b-cuda11fix.tar.part03` | 4.60GB |
| 5 | `lms_31b-cuda11fix.tar.part04` | 3.82GB |
| 6 | `lms-gateway_latest.tar` · `claude_latest.tar` · `SHA256SUMS` · `MANIFEST.txt` · **폴더 전체(스크립트·문서)** | 0.92GB |

> * 5번과 6번을 한 장에 합치려 하지 말 것 — 3.82 + 0.92 = 4.74GB 로 **DVD 용량을 24MB 초과**한다.
> * **6번 디스크에는 `7.lms_MultiLLM_run_v2` 폴더 전체(단 `_img/*.tar*` 제외)를 함께 담는다.**
>   스크립트·문서가 없으면 단독망에서 `load.sh` 를 실행할 수 없다. 용량은 1MB 미만이다.

## 1-3. 라벨링 (실수 방지)

각 디스크 표면에 **파일명과 순번을 그대로** 적는다. 조각 순서가 뒤섞이면 `cat` 결과가
깨지는데, SHA256 검증이 그것을 잡아 주긴 하지만 재굽기 비용이 크다.

```
[air-gap lms v2] 1/6  lms_31b-cuda11fix.tar.part00
[air-gap lms v2] 2/6  lms_31b-cuda11fix.tar.part01
[air-gap lms v2] 3/6  lms_31b-cuda11fix.tar.part02
[air-gap lms v2] 4/6  lms_31b-cuda11fix.tar.part03
[air-gap lms v2] 5/6  lms_31b-cuda11fix.tar.part04
[air-gap lms v2] 6/6  gateway + claude + SCRIPTS   ← load.sh 가 여기 있음
```

# 2부 — 단독망 측: 반입부터 접속까지

## 2-0. 사전 요구사항 (이미지에 들어 있지 않은 것)

반입 전에 **단독망 호스트에 이미 있어야** 한다. 없으면 여기서 막히므로 먼저 확인할 것.

| 항목 | 확인 명령 | 없을 때 |
| :--- | :--- | :--- |
| Docker Engine | `docker version` | 별도 반입·설치 필요 |
| NVIDIA 드라이버 | `nvidia-smi` | 별도 설치 필요 |
| **nvidia-container-toolkit** | `docker run --rm --gpus all ubuntu nvidia-smi` | **별도 설치 필요 — 이게 없으면 `--gpus` 자체가 실패한다** |
| 여유 디스크 | `df -h /var/lib/docker` | 이미지 22GB + 재조립 임시 22GB ≈ **50GB 이상** 권장 |
| GPU VRAM | `nvidia-smi` | 31B 전량 offload 는 **24GB 이상**(A6000 48GB 권장) |

> CUDA **툴킷**은 필요 없다. 컨테이너가 CUDA 11 런타임을 자체 보유하고, 드라이버
> (`libcuda.so.1`)만 `--gpus` 로 런타임 주입된다.

## 2-1. 디스크 → 로컬 디스크로 복사

DVD 는 읽기 전용이라 그 위에서 재조립할 수 없다. **먼저 전부 하드디스크 한 폴더로 모은다.**

```bash
mkdir -p ~/airgap && cd ~/airgap
# 6번 디스크에서 폴더 트리부터 복사 (load.sh·문서가 여기 있다)
cp -r /media/cdrom/7.lms_MultiLLM_run_v2 .
cd 7.lms_MultiLLM_run_v2

# 1~5번 디스크를 갈아 끼우며 조각을 _img/ 로 모은다
for d in 1 2 3 4 5; do
  read -p "디스크 ${d} 삽입 후 Enter"
  cp /media/cdrom/_img/* _img/ 2>/dev/null || cp /media/cdrom/* _img/
done

# 빠짐없이 모였는지 확인 — 아래 7개가 모두 있어야 한다
ls -la _img/
#   lms_31b-cuda11fix.tar.part00 .. part04   (5개)
#   lms-gateway_latest.tar · claude_latest.tar
```

경로(`/media/cdrom`)는 배포판마다 다르다 — `lsblk` / `mount` 로 실제 마운트 지점을 확인할 것.

## 2-2. 무결성 검증 (로드 전에 반드시)

```bash
./load.sh --verify
```

`SHA256SUMS` 전 항목이 일치해야 한다. **하나라도 어긋나면 그 디스크를 다시 굽는다.** 손상된
조각으로 `docker load` 하면 "unexpected EOF" 같은 뒤늦은 에러가 나거나, 더 나쁘게는 로드는
됐는데 런타임에 깨지는 경우가 생긴다.

## 2-3. docker load

```bash
./load.sh
```

수행 순서: SHA256 검증 → `*.tar.partNN` 재조립 → `docker load` → `MANIFEST.txt` 의 태그가
실제 로드됐는지 확인. 마지막 태그 확인이 성공해야 step4 `run.sh` 가 이미지를 찾는다.

```
✅ lms:31b-cuda11fix
✅ lms-gateway:latest
✅ claude:latest
```

재조립 후 조각(`*.partNN`)은 디스크에 남는다. 공간이 빠듯하면 로드 성공 확인 뒤 지운다.

## 2-4. CUDA 판정 (기동 전 30초 확인)

여기서 실패하면 뒤 단계를 다 해도 소용없다. 순서대로 3개만 본다.

```bash
# ① 컨테이너가 CUDA 11 런타임을 해석하는가 (이미지 자체 점검, GPU 불필요)
docker run --rm --entrypoint bash lms:31b-cuda11fix -lc 'ldconfig -p | grep libcudart.so.11'
#   → libcudart.so.11.0 ... => /home/lms/.lmstudio/extensions/backends/vendor/.../libcudart.so.11.0

# ② 컨테이너에 GPU 가 보이는가 (nvidia-container-toolkit 점검)
docker run --rm --gpus all --entrypoint bash lms:31b-cuda11fix -lc 'nvidia-smi -L'
#   → GPU 0: ... (UUID: ...)

# ③ 모델이 이미지 안에 있는가
docker run --rm --entrypoint bash lms:31b-cuda11fix -lc 'lms ls'
#   → google/gemma-4-31b-qat ... 18.85 GB  Local
```

셋 다 통과하면 CUDA 경로는 확보된 것이다.

## 2-5. 서버 스택 기동 (step4)

```bash
cd step4.cc_gw_lms2
cp .env.org .env
vi .env
```

`.env` 에서 반입 환경에 맞춰 확인할 값:

| 키 | 기본값 | 조정 기준 |
| :--- | :--- | :--- |
| `LMS_IMAGE` | `lms:31b-cuda11fix` | 반입한 태그 그대로. 건드릴 일 없음 |
| `LMS_MODEL` | `google/gemma-4-31b-qat` | `lms ls` 로 본 **로컬 키**와 정확히 일치해야 함 |
| `LMS_GPU` | `max` | VRAM ≥24GB 면 `max`(전량). 부족하면 `0.6` 등 부분 offload — 느려짐 |
| `LMS_BACKEND_COUNT` | `1` | 2 로 올리려면 (17.6GiB+KV)×2 를 VRAM 이 감당해야 함. A6000 48GB 에서 ≈92% 로 안전선 초과 |
| `LMS_REQUIRE_CUDA` | `1` | **1 유지.** CUDA 실패 시 조용히 CPU 로 넘어가지 않고 중단시키는 안전장치 |
| `LMS_SKIP_GET` | `1` | **1 유지.** 폐쇄망에서 LM Studio 허브 조회는 실패가 아니라 수 분 hang 이 된다 |
| `LMS_CONTEXT_LENGTH` | `32768` | Claude Code 는 시스템+도구 페이로드가 커서 32k 이상 권장 |

```bash
./run.sh                                  # lms-N + gateway + cc 기동
./run.sh --check                          # 게이트 판정 (도달·shim·VRAM)
```

**기동 중 반드시 확인할 로그** — CUDA 가 실제로 잡혔는지:

```bash
docker logs lms-1 2>&1 | grep -E 'CUDA|프리플라이트|selecting'
#   [lms] CUDA 런타임 프리플라이트 통과 (libcudart.so.11 해석 가능)
#   [lms] selecting GPU runtime: llama.cpp-linux-x86_64-nvidia-cuda-avx2@2.23.1

nvidia-smi --query-gpu=memory.used --format=csv
#   → 모델 크기만큼 실제로 점유돼 있어야 한다. 0 MiB 면 CPU 로 돌고 있는 것이다.
```

31B 는 로드에 수 분 걸린다. `--check` 를 너무 일찍 치면 아직 모델이 안 올라와 있을 수 있다.

## 2-6. 붙는 방법 ① — 서버 안에서 (가장 빠른 확인)

`run.sh` 가 `claude:latest` 컨테이너(`cc-step4`)를 이미 게이트웨이에 물려서 띄워 둔다.

```bash
docker exec -it cc-step4 bash
cc                                        # 컨테이너 안의 Claude Code 실행 별칭
```

이 컨테이너에는 `ANTHROPIC_BASE_URL=http://gateway:8080`,
`ANTHROPIC_MODEL=<LMS_MODEL>`, `ANTHROPIC_AUTH_TOKEN=lms` 가 이미 주입돼 있다.

원시 API 로 확인하려면:

```bash
curl -s http://127.0.0.1:8080/v1/models
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"google/gemma-4-31b-qat","max_tokens":300,
       "messages":[{"role":"user","content":"Reply with exactly: CUDA_OK"}]}'
```

> ⚠️ `max_tokens` 를 작게(예: 16) 주면 **빈 응답**이 온다. 이 모델은 reasoning 토큰을 먼저
> 뱉기 때문에 예산이 거기서 소진된다. 최소 300 이상으로 시험할 것.

## 2-7. 붙는 방법 ② — 같은 망의 다른 PC 에서 (Windows 등)

게이트웨이는 기본이 `127.0.0.1` 전용이라 **그대로면 다른 PC 에서 절대 닿지 않는다.**
LAN 공개는 서버에서 한 번만 한다:

```bash
cd ../step5.win_gw_lms2
./serve-lan.sh            # gateway 만 0.0.0.0 으로 재공개 + 클라이언트용 설정값 출력
./serve-lan.sh --check    # 판정
./serve-lan.sh --revert   # 되돌리기(호스트 내부 전용으로 복귀)
```

`lms-N` 백엔드는 건드리지 않으므로 모델 재로드가 없다. 이후 클라이언트 PC 에서:

```
curl.exe http://<서버IP>:8080/v1/models      # ← 이게 먼저 성공해야 한다
```

여기까지 되면 `%USERPROFILE%\.claude\settings.json` 을 작성한다 — 전체 수동 절차(백업·BOM
없는 저장·되돌리기)는 [../step5.win_gw_lms2/README.md](../step5.win_gw_lms2/README.md) 에 있다.
`settings.json` 의 모델 값은 **`.env` 의 `LMS_MODEL` 과 글자 그대로 같아야 한다**
(`google/gemma-4-31b-qat`).

> ⚠️ 게이트웨이·LMS 의 `/v1` 은 **무인증**이다(토큰 `lms` 는 형식상). 폐쇄망 또는 신뢰 LAN
> 전제에서만 공개할 것. 필요하면 방화벽에서 접속 대역을 제한한다.

# 트러블슈팅

| 증상 | 원인 | 조치 |
| :--- | :--- | :--- |
| `load.sh` 에서 체크섬 불일치 | 매체 손상·조각 누락 | 해당 디스크 재굽기. 조각 파일명·개수부터 재확인 |
| `docker load` 가 `unexpected EOF` | 조각이 덜 모였거나 순서 깨짐 | `_img/*.partNN` 이 `00`부터 빠짐없이 있는지 확인 |
| `docker: could not select device driver ... gpu` | nvidia-container-toolkit 미설치 | 2-0 사전 요구사항 참조. 이미지로 해결 불가 |
| `[lms] ERROR: CUDA 백엔드가 libcudart.so.11.0 을 해석하지 못함` | cuda11fix 가 아닌 이미지를 로드함 | 2-4 ① 로 이미지 확인. 태그가 `-cuda11fix` 인지 볼 것 |
| 로그는 정상인데 `nvidia-smi` VRAM 0 | CPU 로 돌고 있음 | `LMS_REQUIRE_CUDA=1` 인지 확인. 0 이면 조용히 CPU 폴백된다 |
| 모델 로드 중 OOM / 컨테이너 죽음 | VRAM 부족 | `LMS_GPU` 를 낮춰 부분 offload, 또는 `LMS_BACKEND_COUNT=1` |
| 기동이 수 분간 멈춘 듯 보임 | 31B(17.6GiB) 로드 중 | `docker logs -f lms-1` 로 진행률 확인 |
| `lms get` 에서 수 분 hang | 폐쇄망에서 허브 조회 시도 | `.env` 의 `LMS_SKIP_GET=1` 확인 |
| chat 응답의 `content` 가 빈 문자열 | reasoning 토큰이 예산을 다 씀 | `max_tokens`/`CLAUDE_MAX_OUTPUT_TOKENS` ≥ 8192 |
| 다른 PC 에서 접속 불가 | 게이트웨이가 127.0.0.1 전용 | 2-7 의 `serve-lan.sh` 수행 |

# 관련 문서

* [상위 README](../README.md) — v2 전체 개요·단계 인덱스
* [cuda11fix/README.md](../cuda11fix/README.md) — CUDA 근본 원인·이미지 빌드·실기동 검증 결과
* [step4.cc_gw_lms2/README.md](../step4.cc_gw_lms2/README.md) — 서버 스택 상세·판정 게이트
* [step5.win_gw_lms2/README.md](../step5.win_gw_lms2/README.md) — Windows 클라이언트 수동 연결 매뉴얼
