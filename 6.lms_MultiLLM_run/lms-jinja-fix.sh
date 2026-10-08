#!/usr/bin/env bash
# lms-jinja-fix.sh — Claude Code ↔ LM Studio "Jinja 템플릿 오류" 진단 / 우회
#
#   ⚠️ step5 기초 참고 스크립트. 서버측(step4 스택) 진단용이며, Windows 클라이언트에서는 실행하지 않는다.
#      step5 는 서버 스택을 손대지 않으므로, 이 스크립트는 step4 의 .env 를 읽어 이미 떠 있는
#      게이트웨이·백엔드(lms-1..N)를 진단한다.
#
#   증상:
#     500 {"error":{"message":"Error rendering prompt with jinja template:
#          \"Cannot perform operation ~ on undefined values\" ..."}}
#     → 일부 모델의 embedded Jinja chat template 이 Claude Code 의 tools/system
#       페이로드를 렌더하지 못해 발생. (컨테이너 cc 든 Windows 확장이든 동일)
#     상세: info_jinja_and_lms.md
#
#   해결책:
#     ① 검증된 모델 사용  ← 헤드리스 권장 (보안망: Google/gemma 계열만)
#     ② prompt template 편집 (`| string` 필터 제거 등) ← GUI/고급, info_jinja_and_lms.md §2 참조
#
#   사용:
#     ./lms-jinja-fix.sh probe [model]   # 지정(또는 현재 로드) 모델의 jinja 오류 진단
#     ./lms-jinja-fix.sh verified        # 검증된 모델 목록 출력
#     ./lms-jinja-fix.sh use <model>     # 전 LMS 백엔드에서 언로드 후 검증 모델 로드
#     ./lms-jinja-fix.sh status          # 로드 상태
#
#   환경변수: step4.cc_gw_lms2/.env 를 자동 로드 (GATEWAY_PORT·LMS_CONTEXT_LENGTH·LMS_GPU 등)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# step4 의 .env 를 그대로 읽는다 — step5 는 별도 설정을 갖지 않는다(같은 스택이므로).
#   이 스크립트는 6.lms_MultiLLM_run/ 루트에 있고, .env 는 step4 하위에 있다.
ENV_FILE="${SCRIPT_DIR}/step4.cc_gw_lms2/.env"
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a
: "${GATEWAY_PORT:=8080}"
: "${LMS_PORT:=1234}"
: "${LMS_CONTEXT_LENGTH:=32768}"
# LMS_GPU 빈값 = llmster 자동 offload (VRAM<모델 환경에서 max 는 CUDA OOM — .env 정책과 동일)
: "${LMS_GPU:=}"
: "${LMS_PARALLEL:=1}"

# 검증(문서 기준) 모델 — ⚠️ 보안 정책상 중국계(Qwen/GLM) 제외, Google 계열만.
#   참고: gemma-4-31b-qat 이 느렸던 원인은 jinja 가 아니라 GPU offload 미동작(CPU 추론)이었음.
#         → info_jinja_and_lms.md 참조. 실제 해결 레버는 'lms runtime select CUDA' + 충분한 VRAM.
VERIFIED=( "gemma-4-e2b-it" "google/gemma-4-31b-qat" "google/gemma-4-26b-a4b" )

# 실행 중인 LMS 백엔드 컨테이너들 (step4 run.sh: lms-1..N)
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
      c="$(first_backend)"; [ -n "$c" ] || die "실행 중 LMS 백엔드 없음 — step4 run.sh 로 기동"
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
      echo "    → 해결: './lms-jinja-fix.sh use <검증모델>' (아래) 또는 info_jinja_and_lms.md §2 템플릿 편집."
      echo "    검증 모델: ${VERIFIED[*]}"
      exit 1
    elif echo "$body" | grep -qiE '"choices"|"content"|tool_calls'; then
      echo "[✓] 정상 응답 — jinja 오류 없음. Claude Code 사용 가능."
    else
      echo "[~] jinja 오류 문자열은 없음(생성 지연/타임아웃 가능). 응답 일부:"
      echo "    $(echo "$body" | head -c 200)"
      echo "    (오류가 아니면 정상 — 큰 모델은 첫 응답이 느릴 수 있음. GPU offload 확인: info_jinja_and_lms.md §3)"
    fi
    ;;

  use)
    MODEL="${2:-}"; [ -n "$MODEL" ] || die "usage: $0 use <model>"
    backs="$(lms_backends)"; [ -n "$backs" ] || die "실행 중 LMS 백엔드 없음 — step4 run.sh 로 기동"
    GPU_OPT=""; [ -n "$LMS_GPU" ] && GPU_OPT="--gpu $LMS_GPU"
    for c in $backs; do
      echo "[*] $c: 언로드 → $MODEL 로드 (ctx=$LMS_CONTEXT_LENGTH, gpu=${LMS_GPU:-auto}, parallel=$LMS_PARALLEL)"
      docker exec "$c" bash -lc "export PATH=\$HOME/.lmstudio/bin:\$PATH; lms unload --all >/dev/null 2>&1 || true; lms load '$MODEL' --yes $GPU_OPT --parallel $LMS_PARALLEL --context-length $LMS_CONTEXT_LENGTH" \
        2>&1 | grep -iE 'loaded|error|fail' | head -3
    done
    echo
    echo "[+] 완료. 클라이언트 모델 키도 맞추세요:"
    echo "    - 컨테이너 cc:   step4.cc_gw_lms2/.env 의 LMS_MODEL=$MODEL 로 변경 후 run.sh 재기동"
    echo "    - Windows 확장:  %USERPROFILE%\\.claude\\settings.json 의 \"model\" 을 $MODEL 로 변경 후"
    echo "                     새 터미널에서 claude 실행 (또는 VSCode: Developer: Reload Window)"
    echo "                     상세: step5.win_gw_lms2/README.md"
    ;;

  *)
    echo "usage: $0 {probe [model]|verified|use <model>|status}"; exit 2 ;;
esac
