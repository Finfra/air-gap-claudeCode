#!/bin/bash
# 목표 3: .env.org 값이 compose config 출력에 반영되고, 두 예제(One·Two)의 KV cache 가 같다
source "$(dirname "$0")/lib.sh"

command -v jq >/dev/null || { echo "jq 필요"; exit 1; }

env_of() { jq -r --arg s "$2" --arg k "$3" '.services[$s].environment[$k]' <<< "$1"; }

# 템플릿 값 그대로 반영되는가
for ex in "${EXAMPLES[@]}"; do
    echo "[$ex]"
    envf="$(make_env "$ex")"
    js="$(compose_json "$ex" "$envf")" || { fail "$ex config 실패"; continue; }
    # shellcheck disable=SC1090
    ( set -a; source "$envf"; set +a
      declare -p COMPOSE_PROJECT_NAME CLAUDE_CONTAINER_NAME USER_UID USER_GID TZ >/dev/null ) \
      || fail "$ex .env.org 필수 키 누락"
    v() { grep -E "^$1=" "$envf" | tail -1 | cut -d= -f2-; }
    expect_eq "name" "$(jq -r .name <<< "$js")" "$(v COMPOSE_PROJECT_NAME)"
    expect_eq "claude container_name" "$(jq -r .services.claude.container_name <<< "$js")" "$(v CLAUDE_CONTAINER_NAME)"
    expect_eq "claude build USER_UID" "$(jq -r .services.claude.build.args.USER_UID <<< "$js")" "$(v USER_UID)"
    expect_eq "claude TZ" "$(env_of "$js" claude TZ)" "Asia/Seoul"
    case "$ex" in
        1.ollama_OneContainer)
            expect_eq "OLLAMA_PORT published" "$(jq -r '.services.claude.ports[0].published' <<< "$js")" "$(v OLLAMA_PORT)"
            expect_eq "OLLAMA_KV_CACHE_TYPE" "$(env_of "$js" claude OLLAMA_KV_CACHE_TYPE)" "q8_0" ;;
        2.ollama_TwoContainer)
            expect_eq "ollama container_name" "$(jq -r .services.ollama.container_name <<< "$js")" "$(v OLLAMA_CONTAINER_NAME)"
            expect_eq "OLLAMA_PORT published" "$(jq -r '.services.ollama.ports[0].published' <<< "$js")" "$(v OLLAMA_PORT)"
            expect_eq "ollama TZ" "$(env_of "$js" ollama TZ)" "Asia/Seoul"
            expect_eq "OLLAMA_KV_CACHE_TYPE" "$(env_of "$js" ollama OLLAMA_KV_CACHE_TYPE)" "q8_0" ;;
        3.ollama_External)
            expect_eq "ANTHROPIC_BASE_URL" "$(env_of "$js" claude ANTHROPIC_BASE_URL)" "http://$(v OLLAMA_HOST):$(v OLLAMA_PORT_EXT)" ;;
    esac
done

# 값 변경이 실제로 전파되는가 (템플릿 기본값과 compose 기본값이 우연히 같아 통과하는 것 방지)
echo "[override 전파]"
envf="$(make_env 2.ollama_TwoContainer COMPOSE_PROJECT_NAME=tdd_probe CLAUDE_CONTAINER_NAME=tdd_claude OLLAMA_PORT=19999 TZ=UTC USER_UID=4321 OLLAMA_KV_CACHE_TYPE=f16)"
js="$(compose_json 2.ollama_TwoContainer "$envf")"
expect_eq "name" "$(jq -r .name <<< "$js")" "tdd_probe"
expect_eq "claude container_name" "$(jq -r .services.claude.container_name <<< "$js")" "tdd_claude"
expect_eq "port" "$(jq -r '.services.ollama.ports[0].published' <<< "$js")" "19999"
expect_eq "TZ" "$(env_of "$js" claude TZ)" "UTC"
expect_eq "USER_UID" "$(jq -r .services.claude.build.args.USER_UID <<< "$js")" "4321"
expect_eq "KV cache" "$(env_of "$js" ollama OLLAMA_KV_CACHE_TYPE)" "f16"

# 두 예제 KV cache 동일 (decisions.md "KV cache 타입")
echo "[KV cache 일치]"
kv1="$(env_of "$(compose_json 1.ollama_OneContainer "$(make_env 1.ollama_OneContainer)")" claude OLLAMA_KV_CACHE_TYPE)"
kv2="$(env_of "$(compose_json 2.ollama_TwoContainer "$(make_env 2.ollama_TwoContainer)")" ollama OLLAMA_KV_CACHE_TYPE)"
expect_eq "One == Two" "$kv1" "$kv2"
finish
