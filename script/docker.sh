#!/bin/bash
# Ollama + Claude Docker Compose 관리 스크립트

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"
COMPOSE=(docker compose -f "${COMPOSE_FILE}")

usage() {
    echo "Usage: $0 {up|down|restart|status|logs|pull} [service]"
    echo ""
    echo "Services: ollama, claude"
    echo ""
    echo "  up      [service]  - 컨테이너 시작"
    echo "  down               - 전체 중지 및 제거"
    echo "  restart [service]  - 재시작"
    echo "  status             - 상태 확인"
    echo "  logs    [service]  - 로그 조회"
    echo "  pull    [service]  - 이미지 업데이트"
    echo "  exec    <service>  - 컨테이너 접속 (bash)"
    exit 1
}

up() {
    echo "[up] ${1:-all}"
    "${COMPOSE[@]}" up -d $1
}

down() {
    echo "[down] all"
    "${COMPOSE[@]}" down
}

restart() {
    echo "[restart] ${1:-all}"
    "${COMPOSE[@]}" restart $1
}

status() {
    "${COMPOSE[@]}" ps
}

logs() {
    "${COMPOSE[@]}" logs -f $1
}

pull() {
    echo "[pull] ${1:-all}"
    "${COMPOSE[@]}" pull $1
}

exec_sh() {
    if [ -z "$1" ]; then
        echo "Usage: $0 exec <service>"
        exit 1
    fi
    "${COMPOSE[@]}" exec "$1" bash
}

case "${1}" in
    up)      up "$2"      ;;
    down)    down          ;;
    restart) restart "$2"  ;;
    status)  status        ;;
    logs)    logs "$2"     ;;
    pull)    pull "$2"     ;;
    exec)    exec_sh "$2"  ;;
    *)       usage         ;;
esac
