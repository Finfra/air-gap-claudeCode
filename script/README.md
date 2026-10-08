# script

> 저장소 공용 보조 스크립트 자리. 현재는 Init 시점(2026-04)의 compose 관리 래퍼 1개만 있다.

## 구성

| 파일        | 역할                                                                          |
| :---------- | :---------------------------------------------------------------------------- |
| `docker.sh` | `docker compose` 의 up·down·restart·status·logs·pull·exec 를 묶은 관리 래퍼 |

## 사용법

```bash
script/docker.sh up [service]       # 컨테이너 시작 (service 생략 시 전체)
script/docker.sh down               # 전체 중지·제거
script/docker.sh restart [service]  # 재시작
script/docker.sh status             # 상태
script/docker.sh logs [service]     # 로그 follow
script/docker.sh pull [service]     # 이미지 갱신
script/docker.sh exec <service>     # 컨테이너 bash 접속
```

## 주의 — 현재 구조와 어긋남

* compose 파일을 `script/../docker-compose.yml`(저장소 루트)로 **고정**해 두었지만, 지금 루트에는 `docker-compose.yml` 이 없다 — 예제가 `1.ollama_OneContainer`·`2.ollama_TwoContainer` 등 하위 폴더로 나뉘었기 때문
* 그대로 실행하면 compose 파일을 찾지 못해 실패한다. 당장은 각 예제 폴더에서 `docker compose ...` 를 직접 쓴다 (각 폴더 README 참조)
* 계속 쓰려면 예제 폴더를 인자로 받도록 `COMPOSE_FILE` 을 고쳐야 한다 (미반영)
