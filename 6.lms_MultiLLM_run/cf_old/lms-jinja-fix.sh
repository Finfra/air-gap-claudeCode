#!/usr/bin/env bash
# lms-jinja-fix.sh — Claude Code ↔ LM Studio "Jinja 템플릿 오류" 진단 / 우회
#
#   증상(참고: LM_Studio_Ubuntu_Headless.md):
#     500 {"error":{"message":"Error rendering prompt with jinja template:
#          \"Cannot perform operation ~ on undefined values\" ..."}}
#     → 일부 모델의 embedded Jinja chat template 이 Claude Code 의 tools/system
#       페이로드를 렌더하지 못해 발생. (컨테이너 `cc` 든 호스트 VSCode 확장이든 동일)
#
#   해결책:
#     ① 검증된 모델 사용  ← 헤드리스 권장 (이 번들의 gemma-4-31b-qat / qwen3-coder-30b)
#     ② prompt template 편집 (`| string` 필터 제거 등) ← GUI/고급, README 참조
#
#   사용:
#     ./lms-jinja-fix.sh probe [model]   # 지정(또는 현재 로드) 모델의 jinja 오류 진단
#     ./lms-jinja-fix.sh verified        # 검증된 모델 목록 출력
#     ./lms-jinja-fix.sh use <model>     # 전 LMS 백엔드에서 언로드 후 검증 모델 로드
#     ./lms-jinja-fix.sh status          # 로드 상태
#
#   환경변수: GATEWAY_PORT(기본 8080), LMS_CONTEXT_LENGTH, LMS_GPU  (.env 자동 로드)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && set -a && . "$SCRIPT_DIR/.env" && set +a
: "${GATEWAY_PORT:=8080}"
: "${LMS_PORT:=1234}"
: "${LMS_CONTEXT_LENGTH:=32768}"
# LMS_GPU 빈값 = llmster 자동 offload (VRAM<모델 환경에서 max 는 CUDA OOM — start.sh 와 동일 정책)
: "${LMS_GPU:=}"
: "${LMS_PARALLEL:=1}"

# 검증(문서 기준) 모델 — ⚠️ 보안 정책상 중국계(Qwen/GLM) 제외, Google 계열만.
#   참고: gemma-4-31b-qat 이 느렸던 원인은 jinja 가 아니라 GPU offload 미동작(CPU 추론)이었음.
#         → info_jinja_and_lms.md 참조. 실제 해결 레버는 'lms runtime select CUDA' + 충분한 VRAM.
VERIFIED=( "google/gemma-4-31b-qat" "google/gemma-4-26b-a4b" )

# 실행 중인 LMS 백엔드 컨테이너들 (start.sh: lms-1..N)
lms_backends() { docker ps --format '{{.Names}}' | grep -E '^lms(-[0-9]+)?$' || true; }
first_backend() { lms_backends | head -1; }

die() { echo "[!] $*" >&2; exit 1; }

case "${1:-}" in
  verified)
    echo "검증된 모델 (jinja 오류 없음, Claude Code tool-use OK):"
    printf '  - %s\n' "${VERIFIED[@]}"
    ;;

  status)
    for c in $(lms_backends); do
      echo "=== $c ==="
      docker exec "$c" bash -lc 'export PATH=$HOME/.lmstudio/bin:$PATH; lms ps' 2>&1 | grep -iE 'IDENTIFIER|LOADED|GENERATING|IDLE|No models' | head
    done
    ;;

  probe)
    MODEL="${2:-}"
    if [ -z "$MODEL" ]; then
      c="$(first_backend)"; [ -n "$c" ] || die "실행 중 LMS 백엔드 없음"
      MODEL="$(docker exec "$c" bash -lc 'export PATH=$HOME/.lmstudio/bin:$PATH; lms ps' 2>/dev/null \
               | awk 'NR>1 && $1!="" {print $1; exit}')"
      [ -n "$MODEL" ] || die "로드된 모델 없음 — 'use <model>' 로 먼저 로드"
    fi
    echo "[*] probe 대상 모델: $MODEL  (게이트웨이 :$GATEWAY_PORT, tools 포함 요청)"
    body="$(curl -s --max-time 45 "http://127.0.0.1:${GATEWAY_PORT}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"t\",\"description\":\"d\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}],\"max_tokens\":8}" 2>&1 || true)"
    if echo "$body" | grep -qiE 'jinja|Cannot perform operation ~'; then
      echo "[✗] JINJA 오류 발생 — 이 모델은 Claude Code 에 부적합."
      echo "    응답: $(echo "$body" | head -c 300)"
      echo "    → 해결: './lms-jinja-fix.sh use <검증모델>' (아래) 또는 README ② 템플릿 편집."
      echo "    검증 모델: ${VERIFIED[*]}"
      exit 1
    elif echo "$body" | grep -qiE '"choices"|"content"|tool_calls'; then
      echo "[✓] 정상 응답 — jinja 오류 없음. Claude Code 사용 가능."
    else
      echo "[~] jinja 오류 문자열은 없음(생성 지연/타임아웃 가능). 응답 일부:"
      echo "    $(echo "$body" | head -c 200)"
      echo "    (오류가 아니면 정상 — 큰 모델은 첫 응답이 느릴 수 있음)"
    fi
    ;;

  use)
    MODEL="${2:-}"; [ -n "$MODEL" ] || die "usage: $0 use <model>"
    backs="$(lms_backends)"; [ -n "$backs" ] || die "실행 중 LMS 백엔드 없음"
    GPU_OPT=""; [ -n "$LMS_GPU" ] && GPU_OPT="--gpu $LMS_GPU"
    for c in $backs; do
      echo "[*] $c: 언로드 → $MODEL 로드 (ctx=$LMS_CONTEXT_LENGTH, gpu=${LMS_GPU:-auto}, parallel=$LMS_PARALLEL)"
      docker exec "$c" bash -lc "export PATH=\$HOME/.lmstudio/bin:\$PATH; lms unload --all >/dev/null 2>&1 || true; lms load '$MODEL' --yes $GPU_OPT --parallel $LMS_PARALLEL --context-length $LMS_CONTEXT_LENGTH" \
        2>&1 | grep -iE 'loaded|error|fail' | head -3
    done
    echo
    echo "[+] 완료. 클라이언트 모델 키도 맞추세요:"
    echo "    - 컨테이너 cc:  start.sh 의 .env LMS_MODEL=$MODEL 로 변경 후 재기동"
    echo "    - VSCode 확장:  LMS_MODEL=$MODEL 반영 후  ./vscode-connect.sh on"
    ;;

  *)
    echo "usage: $0 {probe [model]|verified|use <model>|status}"; exit 2 ;;
esac
