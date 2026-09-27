---
title: tdd
description: prj91 air-gap-claudeCode TDD 폴더 — 재생목록과 테스트 실물의 자리 (prj6#Issue16)
date: 2026.09.26
---

# 구조

| 경로 | 내용 |
| :--- | :--- |
| [playlist.md](playlist.md) | **재생목록** — 무엇을 어떤 순서로 검증하나 |
| [run.sh](run.sh) | 러너 — 재생 순서대로 `cases/*.sh` 실행. 인자로 id 를 주면 그 케이스만 |
| `cases/` | 목표별 테스트 실물(`<id>.sh`) + 공통 헬퍼 `lib.sh`. 기존 테스트 타깃이 있으면 새로 만들지 말고 재생목록 실행 열에서 가리킨다 |

* 형식 선례: prj1 `tdd/`(케이스 yml + 러너) · prj7 `tdd/`(파이프라인 E2E 카드)
