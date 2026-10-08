# 1.ollama_OneContainer

> Ollama 서버와 Claude Code 를 **컨테이너 1개**에 함께 올리는 가장 단순한 예제. 빠른 시작·로컬 개발용. 전체 토폴로지 비교는 [상위 README](../README.md) 참조.

## 용도

* 단일 머신에서 Ollama + Claude Code 를 한 번에 띄우고 싶은 경우
* 컨테이너 1개만 관리하면 되므로 셋업·디버깅이 간결
* Ollama API 를 다른 클라이언트와 공유할 필요 없는 1:1 환경

## 구성

| 파일                      | 역할                                                                                      |
| :------------------------ | :---------------------------------------------------------------------------------------- |
| `docker-compose.yml`      | `claude` 서비스 1개 — 이미지 `air-gap-claude-code` 빌드, 포트·볼륨·healthcheck 정의       |
| `docker-compose.gpu.yml`  | NVIDIA GPU 예약 override (`driver: nvidia`, `count: all`)                                 |
| `docker-compose.code.yml` | 호스트 코드 폴더(`MOUNT_CODE_DIR`) → `/home/ubuntu/code` 마운트 override (선택)           |
| `Dockerfile`              | `ollama/ollama` + Node.js 22 + Claude Code + `ubuntu` 유저(UID/GID 가변)                  |
| `entrypoint.sh`           | `ollama serve` 기동 → 준비 대기 → `OLLAMA_MODEL` pull → `~/.claude/settings.json` 생성    |
| `.env.org`                | `.env` 템플릿 (커밋됨). `env.sh` 는 `.env` 를 가리키는 심볼릭링크                         |

* Claude Code 는 같은 컨테이너의 Ollama 를 `ANTHROPIC_BASE_URL=http://127.0.0.1:11434` 로 직결 (Anthropic 호환 API)
* `claude` 명령은 wrapper 로 교체되어 `--dangerously-skip-permissions` 를 자동 주입 — 컨테이너 격리가 안전 경계 역할
* 컨테이너 기본 유저는 `ubuntu` (`docker exec` 도 ubuntu 로 진입, root 는 `-u root`)
* 호스트 포트 매핑: `${OLLAMA_PORT:-11437} → 11434`
* 볼륨: `~/df → /home/ubuntu/df` (작업 폴더) · `claude-home → /home/ubuntu` (Claude 홈 영속화) · `${OLLAMA_MOUNT} → /home/ubuntu/.ollama` (모델 저장소, 토글)

## 사용법

```bash
cd 1.ollama_OneContainer
cp .env.org .env
vi .env          # OLLAMA_MODEL, OLLAMA_MOUNT, MOUNT_CODE_DIR 수정

# Mac / Linux CPU 모드
docker compose up -d --build

# Linux + NVIDIA GPU
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build

# 호스트 코드 폴더 마운트 (선택, .env 의 MOUNT_CODE_DIR 필요)
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d --build

# 컨테이너 접속 후 Claude Code 실행
docker exec -it claude bash
cc               # alias = claude --dangerously-skip-permissions
```

> 첫 기동 시 모델 pull 이 끝날 때까지 시간이 걸린다. 처음 한 번은 퍼미션 오류가 날 수 있으며, 두 번째 실행부터 정상 동작한다.

## 주요 변수 (`.env`)

| 변수                     | 기본값                    | 설명                                                                  |
| :----------------------- | :------------------------ | :-------------------------------------------------------------------- |
| `OLLAMA_MODEL`           | `gemma4:26b`              | 기동 시 pull 할 모델 태그 (Claude Code 기본 모델로도 사용)            |
| `OLLAMA_MOUNT`           | `~/.ollama`               | 모델 저장소 — 호스트 경로면 공유, `ollama-models` 면 격리(named vol)  |
| `MOUNT_CODE_DIR`         | (비어 있음)               | 코드 마운트 override 사용 시 호스트 경로                              |
| `COMPOSE_PROJECT_NAME`   | `air_gap_claude_code_one` | 다중 인스턴스 동시 실행 시 충돌 회피                                  |
| `CLAUDE_CONTAINER_NAME`  | `claude`                  | 컨테이너 이름                                                         |
| `OLLAMA_PORT`            | `11437`                   | 호스트에 노출할 Ollama 포트                                           |
| `USER_UID`·`USER_GID`    | `1000`                    | 호스트 파일 권한 일치 (Linux 는 `id -u`·`id -g` 권장, 변경 시 재빌드) |
| `OLLAMA_FLASH_ATTENTION` | `1`                       | Flash Attention (OOM 시 `0` 으로 폴백)                                |
| `OLLAMA_KV_CACHE_TYPE`   | `q8_0`                    | KV cache 양자화 — `f16`·`q8_0`(권장)·`q4_0`                           |
| `OLLAMA_NUM_GPU`         | `999`                     | GPU 로드 레이어 수 (999 = 전 레이어)                                  |
| `OLLAMA_CONTEXT_LENGTH`  | `100000`                  | 컨텍스트 길이                                                         |
| `TZ`                     | `Asia/Seoul`              | 컨테이너 시각                                                         |

## 점검

```bash
# 호스트에서 Ollama 응답 확인
curl -s http://localhost:11437/api/tags | head

# 컨테이너 상태(healthcheck = ollama list)
docker ps --filter name=claude

# 모델이 GPU 에서 도는지 (PROCESSOR 가 "100% GPU" 여야 정상)
docker exec claude ollama ps

# entrypoint 로그 (모델 pull 실패 경고 확인)
docker logs claude | grep entrypoint
```

* `WARNING: model pull failed` → 모델 태그 오타 또는 네트워크 차단. 폐쇄망이면 `OLLAMA_MOUNT` 로 미리 받아 둔 모델 저장소를 공유
* GPU 미적용 → `docker-compose.gpu.yml` 을 포함해 재생성 ([상위 README](../README.md) 트러블슈팅 참조)
