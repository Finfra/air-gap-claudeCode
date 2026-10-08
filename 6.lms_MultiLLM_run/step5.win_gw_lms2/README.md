---
name: README
description: step5 — Windows Claude Code → gateway → lms-1, lms-2. 스크립트 없이 설정 파일 + 수동 매뉴얼로 연결
date: 2026-07-20
---

# 목적

```
[Windows PC: Claude Code] ──LAN──→ 서버:8080(gateway) ──→ lms-1 / lms-2
```

step4 에서 서버 내부 스택이 확정된 상태에서 **클라이언트를 Windows 로 바꾸는 것 하나만** 추가한다.

검증 대상:

* 게이트웨이 포트의 LAN 노출 (`0.0.0.0` 바인딩)
* Windows 방화벽·프록시 통과
* Windows `%USERPROFILE%\.claude\settings.json` 구성

> **서버 스택은 step4 의 것을 그대로 쓴다.** step5 는 별도 스택을 세우지 않으며,
> `.env` 도 step4 의 것을 읽는다. lms-1·lms-2 는 **계속 실행 중이어야 한다.**

# ⚠️ PowerShell 스크립트를 쓰지 않는다

이전 반입에서 `vscode-connect.ps1` 이 오동작하여 실패 원인 1순위가 되었음. 폐쇄망 Windows 에서 재현된 문제:

* 실행 정책(`ExecutionPolicy`)으로 스크립트 자체가 차단됨 — 정책 변경은 보안 통제상 불가한 경우가 많음
* PowerShell 5.1 의 JSON 병합 시 기존 사용자 설정이 유실
* UTF-8 BOM 기록으로 `settings.json` 파싱 실패 (에러 메시지가 불명확)

**대체 방식**: 검토·복사 가능한 **설정 파일 원본** + 사람이 그대로 따라 하는 **매뉴얼**. Windows 에서 실행되는 자동화 코드는 두지 않는다. 되돌리기는 백업 파일을 되돌려 놓는 것으로 끝난다.

> 폐기한 스크립트는 [cf_old/vscode-connect.ps1](../cf_old/vscode-connect.ps1) 에 보존(참조 전용, 실행 금지).
> 아래 매뉴얼은 그 스크립트가 다루던 범위(키 5종 병합·`.bak` 백업·BOM 없는 저장·되돌리기·상태 확인)를
> 모두 사람이 수행할 수 있게 옮긴 것이다.

# 구현 방법

## 구성 파일

| 파일                   | 실행 위치       | 역할                                                                               |
| :--------------------- | :-------------- | :--------------------------------------------------------------------------------- |
| `serve-lan.sh`         | **서버(Linux)** | 게이트웨이만 `0.0.0.0` 으로 재공개. **백엔드는 건드리지 않음**. 판정·되돌리기 포함 |
| `settings.json.sample` | Windows         | `%USERPROFILE%\.claude\settings.json` 원본. `<서버IP>`·`<모델키>` 2곳만 치환       |
| (이 README)            | —               | 수동 적용 매뉴얼                                                                   |

# 1단계 — 서버 측 준비 (Linux, 1회)

게이트웨이는 기본이 `127.0.0.1` 전용이라 그대로면 Windows 에서 **절대** 닿지 않는다.

```bash
cd step5.win_gw_lms2
./serve-lan.sh            # gateway 만 0.0.0.0 으로 재공개 + Windows 용 설정값 출력
./serve-lan.sh --check    # 게이트 A/B/C 판정
```

`serve-lan.sh` 가 하는 일:

1. **step4 백엔드 생존 확인** — lms-1..N 이 죽어 있으면 여기서 중단한다. 백엔드가 죽은 채로 게이트웨이만 열면 Windows 에서 502 를 보고 "Windows 문제"로 오진하게 된다
2. **gateway 컨테이너만 재생성** — docker 는 실행 중 컨테이너의 포트 publish 를 바꿀 수 없어 재생성이 유일한 방법이다. gateway 는 무상태라 비용이 없고, **lms 는 모델 재로드가 필요하므로 손대지 않는다**
3. 서버 LAN IP 자동 탐지 → Windows 에 붙여넣을 `settings.json` 을 실제 값으로 출력

