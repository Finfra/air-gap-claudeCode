# 3.ollama_External

> 호스트(또는 원격 서버)에 **이미 설치된 외부 Ollama** 에 Claude Code 컨테이너만 붙이는 '일반 방식' 예제. Ollama 컨테이너를 따로 띄우지 않는다. 전체 토폴로지 비교는 [상위 README](../README.md) 참조.

## 용도

* 호스트·서버에 Ollama 가 이미 운영 중인 환경(systemd 등)에 Claude Code 클라이언트만 추가
* 모델·GPU·KV cache·context 튜닝을 호스트 Ollama 에 일임
* 여러 머신·팀이 공용 중앙 Ollama 서버에 클라이언트만 늘리는 경우

## 구성

| 파일                      | 역할                                                                              |
| :------------------------ | :-------------------------------------------------------------------------------- |
| `docker-compose.yml`      | `claude` 서비스 1개 — 외부 Ollama 주소를 `ANTHROPIC_BASE_URL` 로 주입             |
| `docker-compose.code.yml` | 호스트 코드 폴더(`MOUNT_CODE_DIR`) → `/home/ubuntu/code` 마운트 override (선택)   |
| `Dockerfile.claude`       | `debian:bookworm-slim` + Node.js 22 + Claude Code, `ubuntu` 유저(UID/GID 가변)    |
| `entrypoint.sh`           | 외부 Ollama 도달 확인(`nc`, 최대 60초) + `~/.claude/settings.json` 생성           |
| `.env.org`                | `.env` 템플릿 (커밋됨). `env.sh` 는 `.env` 를 가리키는 심볼릭링크                 |

* 컨테이너 1개(`claude`)만 존재 — 호스트 포트 매핑 없음(Ollama 는 외부가 이미 11434 제공)
* `extra_hosts: host.docker.internal:host-gateway` 로 Linux 호스트에서도 호스트 Ollama 해석 (macOS·Windows Docker Desktop 은 자동)
* 볼륨: `~/df → /home/ubuntu/df` (작업 폴더) · `claude-home → /home/ubuntu` (Claude 홈 영속화)

## 사전 조건

* 외부 Ollama 에 모델이 **미리 pull** 되어 있어야 함 — 컨테이너는 모델을 받지 않음
    ```bash
    ollama pull gemma4:26b
    ```
* 호스트 Ollama 가 **`0.0.0.0` 에 바인드**되어야 컨테이너에서 접근 가능 (기본 `127.0.0.1` 이면 연결 불가)
    ```bash
    sudo systemctl edit ollama      # [Service] Environment=OLLAMA_HOST=0.0.0.0
    sudo systemctl restart ollama
    ```

## 사용법

```bash
cd 3.ollama_External
cp .env.org .env
vi .env          # OLLAMA_HOST(외부 Ollama 주소), OLLAMA_MODEL 수정

# 기동 (GPU override 불필요 — GPU 는 호스트 Ollama 소관)
docker compose up -d --build

# 호스트 코드 폴더 마운트 (선택, .env 의 MOUNT_CODE_DIR 필요)
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d --build

# 컨테이너 접속 후 Claude Code 실행
docker exec -it claude bash
cc               # alias = claude --dangerously-skip-permissions
```

원격 서버 Ollama 를 쓰려면 `.env` 에서 `OLLAMA_HOST=<서버 IP 또는 호스트명>` 으로 바꾸고 재기동한다.

## 주요 변수 (`.env`)

| 변수                    | 기본값                          | 설명                                                  |
| :---------------------- | :------------------------------ | :---------------------------------------------------- |
| `OLLAMA_MODEL`          | `gemma4:26b`                    | 사용할 모델 태그 — 외부 Ollama 에 pull 되어 있어야 함 |
| `OLLAMA_HOST`           | `host.docker.internal`          | 외부 Ollama 호스트 (같은 머신이면 기본값)             |
| `OLLAMA_PORT_EXT`       | `11434`                         | 외부 Ollama 포트                                      |
| `MOUNT_CODE_DIR`        | (비어 있음)                     | 코드 마운트 override 사용 시 호스트 경로              |
| `COMPOSE_PROJECT_NAME`  | `air_gap_claude_code_external`  | 다중 인스턴스 동시 실행 시 충돌 회피                  |
| `CLAUDE_CONTAINER_NAME` | `claude`                        | 컨테이너 이름                                         |
| `USER_UID`·`USER_GID`   | `1000`                          | 호스트 파일 권한 일치 (Linux 는 `id -u`·`id -g` 권장) |
| `TZ`                    | `Asia/Seoul`                    | 컨테이너 시각                                         |

## 점검

```bash
# 호스트에서 외부 Ollama 응답 확인
curl -s http://localhost:11434/api/tags | head

# 컨테이너에서 외부 Ollama 도달 확인
docker exec claude bash -c 'nc -zv "$OLLAMA_HOST" "$OLLAMA_PORT_EXT"'

# entrypoint 로그 (연결 대기·경고 확인)
docker logs claude | grep entrypoint
```

* `host '...' not resolvable` 경고 → `OLLAMA_HOST` 값 또는 `extra_hosts` 확인
* `external Ollama unreachable after 60s` → 호스트 Ollama 의 `0.0.0.0` 바인드·방화벽 확인
