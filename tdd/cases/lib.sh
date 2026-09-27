#!/bin/bash
# tdd 케이스 공통 헬퍼 — 추적 템플릿(.env.org) 기준으로 compose config 를 렌더한다
# 사용자 로컬 .env 는 읽지 않는다(머신마다 달라 판정이 흔들림)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXAMPLES=(1.ollama_OneContainer 2.ollama_TwoContainer 3.ollama_External)

FAIL=0
TMPDIR_TDD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TDD"' EXIT

pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; FAIL=1; }

# .env.org 를 복사하고 KEY=VALUE 치환·추가·삭제를 적용한 env 파일 경로를 출력
#   make_env <예제> [KEY=VALUE ...] [-KEY ...]
make_env() {
    local ex="$1"; shift
    local out="$TMPDIR_TDD/${ex}.$RANDOM.env"
    cp "$REPO_ROOT/$ex/.env.org" "$out"
    local kv key
    for kv in "$@"; do
        # BSD·GNU sed -i 문법이 달라 grep -v 로 재작성 (macOS·fg1 양쪽 동작)
        key="${kv#-}"; key="${key%%=*}"
        grep -v "^${key}=" "$out" > "$out.tmp"; mv "$out.tmp" "$out"
        [[ "$kv" == -* ]] || echo "$kv" >> "$out"
    done
    echo "$out"
}

# compose config 를 JSON 으로 렌더
#   compose_json <예제> <env파일> [추가 -f 파일 ...]
compose_json() {
    local ex="$1" envf="$2"; shift 2
    local files=(-f "$REPO_ROOT/$ex/docker-compose.yml")
    local f
    for f in "$@"; do files+=(-f "$REPO_ROOT/$ex/$f"); done
    docker compose --project-directory "$REPO_ROOT/$ex" --env-file "$envf" "${files[@]}" config --format json
}

# 기대값 비교
#   expect_eq <라벨> <실제> <기대>
expect_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1 = $3"; else fail "$1: 기대 '$3' / 실제 '$2'"; fi
}

finish() {
    if [[ $FAIL -eq 0 ]]; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
}
