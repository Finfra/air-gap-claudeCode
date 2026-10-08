#!/bin/bash
# LMS 백엔드 컨테이너 PID 1 — llmster headless 데몬 구동 (GUI 없음)
#   시퀀스:
#     1) lms daemon up                         (llmster 데몬 기동)
#     2) lms server start --bind 0.0.0.0        (OpenAI /v1 서버, 컨테이너 외부 접근 허용)
#     3) /v1/models 헬스 폴링 (최대 LMS_HEALTH_TRIES 회)
#     4) lms get -y / lms load ${LMS_MODEL}     (없으면 다운로드 후 로드. 실패해도 컨테이너 유지)
#     5) exec lms log stream                    (PID1 인계, SIGTERM 전파)
set -e

LMS_PORT="${LMS_PORT:-1234}"
LMS_HEALTH_TRIES="${LMS_HEALTH_TRIES:-30}"
export PATH="$HOME/.lmstudio/bin:$PATH"

# 1) llmster 데몬 기동 + 준비 대기 (재기동 시 binary 경합/세그폴트 방지)
echo "[lms] starting llmster daemon ..."
lms daemon up || true
for i in $(seq 1 15); do
  lms daemon status >/dev/null 2>&1 && break
  echo "[lms] waiting for daemon ready (${i}/15)"
  sleep 1
done
sleep 1   # 데몬 안정화 — 직후 server start 의 'Text file busy' 회피

# 1.5) JIT(Just-In-Time) 모델 로딩 비활성화 — ⚠️ 폐쇄망 필수.
#    JIT 가 켜져 있으면(llmster 기본 true) 모델이 로드되지 않은 상태로 요청이 와도 서버가
#    그 자리에서 임의 로드를 시도한다. 그때 적용되는 값은 우리가 지정한 --context-length /
#    --parallel 이 아니라 기본값(ctx 8192 / parallel 4 → 슬롯 2048)이라, Claude Code 의
#    시스템+도구 페이로드가 슬롯을 초과해 400 이 남는다 (prj55 benchmark_lms_report.md 실측).
#    끄면 "모델 없음"이 조용한 오작동 대신 명시적 실패로 드러난다.
#    CLI 플래그가 없어 설정 파일로만 제어 가능. 서버 기동 전에 기록해야 반영됨(실측 확인).
JIT_CFG="$HOME/.lmstudio/.internal/http-server-config.json"
mkdir -p "$(dirname "$JIT_CFG")"
if [ -f "$JIT_CFG" ]; then
  # 기존 설정 보존 — 해당 키만 뒤집는다 (이미지에 jq/python3 없음)
  sed -i 's/"justInTimeModelLoading"[[:space:]]*:[[:space:]]*true/"justInTimeModelLoading": false/' "$JIT_CFG"
  echo "[lms] JIT 모델 로딩 비활성화 (기존 설정 갱신)"
else
  cat > "$JIT_CFG" <<EOF
{
  "autoStartOnLaunch": false,
  "port": ${LMS_PORT},
  "cors": false,
  "logSensitiveData": true,
  "logIncomingTokens": false,
  "verbose": true,
  "logLinesLimit": 500,
  "networkInterface": "0.0.0.0",
  "justInTimeModelLoading": false,
  "fileLoggingMode": "succinct"
}
EOF
  echo "[lms] JIT 모델 로딩 비활성화 (설정 신규 생성)"
fi

# 2) OpenAI 호환 서버 (0.0.0.0 바인딩 → claude 컨테이너에서 접근 가능)
#    'Text file busy' 등 일시 오류 시 짧게 재시도
echo "[lms] starting OpenAI server on 0.0.0.0:${LMS_PORT} ..."
for i in $(seq 1 5); do
  if lms server start --port "${LMS_PORT}" --bind 0.0.0.0; then
    break
  fi
  echo "[lms] server start retry (${i}/5)"
  sleep 2
done

