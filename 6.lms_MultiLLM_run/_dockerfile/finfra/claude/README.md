---
name: README
description: finfra/claude — step1~5 공용 Claude Code 클라이언트 이미지. 백엔드 주소를 굽지 않고 런타임 주입
date: 2026-07-20
---

# 목적

step1~4 가 각자 `Dockerfile.claude` 를 복제해 **`ANTHROPIC_BASE_URL` 한 줄만 다른** 이미지를 따로 만들던 것을
하나로 합친다. 백엔드 주소는 이미지에 굽지 않고 런타임에 주입하므로, 같은 이미지가 아래 5개 경로를 모두 커버한다.

| 단계  | 경로                              | 주입 방식                                     |
| :---- | :-------------------------------- | :-------------------------------------------- |
| step1 | cc → 호스트 lms                   | `-e LMS_HOST=host.docker.internal`            |
| step2 | cc → docker lms                   | `-e LMS_HOST=lms -e LMS_PORT=1234`            |
| step3 | cc → gateway → lms                | `-e GW_HOST=gateway -e GW_PORT=8080`          |
| step4 | cc → gateway → lms-1/lms-2        | 위와 동일 (+ X-Session affinity 기본 활성)    |
| step5 | 원격 클라이언트 → 서버 gateway    | `-e CC_BASE_URL=http://<서버IP>:8080`         |

step5 는 원래 Windows 수동 설정이지만, **배포할 `settings.json` 을 이 이미지가 출력**한다(아래 참조).
손으로 관리하던 `settings.json.sample` 이 컨테이너 실제 설정과 어긋나는 문제를 없앤다.

# 빌드

```bash
./build.sh                        # 최신 claude-code → finfra/claude:latest + 게이트 판정
./build.sh --version 2.1.215      # 버전 고정 (반입본은 반드시 고정할 것)
./build.sh --tag claude:latest    # 기존 step1~4 스크립트 호환 태그 동시 부여
./build.sh --save                 # _img/finfra-claude.tar + .sha256 (폐쇄망 반입용)
./build.sh --check                # 빌드 없이 현재 이미지만 판정
```

빌드는 인터넷이 필요하다(nodesource·npm). 폐쇄망에서는 `--save` 로 만든 tar 를 반입해 `docker load -i` 한다.
`USER_UID/GID` 는 빌드 실행 사용자에 자동으로 맞춘다 — 코드 디렉토리를 마운트했을 때 root 소유 파일이 생기는 것을 막는다.

# 주입 파라미터

| 변수                              | 기본값                 | 역할                                                       |
| :-------------------------------- | :--------------------- | :--------------------------------------------------------- |
| `CC_BASE_URL`                     | (빈값)                 | 전체 URL 직접 지정. **최우선** — step5·원격 LAN 용         |
| `GW_HOST` / `GW_PORT`             | — / `8080`             | 게이트웨이 경유 (step3·step4)                              |
| `LMS_HOST` / `LMS_PORT`           | — / `1234`             | LMS 직결 (step1·step2)                                     |
| `CC_MODEL`                        | `ANTHROPIC_MODEL`→`LMS_MODEL` | 모델 키. **로컬 키**를 쓸 것(허브 키는 폴백 유발)   |
| `ANTHROPIC_AUTH_TOKEN`            | `lms`                  | 더미 토큰(값 무관, 존재만 하면 됨)                         |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS`   | `8192`                 | 기본값(≈32k)은 컨텍스트를 넘겨 500                         |
| `API_TIMEOUT_MS`                  | `600000`               | 로컬 추론은 느리다                                         |
| `CLAUDE_DIET`                     | `1`                    | 프롬프트 다이어트(도구 축소). `0` 이면 전체 도구           |
| `CC_AFFINITY`                     | `1`                    | X-Session 세션 고정. 백엔드 1개면 무해, 2개 이상이면 필수  |
| `CC_WAIT` / `CC_WAIT_TRIES`       | `1` / `30`             | 기동 시 백엔드 도달 확인(2초 간격). `0` 이면 생략          |

주소 결정 우선순위: `CC_BASE_URL` > `ANTHROPIC_BASE_URL` > `GW_HOST` > `LMS_HOST` > `http://gateway:8080`.

# step5 (원격 클라이언트) 설정 출력

컨테이너를 띄우지 않고 `settings.json` 만 뽑는다:

```bash
docker run --rm \
  -e CC_BASE_URL=http://192.168.0.4:8080 \
  -e CC_MODEL=gemma-4-e2b-it \
  finfra/claude:latest settings > settings.json
```

