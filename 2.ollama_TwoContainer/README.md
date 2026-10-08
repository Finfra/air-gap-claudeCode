# 2.ollama_TwoContainer

> Ollama 와 Claude Code 를 **컨테이너 2개**로 분리한 예제. Ollama 서비스를 독립시켜 재시작·로그·공유가 쉽다. 전체 토폴로지 비교는 [상위 README](../README.md) 참조.

## 용도

* Ollama 서버를 독립 컨테이너로 운영하고 싶은 경우 (재시작·로그 분리, 모니터링 용이)
* 같은 Ollama 를 여러 클라이언트(Claude Code 외 다른 도구)와 공유
* `claude` 컨테이너만 자주 빌드·교체하고 `ollama` 는 유지하고 싶은 환경

## 구성

| 파일                      | 역할                                                                                    |
| :------------------------ | :-------------------------------------------------------------------------------------- |
| `docker-compose.yml`      | `ollama`(공식 이미지 그대로) + `claude`(빌드) 2개 서비스, 전용 네트워크 `ollama`        |
| `docker-compose.gpu.yml`  | `ollama` 서비스에 NVIDIA GPU 예약 override                                              |
| `docker-compose.code.yml` | 호스트 코드 폴더(`MOUNT_CODE_DIR`) → `claude` 의 `/home/ubuntu/code` 마운트 (선택)      |
| `Dockerfile.claude`       | `debian:bookworm-slim` + Node.js 22 + Claude Code, `ubuntu` 유저(UID/GID 가변)          |
| `test-setup.sh`           | 기동 후 5단계 점검 스크립트 (컨테이너·API·모델·네트워크·settings.json)                  |
| `.env.org`                | `.env` 템플릿 (커밋됨). `env.sh` 는 `.env` 를 가리키는 심볼릭링크                       |

* `ollama` 컨테이너: 기동 시 `ollama serve` → `${OLLAMA_MODEL}` 자동 pull. healthcheck = `ollama list`
* `claude` 컨테이너: ollama healthcheck 통과 후 기동 (`depends_on: service_healthy`)
* 컨테이너 간 통신: `claude` → `http://ollama:11434` (Anthropic 호환 API 직결)
* `claude` 의 entrypoint(`wait-for-ollama.sh`, Dockerfile 내장)가 `~/.claude/settings.json` 생성 후 `nc` 로 Ollama 대기
* 호스트 포트 매핑: `${OLLAMA_PORT:-11436} → ollama:11434` (claude 는 포트 노출 없음)
* 볼륨: `~/df → /df`(ollama)·`/home/ubuntu/df`(claude) · `${OLLAMA_MOUNT} → /root/.ollama`(ollama 전용 모델 저장소, 토글) · `claude-home → /home/ubuntu`

## 사용법

```bash
cd 2.ollama_TwoContainer
cp .env.org .env
vi .env          # OLLAMA_MODEL, OLLAMA_MOUNT, MOUNT_CODE_DIR 수정

# Mac / Linux CPU 모드
docker compose up -d --build

# Linux + NVIDIA GPU
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build

# 호스트 코드 폴더 마운트 (선택, .env 의 MOUNT_CODE_DIR 필요)
docker compose -f docker-compose.yml -f docker-compose.code.yml up -d --build

# 클라이언트 접속 후 Claude Code 실행 (기본 유저 ubuntu)
docker exec -it claude bash
cc               # alias = claude --dangerously-skip-permissions

# Ollama 단독 재시작 (claude 영향 없음)
docker compose restart ollama
```

## 주요 변수 (`.env`)

| 변수                     | 기본값                    | 설명                                                                  |
| :----------------------- | :------------------------ | :-------------------------------------------------------------------- |
| `OLLAMA_MODEL`           | `gemma4:26b`              | ollama 기동 시 pull 할 모델 태그 (Claude Code 기본 모델로도 사용)     |
| `OLLAMA_MOUNT`           | `~/.ollama`               | 모델 저장소 — 호스트 경로면 공유, `ollama-models` 면 격리(named vol)  |
| `MOUNT_CODE_DIR`         | (비어 있음)               | 코드 마운트 override 사용 시 호스트 경로                              |
| `COMPOSE_PROJECT_NAME`   | `air_gap_claude_code_two` | 다중 인스턴스 동시 실행 시 충돌 회피                                  |
| `OLLAMA_CONTAINER_NAME`  | `ollama`                  | ollama 컨테이너 이름 (claude 의 `ANTHROPIC_BASE_URL` 호스트명에 반영) |
| `CLAUDE_CONTAINER_NAME`  | `claude`                  | claude 컨테이너 이름                                                  |
| `OLLAMA_NETWORK_NAME`    | `ollama`                  | 두 컨테이너가 붙는 Docker 네트워크 이름                               |
| `OLLAMA_PORT`            | `11436`                   | 호스트에 노출할 Ollama 포트                                           |
| `USER_UID`·`USER_GID`    | `1000`                    | 호스트 파일 권한 일치 (Linux 는 `id -u`·`id -g` 권장, 변경 시 재빌드) |
| `OLLAMA_FLASH_ATTENTION` | `1`                       | Flash Attention (OOM 시 `0` 으로 폴백)                                |
| `OLLAMA_KV_CACHE_TYPE`   | `q8_0`                    | KV cache 양자화 — `f16`·`q8_0`(권장)·`q4_0`                           |
| `OLLAMA_NUM_GPU`         | `999`                     | GPU 로드 레이어 수 (999 = 전 레이어)                                  |
| `OLLAMA_CONTEXT_LENGTH`  | `100000`                  | 컨텍스트 길이                                                         |
| `TZ`                     | `Asia/Seoul`              | 컨테이너 시각                                                         |

## 점검

```bash
# 5단계 자동 점검 (기동 후)
bash test-setup.sh

# 호스트에서 Ollama 응답 확인
curl -s http://localhost:11436/api/tags | head

# claude → ollama 네트워크 연결
docker exec claude nc -z ollama 11434 && echo OK

# 모델이 GPU 에서 도는지 (PROCESSOR 가 "100% GPU" 여야 정상)
docker exec ollama ollama ps
```

* `test-setup.sh` 의 [3/5] 모델 확인은 `qwen3-coder:30b` 로 고정돼 있다 — 다른 `OLLAMA_MODEL` 을 쓰면 ⚠️ 경고만 뜨고 실패로 치지 않는다
* `Ollama host not found - running without Ollama` → claude 가 compose 네트워크 밖에서 실행된 것. `docker compose` 로 함께 기동
* `claude` 가 계속 대기 → `docker logs ollama` 로 모델 pull 진행·실패 여부 확인