# 3) /v1/models 헬스 폴링 (모델 로드 전에도 200 응답)
echo "[lms] waiting for /v1/models ..."
TRIES=0
until curl -fsS "http://127.0.0.1:${LMS_PORT}/v1/models" >/dev/null 2>&1; do
  TRIES=$((TRIES+1))
  if [ "$TRIES" -ge "$LMS_HEALTH_TRIES" ]; then
    echo "[lms] ERROR: server not ready after $((LMS_HEALTH_TRIES*2))s" >&2
    exit 1
  fi
  echo "[lms] server unavailable - sleeping (${TRIES}/${LMS_HEALTH_TRIES})"
  sleep 2
done
echo "[lms] server is up"

# 3.2) 바인딩 검증 — ⚠️ '--bind 0.0.0.0' 이 반영되지 않는 사례가 실측됨(prj55 fg1/lms:
#      방화벽 무관하게 llmster 가 127.0.0.1 로만 LISTEN). 이 경우 컨테이너 내부 curl 은
#      성공하지만 nginx 가 lms-N:1234 로 붙지 못해 스택 전체가 죽는다 — 즉 위의 헬스체크로는
#      절대 안 잡히는 고장이다. 여기서 fail-loud 로 잡는다.
#      (이미지에 ss/netstat 이 없어 /proc/net/tcp 를 직접 읽음. 상태 0A = LISTEN)
PORT_HEX="$(printf '%04X' "${LMS_PORT}")"
LISTEN_ADDRS="$(awk -v ph="$PORT_HEX" '$4=="0A"{split($2,a,":"); if(a[2]==ph) print a[1]}' \
  /proc/net/tcp /proc/net/tcp6 2>/dev/null)"
if [ -z "$LISTEN_ADDRS" ]; then
  echo "[lms] WARNING: /proc/net/tcp 에서 :${LMS_PORT} LISTEN 을 찾지 못함 — 바인딩 검증 생략"
elif echo "$LISTEN_ADDRS" | grep -qE '^(00000000|00000000000000000000000000000000)$'; then
  echo "[lms] bind OK — 0.0.0.0:${LMS_PORT} (컨테이너 외부 접근 가능)"
else
  echo "[lms] ERROR: :${LMS_PORT} 이 loopback 전용으로 바인딩됨 (addr=${LISTEN_ADDRS})." >&2
  echo "[lms]        '--bind 0.0.0.0' 미반영 — nginx 가 lms 백엔드에 접속하지 못합니다." >&2
  echo "[lms]        조치: 컨테이너 재기동. 반복되면 'lms server stop && lms server start" >&2
  echo "[lms]        --port ${LMS_PORT} --bind 0.0.0.0' 를 수동 실행해 재현 여부 확인." >&2
  exit 1
fi