Windows 는 이 파일을 `%USERPROFILE%\.claude\settings.json` 에 둔다.
**저장 인코딩은 UTF-8(BOM 아님)** — BOM 이면 Claude Code 가 읽지 못한다(이전 반입 실패 원인).
기존 설정이 있으면 덮어쓰지 말고 `.bak` 백업 후 `model`·`env`·`permissions` 를 병합할 것.
자세한 매뉴얼은 [step5 README](../../../step5.win_gw_lms2/README.md).

# 설계 결정

* **백엔드 주소를 이미지에 굽지 않는다** — 구우면 단계마다 이미지를 다시 빌드해야 하고, 실제 접속처와
  다른 값이 이미지에 남아 오진을 부른다. `build.sh --check` 의 게이트 2 가 이 조건을 강제한다.
* **X-Session 을 `settings.json` 에 넣지 않는다** — settings.json 의 `env` 가 셸 export 보다 우선하므로
  (실측), 정적 값이면 모든 세션이 한 백엔드에 고정되어 분산이 죽는다. rc 파일 export + PATH shim 두
  경로만 쓴다.
* **PATH 선두를 `~/.local/bin` 으로 이미지에 박는다** — `docker exec <cc> claude` 처럼 셸을 거치지 않는
  진입에서도 affinity shim 이 잡히게 한다. 단계 스크립트가 `-e PATH=...` 를 잊어도 동작한다.
* **WebSearch/WebFetch 는 `CLAUDE_DIET=0` 으로도 열리지 않는다** — 폐쇄망에서 외부망 도구를 켜두면
  모델이 호출→실패→재시도 루프에 빠진다.

# 성공 판정 (게이트)

`./build.sh --check` 가 1~5 를 자동 판정한다.

| 게이트 | 내용                                                        |
| :----- | :---------------------------------------------------------- |
| 1      | `claude --version` 실행                                      |
| 2      | `ANTHROPIC_BASE_URL` 이 이미지에 구워져 있지 **않을** 것     |
| 3      | PATH 선두 = `/home/ubuntu/.local/bin` (shim 보장)            |
| 4      | `settings` 출력이 유효 JSON · base_url 반영 · WebSearch deny |
| 5      | 기본 유저 = `ubuntu` (비루트)                                |

실기 판정(백엔드 필요)은 위 5개로 커버되지 않는다 — 아래를 수동 확인한다.

| 게이트 | 확인                                                                        |
| :----- | :-------------------------------------------------------------------------- |
| 6      | `docker logs <cc>` 에 `backend is up`                                        |
| 7      | `docker exec <cc> bash -lc 'claude --dangerously-skip-permissions -p "Reply with exactly: PONG"'` |

## 실측 결과 (fg1, 2026-07-20)

claude-code **2.1.215**, 이미지 684MB. step4 스택(gateway + lms-1 + lms-2) 가동 중 검증.

| 게이트                 | 결과                                              |
| :--------------------- | :------------------------------------------------ |
| 1~5 (`--check`)        | ✅ 전 게이트 통과                                  |
| 6 컨테이너 경유(step4) | ✅ `GW_HOST=gateway` → `backend is up`             |
| 7 1턴(step4 경로)      | ✅ `PONG`                                          |
| 6 LAN 직결(step5 경로) | ✅ `CC_BASE_URL=http://192.168.0.4:8080` (네트워크 밖) |
| 7 1턴(step5 경로)      | ✅ `PONG`                                          |
| settings 출력          | ✅ step5 `settings.json.sample` 과 키 구성 일치     |

> step5 의 **Windows 실기**는 여전히 미검증이다. 위 LAN 검증은 리눅스 컨테이너에서 LAN IP 로 붙은 것으로,
> Windows 방화벽·프록시·인코딩 문제는 이 검증이 커버하지 않는다.

# 실패 시 진단

| 증상                                        | 확인                                                                       |
| :------------------------------------------ | :------------------------------------------------------------------------- |
| `host not resolvable` 경고                  | `--network` 누락 또는 `GW_HOST` 오타. step5 면 `CC_BASE_URL` 을 쓸 것       |
| `backend unreachable after 60s`             | 게이트웨이/LMS 미기동. `curl <BASE_URL>/v1/models` 로 직접 확인             |
| 502                                         | 게이트웨이는 살아 있고 백엔드가 죽음 — `docker ps` 로 lms-* 확인            |
| 500                                         | `LMS_PARALLEL` 이 1 이 아니거나 컨텍스트 < 32768 (백엔드 쪽 문제)           |
| `model not found`                           | `CC_MODEL` 이 `/v1/models` 의 `id` 와 불일치. 허브 키가 아니라 로컬 키      |
| 응답은 되는데 매 턴 느림(백엔드 2개 이상)   | affinity 미적용 — `docker exec <cc> which claude` 가 `~/.local/bin/claude` 인지 |
| 빌드가 npm 에서 멈춤                        | 폐쇄망에서 빌드 시도 중 — 인터넷 망에서 `--save` 후 tar 반입                |
