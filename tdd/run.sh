#!/bin/bash
# tdd 러너 — playlist.md 재생 순서대로 자동 케이스(cases/*.sh)를 돈다
# 기동이 필요한 5~7 번은 수동 절차라 여기서 돌지 않는다 (playlist 실행 열 참조)
#   bash tdd/run.sh            전부
#   bash tdd/run.sh <id> ...   지정 케이스만
cd "$(dirname "$0")/cases" || exit 1
ORDER=(compose-config-examples entrypoint-syntax env-externalized ollama-mount-toggle)
[[ $# -gt 0 ]] && ORDER=("$@")

rc=0
for id in "${ORDER[@]}"; do
    echo "=== $id"
    if bash "./$id.sh"; then :; else rc=1; fi
done
echo
[[ $rc -eq 0 ]] && echo "ALL GREEN" || echo "RED 있음"
exit $rc
