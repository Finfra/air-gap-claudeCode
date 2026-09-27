#!/bin/bash
# 목표 2: 추적 중인 entrypoint 스크립트 전부가 bash -n 을 통과한다
source "$(dirname "$0")/lib.sh"

cd "$REPO_ROOT"
files="$(git ls-files 'entrypoint*.sh' '*/entrypoint*.sh')"
[[ -n "$files" ]] || fail "entrypoint 스크립트를 찾지 못함"
while IFS= read -r f; do
    if err="$(bash -n "$f" 2>&1)"; then pass "$f"; else fail "$f — $err"; fi
done <<< "$files"
finish
