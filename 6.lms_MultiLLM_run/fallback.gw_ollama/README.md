---
name: README
description: fallback — lms 실패 시 기존 ollamawebui(11434) 를 게이트웨이 백엔드로 갈아끼우는 대체 경로
date: 2026-07-21
---

# 목적

step1~5 의 정규 경로(lms 백엔드)가 폐쇄망에서 동작하지 않을 때의 **대체 경로**다.
게이트웨이는 그대로 두고 **백엔드만 lms → 기존 ollama 로 교체**한다.

```
[Windows PC: 클라이언트] ──LAN──→ 서버:8080(gateway) ──→ ollamawebui:11434
                                    (nginx, 반입 이미지 재사용)      (폐쇄망에 이미 떠 있음)
```

핵심 전제 (사용자 확인 사항):

* 폐쇄망에 `ollamawebui` 컨테이너가 **11434 로 이미 서비스 중**이고, Windows 에서 직접 접속해 **잘 쓰고 있음** → ollama 백엔드 건강은 이미 검증됨
* **cc(Claude Code) 컨테이너는 반입하지 않음** — 클라이언트는 Windows PC
* **반입할 gateway 컨테이너(`lms-gateway:latest`)를 수정**하는 것이 이 문서의 범위

# 왜 게이트웨이만 갈아끼우면 되는가

정규 경로의 게이트웨이는 순수 nginx 프록시이고, 백엔드 lms 는 **OpenAI `/v1`** 을 서빙한다.
ollama 도 11434 에서 **동일한 OpenAI `/v1`**(`/v1/models`, `/v1/chat/completions`)을 서빙한다.
→ 게이트웨이의 upstream 을 `lms-N:1234` 에서 `ollamawebui:11434` 로 바꾸기만 하면
   `/v1` 레벨에서 **무변경 드롭인 교체**가 성립한다. 클라이언트 설정도 주소는 그대로다.

lms 게이트웨이와의 차이는 하나뿐:

* 백엔드가 **ollamawebui 단일 컨테이너** → consistent hash 세션 고정(affinity)이 불필요
  → 단순 단일 upstream 으로 축소 ([ollama.nginx.conf.template](ollama.nginx.conf.template))

> **"게이트웨이 수정" = 이미지 재빌드가 아니다.** 반입한 `lms-gateway:latest` 를 그대로 쓰되,
> 다른 nginx 템플릿 + 다른 env(`OLLAMA_UPSTREAM`)로 **다시 실행**하는 것이 수정의 실체다.
> 폐쇄망에서 이미지 빌드가 필요 없다.

# 구성 파일

| 파일                          | 실행 위치       | 역할                                                                      |
| :---------------------------- | :-------------- | :------------------------------------------------------------------------ |
| `ollama.nginx.conf.template`  | 게이트웨이 컨테이너 | lms 템플릿에서 affinity 제거 + upstream 을 `${OLLAMA_UPSTREAM}` 로 치환한 것 |
| `serve-ollama.sh`             | **서버(Linux)** | 네트워크·LAN IP 자동 탐지 → gateway 를 ollama 백엔드로 재실행. 판정·되돌리기 포함 |
| (이 README)                   | —               | 절차 안내                                                                 |

# 절차 (서버 · Linux)

## 0. 사전 확인 — ollama 백엔드 도달

게이트웨이를 세우기 전에 백엔드가 살아 있는지부터 본다. 여기서 실패하면 게이트웨이는 무의미하다.

```bash
docker ps --filter name=ollamawebui           # 실행 중인지
curl -s http://127.0.0.1:11434/v1/models | head   # OpenAI /v1 응답 확인 (id 목록)
```

* 모델 `id` 목록 JSON 이 나와야 한다. 이 `id` 하나가 뒤에서 Windows `model` 키가 된다
* 모델 정책: **Google 계열(gemma)만 사용**. `/v1/models` 에 gemma 계열이 로드돼 있어야 한다

## 1. 게이트웨이를 ollama 백엔드로 재실행

```bash
cd fallback.gw_ollama
./serve-ollama.sh            # 네트워크 자동 탐지 → gateway(:8080) 를 ollama 로 재공개
./serve-ollama.sh --check    # 게이트 A/B/C 판정
```

`serve-ollama.sh` 가 하는 일:

1. **ollamawebui 생존 확인** — 죽어 있으면 중단 (백엔드 죽은 채 게이트웨이만 열면 502 를 "Windows 문제"로 오진)
2. **ollamawebui 의 docker 네트워크 자동 탐지** → gateway 를 **같은 네트워크**에 붙여 컨테이너명(`ollamawebui:11434`)으로 닿게 함
    - 같은 네트워크에 못 붙이는 경우 `host.docker.internal:11434` 로 폴백 (`--add-host` 자동 부착)
3. **gateway 컨테이너만 재생성** — 반입 이미지 `lms-gateway:latest` + ollama 템플릿 + `OLLAMA_UPSTREAM` env
4. 서버 LAN IP 자동 탐지 → Windows 에 붙여넣을 `settings.json` 을 실제 값으로 출력

수동으로 하려면(스크립트 없이):

```bash
# ollamawebui 네트워크 확인
NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' ollamawebui | awk '{print $1}')

docker rm -f gateway 2>/dev/null
docker run -d --name gateway \
  --network "$NET" \
  --restart unless-stopped \
  -p 0.0.0.0:8080:8080 \
  -v "$PWD/ollama.nginx.conf.template:/etc/nginx/templates/default.conf.template:ro" \
  -e OLLAMA_UPSTREAM=ollamawebui:11434 \
  lms-gateway:latest
```

