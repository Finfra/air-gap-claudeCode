#!/bin/bash
# 목표 1: 세 ollama 예제의 docker compose config 가 .env.org 기준으로 통과한다
source "$(dirname "$0")/lib.sh"

for ex in "${EXAMPLES[@]}"; do
    envf="$(make_env "$ex")"
    if err="$(compose_json "$ex" "$envf" 2>&1 >/dev/null)"; then
        pass "$ex config"
    else
        fail "$ex config — $err"
    fi
done
finish
