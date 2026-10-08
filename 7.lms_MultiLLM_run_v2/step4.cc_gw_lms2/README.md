---
name: README
description: step4 — docker cc → gateway → lms-1, lms-2. 다중 백엔드 분산·세션 고정 검증
date: 2026-07-20
---

# 목적

```
                        ┌─→ lms-1:1234
[docker: claude] → gateway:8080 ─┤
                        └─→ lms-2:1234
```

step3 에서 게이트웨이 1:1 경로가 확정된 상태에서 **백엔드를 2개로 늘리는 것 하나만** 추가한다.

검증 대상:

* `X-Session` 헤더 consistent hash → **세션↔백엔드 고정(affinity)**
* affinity shim (PATH 선순위 `~/.local/bin/claude`) — `docker exec claude claude` 처럼 셸 미경유 진입에서도 헤더 보장
* GPU 전용 할당 (`--gpus "device=K"`) — `--gpus all` 을 N개에 주면 전원이 GPU0 에 적재됨
* VRAM 초과 구독 가드 (`LMS_ALLOW_GPU_OVERSUBSCRIBE`)

**이 단계를 통과한 `lms-gateway:latest` 와 `claude:latest` 가 폐쇄망 반입 대상 이미지다.**

## 왜 affinity 가 필수인가

요청 단위 라운드로빈이면 세션 후속 턴이 다른 백엔드에 떨어져 **전체 컨텍스트를 재프리필**한다. 30k 토큰 기준 6.2s vs 0.49s — **약 13배**(실측: `_doc_work/report/lms-affinity-test_report.md`). 에러 없이 느려지기만 해서 발견이 어렵다.

# 구현 방법

## 구성 파일

step3 구성 + 아래 차이:

| 파일 | 변경점 |
| :--- | :----- |
| `.env.org` | `LMS_BACKEND_COUNT=2` |
| `entrypoint.cc.sh` | **X-Session affinity 주입 추가** — `.bashrc`/`.profile` export + `~/.local/bin/claude` shim |
| `run.sh` | 백엔드 루프 N개 + GPU 전용 할당 + upstream 서버 목록 N줄 생성 |

> ⚠️ **`settings.json` 의 `env` 에 정적 `X-Session` 을 넣지 말 것.** settings.json 이 셸
> export 보다 우선하므로(실측), 정적 값을 넣으면 모든 세션이 한 백엔드에 고정되어 분산이
> 죽는다. shim 은 프로세스 환경변수만 세팅하므로 세션별 고유값이 유지된다.

> ⚠️ **GPU 초과 구독**: 백엔드 수 > GPU 수이면 `run.sh` 가 **기본적으로 정지**시킨다.
> 의도적일 때만 `LMS_ALLOW_GPU_OVERSUBSCRIBE=1` 로 강행. 31b@32k ×2 ≈ 44GB 는 A6000(48GB)
> 의 92% 로 83% 안전선을 초과 — 짧은 프롬프트는 통과하다 장문에서 죽는다.

## 실행 절차

> 컨테이너 이름은 `.env` 기준 **lms-1** / **lms-2** / **gateway** / **cc-step4**.

```bash
cd step4.cc_gw_lms2
cp .env.org .env && vi .env       # LMS_BACKEND_COUNT=2, LMS_GPU, 초과 구독 가드 검토

./run.sh
./run.sh --status

# 1) 도달·shim·VRAM 자동 판정
./run.sh --check

# 2) 분산 — 헤더 없는 요청이 두 백엔드에 나뉘는가
./run.sh --distribute

# 3) 세션 고정 — 같은 X-Session 이 한 백엔드에만 가는가
./run.sh --affinity

# 3-2) 세션 키가 두 백엔드에 '모두' 배정되는가  ← 아래 주의 참조
./run.sh --spread

# 4) SSE / 재기동 내성
./run.sh --sse
./run.sh --resilience

# 5) 동시 2세션 (각각 다른 X-Session 으로 서로 다른 백엔드에 붙는지)
docker exec -it cc-step4 bash   # 터미널 A → cc
docker exec -it cc-step4 bash   # 터미널 B → cc
```