> ⚠️ 게이트웨이·ollama 의 `/v1` 은 **무인증**이다. 폐쇄망/신뢰 LAN 전제에서만 `0.0.0.0` 공개할 것.
> 필요하면 방화벽에서 8080 접속 대역을 제한한다.

## 2. 방화벽 (필요 시)

```bash
sudo ufw allow 8080/tcp    # ufw active 인 경우만
```

# 절차 (클라이언트 · Windows)

> 이미 Windows 에서 ollama(11434) 를 직접 잘 쓰고 있다면, 게이트웨이 경유로 바꾸는 것은
> **접속 주소를 :11434 → 게이트웨이 :8080 으로 바꾸는 것**뿐이다. 백엔드는 동일한 ollama 다.
> 게이트웨이를 거치는 이유: lms 정규 경로와 **동일한 :8080 엔드포인트**를 유지해 클라이언트 설정을
> 최소 변경으로 재사용하기 위함(주소 고정, 되돌리기 단순화).

## 2-1. 도달 확인 (설정보다 먼저)

명령 프롬프트/PowerShell 에서:

```
curl.exe http://<서버IP>:8080/v1/models
```

* **`.exe` 를 반드시 붙일 것** — PowerShell 의 `curl` 은 `Invoke-WebRequest` 별칭이라 문법이 다르다
* 모델 목록 JSON 이 나와야 다음으로 진행. 여기서 실패하면 클라이언트 설정을 고쳐도 소용없다

## 2-2. 클라이언트 접속 주소 변경

기존에 `http://<서버IP>:11434`(또는 게이트웨이 :8080) 로 향하던 설정에서 **base URL 을
`http://<서버IP>:8080` 으로, `model` 을 `/v1/models` 의 `id` 로** 맞춘다.

Claude Code 를 쓰는 경우 `%USERPROFILE%\.claude\settings.json` 예시 (`serve-ollama.sh` 출력값 그대로):

```json
{
  "model": "<모델키 — /v1/models 의 id>",
  "env": {
    "ANTHROPIC_BASE_URL": "http://<서버IP>:8080",
    "ANTHROPIC_AUTH_TOKEN": "ollama",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8192",
    "API_TIMEOUT_MS": "600000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

> **저장 인코딩**: 메모장 → 다른 이름으로 저장 → 인코딩 **`UTF-8`**(`UTF-8 (BOM)` 아님).
> BOM 으로 저장하면 Claude Code 가 파일을 읽지 못한다(이전 반입 실패의 직접 원인 중 하나).

# 성공 판정 (게이트)

**서버 측** — `./serve-ollama.sh --check`

| 게이트 | 내용                                                                       |
| :----- | :------------------------------------------------------------------------- |
| 전제   | `ollamawebui` 실행 중                                                       |
| A      | gateway publish 가 `0.0.0.0:8080`                                          |
| B      | 서버가 **자기 LAN IP** 로 `/v1/models` 200 (여기서 실패하면 Windows 도 실패) |
| C      | 방화벽 8080/tcp 인바운드 허용                                              |

**Windows 측** — 수동

1. `curl.exe http://<서버IP>:8080/v1/models` → 모델 목록 JSON
2. 클라이언트에서 1턴 대화 성공

# 되돌리기

```bash
./serve-ollama.sh --revert    # gateway 컨테이너만 제거 (ollamawebui 는 그대로)
```

* lms 정규 경로로 복귀하려면 step4/step5 절차로 lms 게이트웨이를 다시 세운다
* ollamawebui 는 이 절차에서 **한 번도 건드리지 않으므로** Windows 직접 접속(11434)은 계속 유효하다

# 실패 시 진단

| 증상                            | 확인                                                                                 |
| :------------------------------ | :----------------------------------------------------------------------------------- |
| Windows curl 이 타임아웃        | 서버 방화벽 8080 인바운드 차단 — `sudo ufw allow 8080/tcp`                            |
| 연결 거부(refused)              | gateway 가 `127.0.0.1` 전용 — `./serve-ollama.sh` 로 `0.0.0.0` 재공개                |
| 502 가 돌아옴                   | gateway 는 살아 있고 백엔드에 못 닿음 — gateway 가 ollamawebui 와 **같은 네트워크**인지 확인 (`docker inspect gateway`), IP 바뀌었으면 `./serve-ollama.sh` 재실행 |
| gateway 로그 `host not found`   | `OLLAMA_UPSTREAM` 이름 해석 실패 — 컨테이너명 대신 호스트IP(`172.17.0.1:11434`) 로 재시도 |
| model not found                 | `model` 키가 `/v1/models` 의 `id` 와 불일치                                           |
| curl.exe 문법 오류              | `curl` 이 아니라 **`curl.exe`** 사용 (PowerShell 별칭 충돌)                           |
| 첫 응답이 매우 느림             | ollama 콜드 로드(모델 최초 적재) — 정상. 이후 요청은 빨라짐                            |

# 정규 경로와의 관계

* 이 폴더는 step1~5 의 **대체 경로**이지 순차 단계가 아니다
* 게이트웨이 이미지(`lms-gateway:latest`)는 **정규 경로와 동일한 반입본**을 그대로 쓴다
* lms 가 복구되면 언제든 step4/step5 로 되돌아갈 수 있고, 그때 클라이언트 설정 주소(:8080)는 동일하다
