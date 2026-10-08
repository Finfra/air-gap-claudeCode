---
title: offline-scar/claude
description: 서버 99(DGX Spark) ~/.claude 에 additive 로 얹을 린 SCAR 소스 트리
date: 2026.10.08
---

# 이 폴더의 자리

`deploy-to-99.sh` 가 이 트리를 그대로 `admin@spark-1:~/.claude` 에 rsync 한다(삭제 없는 additive 배포). 그래서 하위 구조는 대상 `~/.claude` 의 구조(`rules/`·`commands/`)와 **같아야 한다**. 배경·배포 절차는 [상위 README](../README.md) 참조.

# 구성

| 경로                                                   | 역할                                                                                    |
| :----------------------------------------------------- | :-------------------------------------------------------------------------------------- |
| [rules/md-rules.md](rules/md-rules.md)                 | 마크다운 규약 — 프런트매터·아웃라인·불릿·표. `base-rules` 상속                          |
| [rules/offline-exec-rules.md](rules/offline-exec-rules.md) | 단독망 실행 규율 — 인터넷 시도 금지·종료 조건·재시도 1회·상한·무거운 작업 라우팅·승인 |
| [commands/plan.md](commands/plan.md)                   | `/plan` — needs 를 Plan 문서로 구체화(nPTiR n→P 진입), 이후 `/issue-reg` 로 연결        |

# 작성 규약

* 각 파일은 서버 99 에 **이미 있는** 자산을 참조한다 — `base-rules`·`doc-design-rules`·`nptir-flow` 등. 이 폴더에 없다고 깨진 링크가 아니다
* 서버에 이미 있는 자산과 **같은 이름의 파일을 두지 않는다** — additive 배포라 덮어쓰기가 된다
* 로컬 모델(`f-ollama`)의 작은 컨텍스트를 전제로 짧게 쓴다 — 룰 1개가 한 화면을 넘지 않게