# 3.5) GPU(CUDA) 런타임 자동 선택 — llmster 는 CUDA 백엔드를 설치해도 기본 SELECTED 가
#      CPU(avx2) 인 경우가 있어, --gpu max 여도 CPU 로 추론 → 대형 모델(예: 31B)이 극도로
#      느려 응답 타임아웃(504). LMS_GPU!=off 이고 GPU 가 보이면 CUDA 런타임을 선택한다.
#      (검증: nvidia-smi 로 VRAM 사용 확인. CUDA 미설치면 경고 후 CPU 로 계속.)
#
# ★ v2 차이점 — CUDA 런타임 라이브러리 프리플라이트 (fail-loud).
#   6.lms_MultiLLM_run 반입 실패의 주 원인이 여기였다:
#     "Failed to load LLM engine ... llm_cuda.node: 'libcudart.so.11.0':
#      cannot open shared object file: no such file or directory"
#   → CUDA 백엔드(llama.cpp-*-nvidia-cuda-avx2-2.23.1)는 CUDA 11 런타임(libcudart.so.11.0)을
#     요구하는데 호스트/컨테이너에 그 버전이 없어(대개 CUDA 12만 설치) 엔진 로드가 죽었다.
#   v2 는 prj55#Issue9 에서 CUDA 11 런타임을 설치한 뒤 진행하는 재시도본이므로,
#   CUDA 엔진을 선택하기 전에 libcudart.so.11.0 해석 가능 여부를 먼저 검증하고,
#   실패하면 CPU 로 조용히 넘어가지 않고 명시적으로 중단한다(LMS_REQUIRE_CUDA=1 기본).
if [ "${LMS_GPU:-max}" != "off" ]; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    CUDA_ENGINE="$(lms runtime ls 2>/dev/null | grep -iE 'nvidia-cuda' | awk '{print $1}' | head -1)"
    if [ -n "$CUDA_ENGINE" ]; then
      # 프리플라이트: CUDA 엔진 .node 의 동적 링크를 검사해 libcudart.so.11.0 미해결을 잡는다.
      CUDA_NODE="$(find "$HOME/.lmstudio/extensions/backends" -name 'llm_cuda.node' 2>/dev/null | head -1)"
      CUDART_OK=1
      if command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q 'libcudart\.so\.11'; then
        CUDART_OK=1
      elif [ -n "$CUDA_NODE" ] && command -v ldd >/dev/null 2>&1 \
           && ldd "$CUDA_NODE" 2>/dev/null | grep -q 'libcudart\.so\.11.*not found'; then
        CUDART_OK=0
      elif ! (command -v ldconfig >/dev/null 2>&1); then
        CUDART_OK=1   # ldconfig 부재 → 검사 불가, 선택 시도로 위임
      fi

      if [ "$CUDART_OK" = "0" ]; then
        echo "[lms] ERROR: CUDA 백엔드가 libcudart.so.11.0 을 해석하지 못함 (CUDA 11 런타임 부재)." >&2
        echo "[lms]        이것이 6.lms_MultiLLM_run 반입 실패의 주 원인이었다." >&2
        echo "[lms]        조치: prj55#Issue9 (CUDA 11 런타임 설치)를 먼저 완료할 것." >&2
        echo "[lms]        엔진: ${CUDA_NODE:-'(llm_cuda.node 미발견)'}" >&2
        if [ "${LMS_REQUIRE_CUDA:-1}" = "1" ]; then
          echo "[lms]        LMS_REQUIRE_CUDA=1 — CPU 폴백 금지, 중단." >&2
          exit 1
        fi
        echo "[lms]        LMS_REQUIRE_CUDA=0 — CPU(avx2)로 계속 (대형 모델 매우 느림)." >&2
      else
        echo "[lms] CUDA 런타임 프리플라이트 통과 (libcudart.so.11 해석 가능)"
        echo "[lms] selecting GPU runtime: ${CUDA_ENGINE}"
        lms runtime select "${CUDA_ENGINE}" || echo "[lms] WARNING: 'lms runtime select' 실패 (계속 진행)"
      fi
    else
      echo "[lms] WARNING: CUDA 런타임 미설치 — CPU(avx2)로 동작, 대형 모델 매우 느림"
      [ "${LMS_REQUIRE_CUDA:-1}" = "1" ] && { echo "[lms] LMS_REQUIRE_CUDA=1 — 중단 (prj55#Issue9 확인)" >&2; exit 1; }
    fi
  else
    echo "[lms] note: GPU 미감지 — CPU 로 동작(LMS_GPU=${LMS_GPU:-max})"
  fi
fi

