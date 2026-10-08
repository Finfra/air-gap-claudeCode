---
title: tdd/cases
description: TDD 재생목록 1~4번(자동)의 테스트 실물과 공통 헬퍼
date: 2026.10.08
---

# 이 폴더의 자리

[재생목록](../playlist.md)의 자동 목표(1~4)를 검증하는 bash 스크립트 모음. 러너 [run.sh](../run.sh) 가 재생 순서대로 `<id>.sh` 를 실행한다. 5~7번(기동 필요·수동)은 기존 테스트를 가리키므로 여기에 없다.

# 구성

| 파일                                                     | 재생 # | 검증 내용                                                                                   |
| :------------------------------------------------------- | :----- | :------------------------------------------------------------------------------------------ |
| [compose-config-examples.sh](compose-config-examples.sh) | 1      | ollama 예제 3개(One·Two·External)의 `docker compose config` 가 `.env.org` 기준으로 통과     |
| [entrypoint-syntax.sh](entrypoint-syntax.sh)             | 2      | 추적 중인 `entrypoint*.sh` 전부가 `bash -n` 통과                                             |
| [env-externalized.sh](env-externalized.sh)               | 3      | `.env.org` 값이 config 출력에 반영되고, 값 변경이 실제로 전파되며, One·Two KV cache 가 동일 |
| [ollama-mount-toggle.sh](ollama-mount-toggle.sh)         | 4      | `OLLAMA_MOUNT` 미설정·격리·공유(경로·`~`)별 마운트 형태, `MOUNT_CODE_DIR` override 적용     |
| [lib.sh](lib.sh)                                         | —      | 공통 헬퍼 (아래)                                                                            |

# 실행

```bash
bash tdd/run.sh                      # 1~4 전체 (재생 순서)
bash tdd/run.sh env-externalized     # 한 케이스만
```

* 전제: `docker` CLI(compose v2)·`jq`(3·4번). **데몬 기동·이미지 빌드 불필요** — `docker compose config` 렌더만 쓴다
* bash 3.2(macOS)·GNU(fg1) 양쪽에서 동작하도록 작성 — 연관 배열·`sed -i` 를 쓰지 않는다

# lib.sh 헬퍼

| 함수                                 | 설명                                                                           |
| :----------------------------------- | :----------------------------------------------------------------------------- |
| `make_env <예제> [K=V ...] [-K ...]` | `.env.org` 를 임시 복사해 키 치환·추가(`K=V`)·삭제(`-K`) 후 경로 출력          |
| `compose_json <예제> <env> [-f ...]` | 해당 예제의 compose config 를 JSON 으로 렌더 (추가 override 파일 지정 가능)    |
| `expect_eq <라벨> <실제> <기대>`     | 비교 후 ✅·❌ 출력                                                              |
| `pass`·`fail`·`finish`               | 결과 기록, `finish` 가 PASS(0)·FAIL(1) 로 종료                                 |

* 사용자 로컬 `.env` 는 **읽지 않는다** — 머신마다 달라 판정이 흔들린다. 항상 추적 템플릿 `.env.org` 기준
* 임시 파일은 `mktemp -d` 아래에 만들고 `trap` 으로 정리

# 케이스 추가 규약

* 파일명 = 재생목록 `id` (`<id>.sh`), 첫 줄 주석에 `# 목표 N: ...`
* `source "$(dirname "$0")/lib.sh"` 로 시작해 `finish` 로 끝낸다
* 실패를 삼키지 않는다 — `2>/dev/null || true` 금지 ([재생목록 규약](../playlist.md))
* 추가 후 [playlist.md](../playlist.md) 에 한 줄 올리고 실행 열을 채운다