> ⚠️ 게이트웨이·LMS 의 `/v1` 은 **무인증**이다(토큰 `lms` 는 형식상). 폐쇄망 또는 신뢰 LAN
> 전제에서만 공개할 것. 필요하면 방화벽에서 접속 대역을 제한한다.

되돌리기(호스트 내부 전용으로 복귀):

```bash
./serve-lan.sh --revert
```

# 2단계 — Windows 측 적용 (수동)

## 2-1. 도달 확인 (설정보다 먼저)

PowerShell 또는 명령 프롬프트에서:

```
curl.exe http://<서버IP>:8080/v1/models
```

* Windows 10 1803+ 는 `curl.exe` 기본 포함. **`.exe` 를 반드시 붙일 것** — 그냥 `curl` 은 PowerShell 에서 `Invoke-WebRequest` 별칭이라 문법이 다르다
* 모델 목록 JSON 이 나와야 다음으로 진행한다. 여기서 실패하면 settings.json 을 아무리 고쳐도 소용없다

## 2-2. 폴더 준비

탐색기 주소창에 `%USERPROFILE%\.claude` 입력. 없으면 새 폴더로 생성한다.

## 2-3. 기존 설정 백업

`settings.json` 이 이미 있으면 **반드시** `settings.json.bak` 으로 **복사**해 둔다(이동 아님).

## 2-4. 설정 파일 작성

`settings.json.sample` 을 메모장으로 열어 2곳을 치환하고, `%USERPROFILE%\.claude\settings.json` 으로 저장한다.

| 치환 대상  | 값                                 | 확인 방법                      |
| :--------- | :--------------------------------- | :----------------------------- |
| `<서버IP>` | 게이트웨이 서버의 LAN IP           | 서버에서 `./serve-lan.sh` 출력 |
| `<모델키>` | `/v1/models` 응답의 `id` 값 그대로 | 2-1 의 curl 결과               |

각 키의 의미:

| 키                                         | 역할                                            | 생략하면                                                      |
| :----------------------------------------- | :---------------------------------------------- | :------------------------------------------------------------ |
| `model`                                    | 사용할 모델 키                                  | 모델 불일치로 요청 실패                                       |
| `ANTHROPIC_BASE_URL`                       | 게이트웨이 주소                                 | 실제 Anthropic 으로 나감(폐쇄망에서 실패)                     |
| `ANTHROPIC_AUTH_TOKEN`                     | 더미 토큰(값 무관, 존재만 하면 됨)              | 인증 오류                                                     |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS`            | 출력 상한 8192                                  | 기본값(≈32k)이 컨텍스트를 넘겨 500                            |
| `API_TIMEOUT_MS`                           | 10분 — 로컬 추론은 느리다                       | 긴 응답에서 타임아웃                                          |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | 외부망 잡음 차단                                | 폐쇄망에서 불필요한 재시도                                    |
| `permissions.deny`                         | 프롬프트 다이어트(도구 축소) + 외부망 도구 차단 | 프롬프트가 커져 느려짐. **WebSearch/WebFetch 는 반드시 유지** |

> **저장 시 인코딩 주의**: 메모장 → 다른 이름으로 저장 → 인코딩을 **`UTF-8`** 로 선택.
> `UTF-8 (BOM)` 을 고르면 Claude Code 가 파일을 읽지 못한다. **이전 반입 실패의 직접 원인 중 하나.**
>
> **기존 설정이 있었다면 덮어쓰지 말 것.** `.bak` 의 내용과 샘플의 `model`·`env`·`permissions` 를
> 합쳐 하나의 JSON 으로 만든다. JSON 최상위에 키가 중복되면 안 된다.

## 2-5. 연결 확인

**새 터미널을 열고**(기존 터미널은 환경이 갱신되지 않음):

```
claude
```

VSCode 확장을 쓰는 경우: 명령 팔레트(`Ctrl+Shift+P`) → **Developer: Reload Window**

## 2-6. 되돌리기

`settings.json` 을 지우고 `settings.json.bak` 을 `settings.json` 으로 되돌린다. 백업이 없었다면(원래 파일이 없었다면) `settings.json` 을 삭제하면 된다.

# 성공 판정 (게이트)

**서버 측** — `./serve-lan.sh --check`

| 게이트 | 내용                                                                                   |
| :----- | :------------------------------------------------------------------------------------- |
| 전제   | lms-1·lms-2 실행 중                                                                    |
| A      | 게이트웨이 publish 가 `0.0.0.0:8080`                                                   |
| B      | 서버가 **자기 LAN IP** 로 `/v1/models` 200 (여기서 실패하면 Windows 에서도 절대 안 됨) |
| C      | 방화벽 8080/tcp 인바운드 허용                                                          |

**Windows 측** — 수동

1. `curl.exe http://<서버IP>:8080/v1/models` → 모델 목록 JSON 수신
2. `claude` 실행 → 1턴 응답 성공
3. Windows 세션 2개를 동시에 띄웠을 때, 서버에서 두 백엔드에 각각 붙는 것 확인:
    ```bash
    # 서버에서
    docker logs --since 2m lms-1 | wc -l ; docker logs --since 2m lms-2 | wc -l
    ```
    > ⚠️ consistent hash 는 라운드로빈이 아니다 — 세션 2개가 **우연히 같은 백엔드**에 갈 수 있다
    > (2백엔드·2세션이면 50%). 한쪽으로 몰렸다고 곧바로 고장이 아니다. 세션을 더 늘려 보거나
    > step4 의 `./run.sh --spread` 결과를 근거로 삼을 것