# 4) 모델 다운로드(없으면) + 로드 — 실패해도 컨테이너 유지 (docker exec 로 수동 가능)
#    LMS_CONTEXT_LENGTH: 컨텍스트 토큰 상한. Claude Code 는 시스템+도구 페이로드가 크므로
#                        에이전트 용도면 32768 이상 권장 (기본 8192 로는 부족).
#    LMS_GPU: GPU offload 비율 ("max"/"off"/0~1). 기본 max.
if [ -n "${LMS_MODEL:-}" ]; then
  LOAD_OPTS="--yes"
  [ -n "${LMS_CONTEXT_LENGTH:-}" ] && LOAD_OPTS="$LOAD_OPTS --context-length ${LMS_CONTEXT_LENGTH}"
  [ -n "${LMS_GPU:-}" ] && LOAD_OPTS="$LOAD_OPTS --gpu ${LMS_GPU}"
  # LMS_PARALLEL: 동시 예측 슬롯 수. llmster 는 컨텍스트를 슬롯 수로 "분할"하므로
  #   기본값(4)이면 슬롯당 ctx/4 (32k→8k). Claude Code 시스템 프롬프트(~16k)가 슬롯을
  #   초과해 500 (n_keep >= n_ctx) 발생. Claude Code 용도면 1 필수.
  [ -n "${LMS_PARALLEL:-}" ] && LOAD_OPTS="$LOAD_OPTS --parallel ${LMS_PARALLEL}"
  # 모델 확보 — ⚠️ 폐쇄망 필수 처리.
  #   'lms get' 은 로컬에 모델이 있어도 LM Studio 허브에 존재 확인을 보냄.
  #   blackhole 방화벽(패킷 drop) 환경에서는 '실패'가 아니라 수 분간 hang 하므로
  #   '|| echo' 폴백이 작동하지 않고 아래 'lms load' 까지 도달하지 못함
  #   → 백엔드는 떠 있는데 모델만 없는 조용한 부분 실패 발생 (2026-07-18 실측).
  #   대책 ① 로컬 보유 시 건너뜀  ② 그래도 호출 시 timeout 으로 상한.
  #   LMS_SKIP_GET=1 이면 무조건 건너뜀 (완전 폐쇄망 권장).
  if [ "${LMS_SKIP_GET:-0}" = "1" ]; then
    echo "[lms] LMS_SKIP_GET=1 — 'lms get' 건너뜀 (로컬 모델만 사용)"
  elif lms ls 2>/dev/null | grep -qiF "${LMS_MODEL##*/}"; then
    # stem(마지막 경로조각)으로 검사 — 로컬 키가 허브 키와 다를 수 있음(아래 폴백 주석 참조)
    echo "[lms] model already present locally — 'lms get' 건너뜀: ${LMS_MODEL}"
  else
    echo "[lms] ensuring model present: ${LMS_MODEL} (timeout ${LMS_GET_TIMEOUT:-60}s)"
    timeout "${LMS_GET_TIMEOUT:-60}" lms get -y "${LMS_MODEL}" \
      || echo "[lms] WARNING: 'lms get' 실패/타임아웃 — 로컬 모델로 로드 시도 (폐쇄망이면 정상)"
  fi
  echo "[lms] loading model: ${LMS_MODEL} (opts: ${LOAD_OPTS})"
  if ! lms load "${LMS_MODEL}" ${LOAD_OPTS}; then
    # 폐쇄망 폴백 — 허브 키가 로컬에서 해석되지 않는 경우가 있음.
    #   매니페스트 없이 gguf 만 반입한 모델은 'lms ls' 가 파일명 기반 키로 표시함
    #   (예: 허브 키 google/gemma-4-e2b → 로컬 키 gemma-4-e2b-it). 2026-07-18 실측.
    #   LMS_MODEL 의 마지막 경로조각을 stem 으로 잡아 로컬 키를 역탐색해 재시도.
    STEM="${LMS_MODEL##*/}"
    ALT="$(lms ls 2>/dev/null | awk -v s="$STEM" 'tolower($1) ~ tolower(s) {print $1; exit}')"
    if [ -n "$ALT" ] && [ "$ALT" != "${LMS_MODEL}" ]; then
      echo "[lms] 허브 키 로드 실패 → 로컬 키로 재시도: ${ALT}"
      lms load "$ALT" ${LOAD_OPTS} \
        && echo "[lms] NOTE: 실제 로드된 키는 '${ALT}' — 클라이언트의 ANTHROPIC_MODEL 도 이 값이어야 함" \
        || echo "[lms] WARNING: model load failed - container stays up for manual 'lms load'"
    else
      echo "[lms] WARNING: model load failed - container stays up for manual 'lms load'"
    fi
  fi
else
  echo "[lms] WARNING: LMS_MODEL empty - skipping load (use 'docker exec ... lms load <model>')"
fi

# 5) 로그 스트림으로 PID1 인계 (SIGTERM 전파, 컨테이너 foreground 유지)
echo "[lms] handing off to 'lms log stream' (PID1)"
exec lms log stream
