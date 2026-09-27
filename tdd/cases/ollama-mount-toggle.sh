#!/bin/bash
# 목표 4: OLLAMA_MOUNT 미설정 → named volume ollama-models, 설정 → 호스트 경로 bind.
#         MOUNT_CODE_DIR override 는 /home/ubuntu/code 로 bind 된다
source "$(dirname "$0")/lib.sh"

command -v jq >/dev/null || { echo "jq 필요"; exit 1; }

# 예제별 모델 저장소 마운트 대상 (One: claude 컨테이너 ubuntu 홈 / Two: ollama 공식 이미지 root)
# (bash 3.2 호환 — 연관 배열 대신 "예제 서비스 대상" 3열 목록)
MOUNT_CASES="1.ollama_OneContainer claude /home/ubuntu/.ollama
2.ollama_TwoContainer ollama /root/.ollama"

vol_of() {  # <json> <service> <target> → "type source"
    jq -r --arg s "$2" --arg t "$3" '.services[$s].volumes[] | select(.target==$t) | "\(.type) \(.source)"' <<< "$1"
}

HOSTDIR="$TMPDIR_TDD/models"; mkdir -p "$HOSTDIR"

while read -r ex svc tgt; do
    echo "[$ex]"
    js="$(compose_json "$ex" "$(make_env "$ex" -OLLAMA_MOUNT)")"
    expect_eq "미설정" "$(vol_of "$js" "$svc" "$tgt")" "volume ollama-models"
    js="$(compose_json "$ex" "$(make_env "$ex" OLLAMA_MOUNT=ollama-models)")"
    expect_eq "격리(ollama-models)" "$(vol_of "$js" "$svc" "$tgt")" "volume ollama-models"
    js="$(compose_json "$ex" "$(make_env "$ex" OLLAMA_MOUNT="$HOSTDIR")")"
    expect_eq "공유(호스트 경로)" "$(vol_of "$js" "$svc" "$tgt")" "bind $HOSTDIR"
    js="$(compose_json "$ex" "$(make_env "$ex" OLLAMA_MOUNT='~/.ollama')")"
    expect_eq "공유(~ 확장)" "$(vol_of "$js" "$svc" "$tgt")" "bind $HOME/.ollama"
done <<< "$MOUNT_CASES"

CODEDIR="$TMPDIR_TDD/code"; mkdir -p "$CODEDIR"
for ex in "${EXAMPLES[@]}"; do
    echo "[$ex code override]"
    js="$(compose_json "$ex" "$(make_env "$ex" MOUNT_CODE_DIR="$CODEDIR")" docker-compose.code.yml)"
    expect_eq "MOUNT_CODE_DIR" "$(vol_of "$js" claude /home/ubuntu/code)" "bind $CODEDIR"
    js="$(compose_json "$ex" "$(make_env "$ex")")"
    expect_eq "override 미적용 시 없음" "$(vol_of "$js" claude /home/ubuntu/code)" ""
done
finish
