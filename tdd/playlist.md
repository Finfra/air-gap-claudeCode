---
title: air-gap-claudeCode TDD 재생목록
description: prj91 air-gap-claudeCode 의 TDD 목표를 재생 순서로 나열한 목록 (prj6#Issue16)
date: 2026.09.26
---

# 무엇을 지키나

폐쇄망 Claude Code+로컬 LLM Docker 예제들이 env 외부화 설정대로 기동되고 컨테이너 간 추론 경로가 종단까지 동작함을 지킨다

* 기존 러너: `bash ~/_git/__all/air-gap-claudeCode/2.ollama_TwoContainer/test-setup.sh (기동 후 수동 실행)`
* 목표 7개 중 기존 테스트로 덮인 것 3개 · 신규 4개

# 재생목록

위에서 아래로 돈다 — 빠르고 기초적인 것이 먼저, 통합·E2E 가 뒤다. 앞 항목이 깨지면 뒤 항목의 실패는 원인이 아니라 결과일 수 있다.

| # | id | 목표 | 근거 | 실행 | 상태 |
| :- | :- | :- | :- | :- | :- |
| 1 | `compose-config-examples` | 1.ollama_OneContainer·2.ollama_TwoContainer·3.ollama_External 의 docker compose config 가 통과한다 | Issue12 검증 — docker compose config 3개 예제 모두 통과 | — | ⬜ 신규 |
| 2 | `entrypoint-syntax` | entrypoint 스크립트가 bash -n 문법 검사를 통과한다 | Issue12 bash -n entrypoint.sh OK | — | ⬜ 신규 |
| 3 | `env-externalized` | .env.org 로부터 만든 .env 값(COMPOSE_PROJECT_NAME·컨테이너명·포트·TZ=Asia/Seoul·OLLAMA_KV_CACHE_TYPE=q8_0·USER_UID)이 compose config 출력에 반영되고 두 예제 KV cache 가 같다 | Issue4 .env.org 템플릿; Issue7~10 외부화 (config 출력 검증 기록) | — | ⬜ 신규 |
| 4 | `ollama-mount-toggle` | OLLAMA_MOUNT 미설정 시 named volume ollama-models, 설정 시 호스트 경로가 /root/.ollama 로 마운트되고 MOUNT_CODE_DIR override 가 적용된다 | Issue2 OLLAMA_MOUNT 공유/비공유; Issue3 docker-compose.code.yml override | — | ⬜ 신규 |
| 5 | `two-container-runtime` | TwoContainer 기동 후 ollama·claude 컨테이너 실행, Ollama API 응답, 모델 존재, claude→ollama 네트워크 연결, ubuntu 유저 환경 5단계가 통과한다 | 2.ollama_TwoContainer/test-setup.sh [1/5]~[5/5] | `bash 2.ollama_TwoContainer/test-setup.sh` | ✅ 기존 |
| 6 | `lms-multi-gateway` | lms 2백엔드 기동 시 모델 로드(CONTEXT 131072)·게이트웨이 분산·사용중/유휴 판별·32k 초과 needle·Claude Code 종단이 기대값대로 나온다 | 5.lms_MultiLLM/TEST.md 0)~5) (2026-07-16 실기동 기대값) | `5.lms_MultiLLM/TEST.md 수동 절차` | ✅ 기존 |
| 7 | `lms-session-affinity-diet` | 6.lms_MultiLLM_run 에서 X-Session 헤더 세션이 같은 백엔드에 고정되고 CLAUDE_DIET=1 프롬프트 다이어트가 적용된다 | 6.lms_MultiLLM_run/TEST.md 6) 세션 고정·7) 프롬프트 다이어트 (2026-07-17 패치) | `6.lms_MultiLLM_run/TEST.md 수동 절차` | ✅ 기존 |

# 규약

* **목표는 «검증 가능한 성질»** 이다 — *"잘 동작한다"* 는 목표가 아니다
* 새 버그를 고치면 **재현 테스트를 먼저** 여기 한 줄로 올리고(⬜), 테스트가 생기면 실행 열을 채워 ✅ 로 바꾼다
* 실패를 삼키는 패턴(`2>/dev/null || true` 등)을 테스트 안에 쓰지 않는다 — 실패는 실패로 드러나야 한다
* 판정 출처: prj6 `_doc_work/report/tdd-coverage_report.md` (이 프로젝트가 왜 TDD 대상인가)