> ⚠️ **`--affinity` 만으로는 부족하다.** 그것은 "한 세션이 한 백엔드에 고정"만 본다.
> **모든 세션이 한 백엔드로 몰리는 고장**(= 사실상 단일 백엔드, 나머지는 유휴)과 구분되지
> 않는다. 실제로 첫 실측에서 세션 키 2개가 **둘 다 lms-2** 로 갔다(2백엔드·2키면 우연히
> 같을 확률 50%). 반드시 `--spread` 로 여러 키를 돌려 양쪽이 모두 쓰이는지 볼 것.
>
> ⚠️ **consistent hash 는 라운드로빈이 아니다.** 세션 수가 적으면 배분이 고르지 않은 것이
> **정상**이다(실측: 8세션 → lms-1 2개 / lms-2 6개). 판정 기준은 '균등'이 아니라
> **'양쪽 모두 사용'**. 이 차이를 모르면 "lms-1 이 죽었다"고 오진하기 쉽다.

# 성공 판정 (게이트)

1. lms-1·lms-2 모두 `/v1/models` 200, 각각 다른 GPU(다중 GPU 환경) 또는 승인된 초과 구독 상태
2. **분산**: 헤더 없는 10회 요청이 두 백엔드에 나뉘어 도달 — `--distribute`
3. **세션 고정**: 동일 `X-Session` 10회가 **한 백엔드에만** 도달 — `--affinity`
3-2. **세션 배정 spread**: 여러 세션 키가 두 백엔드에 **모두** 배정 — `--spread`
4. `docker exec cc-step4 which claude` → `/home/ubuntu/.local/bin/claude` (shim 우선) + `settings.json` 에 정적 `X-Session` 없음
5. 동시 2세션에서 각각 정상 응답 + 후속 턴 지연이 초기 턴 대비 급증하지 않음(재프리필 없음)
6. VRAM 사용률 ≤ 83%

## 실측 결과 (fg1, 2026-07-20) — 전 게이트 통과

| 게이트 | 결과 |
| :----- | :--- |
| 1 두 백엔드 200 | ✅ |
| 2 분산 | ✅ 10건 → lms-1 +108줄 / lms-2 +72줄 |
| 3 세션 고정 | ✅ `affinity-A`·`affinity-B` 각각 단일 백엔드 |
| 3-2 spread | ✅ 8개 키 → lms-1 2개 / lms-2 6개 (**2/2 백엔드 사용**) |
| 4 shim | ✅ `/home/ubuntu/.local/bin/claude` · 정적 헤더 없음 |
| 5 동시 2세션 | ✅ `sessA`→lms-1 / `s2`→lms-2 (**서로 다른 백엔드**), 각각 완주 |
| 6 VRAM | ✅ 로드 후 **40.1%** (6,566/16,380), 부하 중 44.6% |
| + SSE | ✅ 112 청크 +1.08s ~ +2.12s 분산 도착 |
| + 재기동 내성 | ✅ **0s** 복구 |

# 실패 시 진단 순서

| 증상 | 확인 |
| :--- | :--- |
| 세션 고정이 안 됨(양쪽에 분산) | upstream 이 단일 `server lms:1234` 인지 확인 — `lms-1`,`lms-2` 개별 엔트리 필수 |
| 모든 세션이 한 백엔드에 고정 | `settings.json` 에 정적 `X-Session` 이 들어감 |
| lms-2 가 OOM | `--gpus all` 로 둘 다 GPU0 적재 — `device=K` 전용 할당 확인 |
| 후속 턴이 유독 느림 | affinity 무효 상태. 3번 판정으로 되돌아갈 것 |