4. 되돌리기 절차로 원래 설정이 복구됨

# 실측 결과 (fg1, 2026-07-20)

서버 측 게이트만 완료. **Windows 측은 실기 검증 대기.**

| 게이트             | 결과                                               |
| :----------------- | :------------------------------------------------- |
| 전제 lms-1·lms-2   | ✅ 실행 중(게이트웨이 재생성 중에도 유지됨)         |
| A `0.0.0.0` 바인딩 | ✅ `8080/tcp -> 0.0.0.0:8080`                       |
| B 자기 LAN IP 접근 | ✅ 200 `gemma-4-e2b-it` (`http://192.168.0.4:8080`) |
| C 방화벽           | ✅ ufw inactive — 차단 없음                         |
| Windows 1~4        | 🚧 **미검증** — Windows 실기 필요                   |

> plan 원칙: **Windows 실기 검증 없이는 미통과로 명시하고 반입하지 않는다.**

# 실패 시 진단

| 증상                            | 확인                                                                                      |
| :------------------------------ | :---------------------------------------------------------------------------------------- |
| Windows curl 이 타임아웃        | 서버 방화벽 8080 인바운드 차단 — `sudo ufw allow 8080/tcp` 또는 사이트 정책               |
| 연결 거부(refused)              | 게이트웨이가 `127.0.0.1` 전용 — 서버에서 `./serve-lan.sh` 실행                            |
| 502 가 돌아옴                   | 게이트웨이는 살아 있고 백엔드가 죽음 — 서버에서 `docker ps` 로 lms-1·lms-2 확인           |
| curl 은 되는데 `claude` 만 실패 | `settings.json` 이 BOM 으로 저장됨 / JSON 문법 오류 — 메모장에서 UTF-8(BOM 아님)로 재저장 |
| `curl` 문법 오류가 남           | `curl` 이 아니라 **`curl.exe`** 를 쓸 것 (PowerShell 별칭 충돌)                           |
| 사내 프록시가 가로챔            | Windows 환경변수 `NO_PROXY` 에 `<서버IP>` 추가                                            |
| model not found                 | `<모델키>` 가 `/v1/models` 의 `id` 와 불일치                                              |
| 응답이 매우 느림                | 세션마다 다른 백엔드로 흩어져 재프리필 중일 수 있음 — step4 `./run.sh --affinity` 재확인  |
