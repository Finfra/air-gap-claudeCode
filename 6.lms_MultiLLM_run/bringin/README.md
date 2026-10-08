---
name: README
description: 단독망(air-gap) 반입 절차 — docker 이미지 export→매체→load. step1~5 는 검증 프레임워크, 이 폴더는 실제 반입 아티팩트 준비/적재 담당
date: 2026-07-21
---

# 목적

step1~5 는 **스택이 올바른지 검증**하는 프레임워크다. 하지만 각 `run.sh` 는 **이미지가 이미
`docker load` 돼 있다고 전제**한다(없으면 `이미지 없음 — docker load -i <tar>` 로 중단). 단독망엔
인터넷·레지스트리가 없으므로, 그 이미지를 **온라인에서 tar 로 떠서 매체로 옮겨 적재**하는 절차가
따로 있어야 한다. 이 폴더가 그 역할이다. (cf_old 의 `_img/*.tar` + `SHA256SUMS` + `docker load`
패턴을 현재 step 구조·`lms:small` 기준으로 각색.)

* 온라인(빌드) 측: [export.sh](export.sh) — 이미지 → `_img/*.tar` + `SHA256SUMS`(+ 매체 초과 시 분할)
* 단독망 측: [load.sh](load.sh) — 검증 → 재조립 → `docker load` → 태그 확인
* 이미지 태그는 [../step4.cc_gw_lms2/.env](../step4.cc_gw_lms2/.env) 를 읽어 `run.sh` 가 찾는 값과
  자동 일치시킨다(어긋날 여지 제거).

# 무엇을 반입하는가

| 이미지 (step4/.env) | 크기(실측) | 내용 | 모델 |
| :------------------ | :--------- | :--- | :--- |
| `lms:small`         | **~29GB**  | LMS 백엔드 + CUDA 런타임 + **모델 내장** | gemma-4-e2b (Q4_K_M) 내장 |
| `lms-gateway:latest`| ~213MB     | nginx 게이트웨이 | — |
| `claude:latest`     | ~684MB     | Claude Code CLI | — |

* **모델은 `lms:small` 에 내장** — 별도 gguf 반입 불필요. 컨테이너가 named volume 을 새로
  마운트하면 docker 가 이미지 내장 모델을 볼륨에 자동 프리팝한다.
* A6000(48GB) 반입에 31b 모델을 쓸 경우엔 `lms:latest`(24.7GB, 31b 내장)를 대상으로 바꾼다 —
  step4/.env 의 `LMS_IMAGE` 를 `lms:latest` 로 두면 export.sh 가 그걸 내보낸다.

# ⚠️ 매체 크기 현실 (먼저 읽을 것)

`lms:small` **한 개가 29GB** 라 **DVD 1장(4.7GB)에 들어가지 않는다.** 선택지:

| 매체 | 처리 | 명령 |
| :--- | :--- | :--- |
| **BD-R DL 50GB 1장** (권장) | 통짜로 담김 | `MEDIA_BYTES=50000000000 ./export.sh` |
| 외장 SSD/USB | 분할 불필요 | `MEDIA_BYTES=0 ./export.sh` |
| DVD 여러 장 | `lms:small` tar 를 4.7GB 조각(`.partNN`)으로 자동 분할 → 매체 7장 내외 | `./export.sh`(기본) |

* DVD 다장 방식은 `_img/*.tar.part00, part01, …` 를 여러 장에 나눠 굽고, 단독망에서 **같은 `_img/`
  폴더로 다시 모으면** `load.sh` 가 `cat` 으로 이어붙인다.
* export.sh 가 시작 시 총량·필요 매체 수를 계산해 출력하므로, 굽기 전에 매체를 정한다.

# 절차

## 1. 온라인(빌드) 호스트 — export

```bash
cd 6.lms_MultiLLM_run/bringin
./export.sh --list        # 무엇을·몇 장 나올지 먼저 확인(save 안 함)
./export.sh               # 기본: DVD 4.7GB 분할 / 또는 위 표의 MEDIA_BYTES 지정
```

산출: `_img/*.tar`(또는 `*.tar.partNN`) + `_img/SHA256SUMS` + `_img/MANIFEST.txt`.

## 2. 매체 굽기

* **6.lms_MultiLLM_run 폴더 전체**를 매체에 담는다(step1~5 스크립트·문서·`bringin/` 포함 → 외부
  의존 없음).
* tar 가 매체보다 크면 `_img/` 의 조각을 여러 매체에 분산. 나머지 스크립트·문서는 첫 매체에.

## 3. 단독망 호스트 — load

```bash
# (매체에서 6.lms_MultiLLM_run 을 통째 복사한 뒤)
cd 6.lms_MultiLLM_run/bringin
./load.sh                 # SHA256 검증 → (분할본 재조립) → docker load → 태그 확인
```

전제(단독망): **docker 엔진** + (GPU 사용 시) **NVIDIA 드라이버 + nvidia-container-toolkit**.

## 4. 스택 기동 (step4) · 클라이언트 (step5)

```bash
cd ../step4.cc_gw_lms2
cp .env.org .env && vi .env      # LMS_BACKEND_COUNT 를 GPU 장수에 맞춤(1장이면 1)
./run.sh
./run.sh --check                 # 도달·shim·VRAM 판정
```

* Windows 클라이언트 연결: [../step5.win_gw_lms2/README.md](../step5.win_gw_lms2/README.md).
* jinja 오류(설치만으론 안 붙음): [../info_jinja_manual_setup.md](../info_jinja_manual_setup.md).
* lms 백엔드가 끝내 안 되면: [../fallback.gw_ollama/README.md](../fallback.gw_ollama/README.md).

# 모델/이미지 재생성 (필요 시)

`lms:small` 을 다시 만들어야 하면(모델 교체·손상) 빌드 레시피는 cf_old 에 보존돼 있다 — 현재
구조에 맞게 참고만:

* [../cf_old/Dockerfile.small](../cf_old/Dockerfile.small) — `FROM lms:latest` + `COPY models/` (모델 내장)
* [../cf_old/build.small.sh](../cf_old/build.small.sh) — `build.small/models/` 에 gguf 두고 빌드
* gguf 원본: [../cf_old/build.small/models/](../cf_old/build.small/models/) (gemma-4-E2B-it Q4_K_M + mmproj)

> cf_old 는 참조 전용(실행 금지). 재빌드는 온라인 호스트에서 하고, 결과 이미지를 export.sh 로 반입한다.

# 체크리스트 (반입 완료 기준)

- [ ] 온라인: `./export.sh` 성공 — `_img/SHA256SUMS` 존재, 대상 3개 tar(또는 분할본) 생성
- [ ] 매체: 6.lms_MultiLLM_run 전체 + `_img/` 조각 전량 담김
- [ ] 단독망: `./load.sh` — SHA256 전 항목 일치, 태그 3종 `docker image inspect` 통과
- [ ] `step4.cc_gw_lms2/run.sh` 기동 + `--check` 통과
- [ ] (jinja 오류 시) [../info_jinja_manual_setup.md](../info_jinja_manual_setup.md) 절차로 해소
