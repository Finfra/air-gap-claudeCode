#!/bin/bash
# step4/run.sh — docker cc → gateway → lms-1, lms-2
#
# 이 단계가 세우는 것: 네트워크 + lms-1..N + gateway + claude.
#   step3 대비 추가된 변수는 "백엔드 다중화" 하나뿐 → 실패하면 원인은 분산·세션 고정 쪽.
#
# 사용:
#   cp .env.org .env && vi .env
#   ./run.sh              # 기동
#   ./run.sh --stop       # 정지 + 제거
#   ./run.sh --status     # 상태
#   ./run.sh --check      # 게이트 판정 (백엔드 도달 · shim · VRAM)
#   ./run.sh --nginx-test # 기동 전 nginx 설정 정적 검증
#   ./run.sh --distribute # 분산 실측 — 헤더 없는 요청이 두 백엔드에 나뉘는가 (게이트 2)
#   ./run.sh --affinity   # 세션 고정 실측 — 같은 X-Session 이 한 백엔드에만 가는가 (게이트 3)
#   ./run.sh --sse        # SSE 스트리밍 실측
#   ./run.sh --resilience # 백엔드 재기동 내성
#   ./run.sh --logs       # gateway 로그 추적

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
else
  echo "[warn] $ENV_FILE 없음 — 기본값 사용 (cp .env.org .env 권장)"
fi

: "${LMS_MODEL:=gemma-4-e2b-it}"
: "${LMS_PORT:=1234}"
: "${LMS_HEALTH_TRIES:=30}"
: "${LMS_CONTEXT_LENGTH:=32768}"
: "${LMS_GPU:=max}"
: "${LMS_PARALLEL:=1}"
: "${LMS_SKIP_GET:=1}"
: "${LMS_GET_TIMEOUT:=60}"
: "${LMS_MODEL_MOUNT:=}"
: "${LMS_BACKEND_COUNT:=2}"
: "${LMS_ALLOW_GPU_OVERSUBSCRIBE:=0}"
: "${GATEWAY_PORT:=8080}"
: "${GATEWAY_BIND_HOST:=127.0.0.1}"
: "${GATEWAY_INTERNAL_PORT:=8080}"
: "${CLAUDE_MAX_OUTPUT_TOKENS:=8192}"
: "${CLAUDE_DIET:=1}"
: "${API_TIMEOUT_MS:=600000}"
: "${MOUNT_CODE_DIR:=}"
: "${GATEWAY_CONTAINER_NAME:=gateway}"
: "${CLAUDE_CONTAINER_NAME:=cc-step4}"
: "${LMS_NETWORK_NAME:=lms-step4}"
: "${LMS_IMAGE:=lms:small}"
: "${GATEWAY_IMAGE:=lms-gateway:latest}"
: "${CLAUDE_IMAGE:=claude:latest}"
: "${TZ:=Asia/Seoul}"
: "${USE_GPU:=1}"

CLAUDE_HOME_VOLUME="cc-step4-home"
GW_URL="http://127.0.0.1:${GATEWAY_PORT}"

# 백엔드별 로그 줄 수 — 어느 백엔드가 요청을 처리했는지 세는 데 쓴다.
#   (LMS 는 요청마다 로그를 남기므로, 요청 전후 줄 수 델타가 곧 처리 건수의 근사치다)
backend_loglines() {
  local i
  for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
    printf '%s ' "$(docker logs "lms-$i" 2>&1 | wc -l)"
  done
}

# 게이트웨이로 chat 요청 1건 — $1 이 비어 있지 않으면 X-Session 헤더로 붙인다
gw_chat() {
  local sess="${1:-}" hdr=()
  [ -n "$sess" ] && hdr=(-H "X-Session: $sess")
  curl -s -o /dev/null --max-time 120 "${GW_URL}/v1/chat/completions" \
    -H 'Content-Type: application/json' "${hdr[@]}" \
    -d "{\"model\":\"${LMS_MODEL}\",\"max_tokens\":4,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
}

# upstream 서버 목록 생성 —
#   ⚠️ 단일 'server lms:1234 resolve' 로 DNS 복제본을 쓰면 nginx 가 해석된 IP 들을 hash
#      대상으로 구분하지 못해 라운드로빈이 된다(affinity 무효, 실측). step3 은 백엔드가
#      1개라 체감되지 않지만, step4 에서 그대로 승계되므로 처음부터 개별 엔트리로 만든다.
build_upstream() {
  local out="" i
  for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
    out="${out}    server lms-$i:${LMS_PORT} resolve max_fails=3 fail_timeout=30s;
"
  done
  printf '%s' "$out"
}

# ── 서브커맨드 ─────────────────────────────────────────────────────────────
case "${1:-}" in
  --stop|stop)
    for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
      docker rm -f "lms-$i" >/dev/null 2>&1 || true
    done
    docker rm -f "$GATEWAY_CONTAINER_NAME" "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "[+] 컨테이너 제거 (네트워크·볼륨 유지)"
    echo "    완전 정리: docker network rm $LMS_NETWORK_NAME; docker volume rm $CLAUDE_HOME_VOLUME"
    exit 0 ;;
  --status|status)
    docker ps -a --filter "network=$LMS_NETWORK_NAME" \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    exit 0 ;;
  --logs|logs)
    exec docker logs -f "$GATEWAY_CONTAINER_NAME" ;;

  --nginx-test|nginx-test)
    # 게이트 1 — 기동 전 정적 검증. 컨테이너를 세우기 전에 설정 오류를 잡는다.
    echo "[게이트 1] nginx 설정 정적 검증 (envsubst 전개 후 nginx -t)"
    # ⚠️ bare 'envsubst' 를 쓰면 안 된다. nginx 설정에는 nginx 자신의 런타임 변수
    #    ($http_x_session, $request_id, $host ...)가 있는데, 인자 없는 envsubst 는
    #    그것까지 환경변수로 보고 **빈 문자열로 치환**한다. 그러면 'map  {' 처럼 인자가
    #    사라져 'invalid number of arguments in "map" directive' 로 실패한다 —
    #    설정은 멀쩡한데 검증만 실패하는 가짜 경보다 (2026-07-20 실측).
    #    nginx 공식 이미지의 entrypoint 도 치환 대상을 명시 목록으로 한정한다.
    #    여기서도 동일하게 우리가 주입하는 2개만 한정한다.
    docker run --rm \
      -v "$SCRIPT_DIR/nginx.conf.template:/tmp/default.conf.template:ro" \
      -e LMS_PORT="$LMS_PORT" \
      -e LMS_UPSTREAM_SERVERS="$(build_upstream)" \
      "$GATEWAY_IMAGE" \
      sh -c 'envsubst "\${LMS_PORT} \${LMS_UPSTREAM_SERVERS}" \
               < /tmp/default.conf.template > /etc/nginx/conf.d/default.conf && nginx -t'
    exit $? ;;

  --distribute|distribute)
    # 게이트 2 — 헤더 없는 요청은 $request_id 로 해시되어 매 요청 흩어져야 한다.
    #   한쪽으로 몰리면 upstream 이 단일 엔트리이거나 hash 키가 고정된 것.
    set +e; set +o pipefail
    N="${2:-10}"
    echo "[게이트 2] 헤더 없는 요청 ${N}건 — 두 백엔드에 나뉘어야 정상"
    read -r -a BEFORE <<< "$(backend_loglines)"
    for _ in $(seq 1 "$N"); do gw_chat ""; done
    sleep 2
    read -r -a AFTER <<< "$(backend_loglines)"
    HIT=0
    for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
      D=$(( AFTER[i-1] - BEFORE[i-1] ))
      echo "  lms-$i : +${D} 로그줄"
      [ "$D" -gt 0 ] && HIT=$((HIT+1))
    done
    if [ "$HIT" -ge 2 ]; then echo "  ✅ ${HIT}개 백엔드가 처리 — 분산 동작"; exit 0
    else echo "  ❌ 한 백엔드에만 몰림 — upstream 이 개별 server 엔트리인지 확인"; exit 1; fi ;;

  --affinity|affinity)
    # 게이트 3 — 같은 X-Session 은 consistent hash 로 항상 같은 백엔드에 가야 한다.
    #   무효면 에러 없이 매 턴 전체 컨텍스트 재프리필(~13배 지연)이 발생한다.
    set +e; set +o pipefail
    N="${2:-10}"
    RC=0
    for SESS in affinity-A affinity-B; do
      echo "[게이트 3] X-Session: ${SESS} 로 ${N}건 — 한 백엔드에만 가야 정상"
      read -r -a BEFORE <<< "$(backend_loglines)"
      for _ in $(seq 1 "$N"); do gw_chat "$SESS"; done
      sleep 2
      read -r -a AFTER <<< "$(backend_loglines)"
      HIT=0
      for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
        D=$(( AFTER[i-1] - BEFORE[i-1] ))
        echo "  lms-$i : +${D} 로그줄"
        [ "$D" -gt 0 ] && HIT=$((HIT+1))
      done
      if [ "$HIT" -eq 1 ]; then echo "  ✅ 단일 백엔드 고정"
      else echo "  ❌ ${HIT}개 백엔드에 분산 — 세션 고정 실패"; RC=1; fi
    done
    exit $RC ;;

  --spread|spread)
    # 게이트 3-2 — 여러 세션 키가 두 백엔드에 **모두** 배정되는가.
    #   --affinity 는 "한 세션이 한 백엔드에 고정"만 본다. 그것만으로는 '모든 세션이
    #   한 백엔드로 몰리는' 고장(= 사실상 단일 백엔드)과 구분되지 않는다.
    #   ⚠️ consistent hash 는 라운드로빈이 아니다 — 세션 수가 적으면 배분이 고르지 않은
    #      것이 정상이다(실측: 8세션 → 2:6). 판정 기준은 '균등'이 아니라 '양쪽 모두 사용'.
    set +e; set +o pipefail
    KEYS="${2:-s1 s2 s3 s4 s5 s6 s7 s8}"
    echo "[게이트 3-2] 세션 키별 배정 백엔드 (양쪽 모두 나와야 정상)"
    declare -A USED=()
    for S in $KEYS; do
      read -r -a BEFORE <<< "$(backend_loglines)"
      for _ in 1 2 3; do gw_chat "$S"; done
      sleep 1
      read -r -a AFTER <<< "$(backend_loglines)"
      WHO=""; MULTI=0
      for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
        [ $(( AFTER[i-1] - BEFORE[i-1] )) -gt 0 ] && { [ -n "$WHO" ] && MULTI=1; WHO="lms-$i"; }
      done
      if [ "$MULTI" = "1" ]; then
        echo "  $S → ❌ 여러 백엔드에 분산 (세션 고정 실패)"; RC=1
      else
        echo "  $S → $WHO"; USED[$WHO]=1
      fi
    done
    echo "  사용된 백엔드: ${!USED[*]} (${#USED[@]}/${LMS_BACKEND_COUNT})"
    if [ "${#USED[@]}" -ge 2 ]; then
      echo "  ✅ 두 백엔드 모두 세션을 배정받음"; exit 0
    else
      echo "  ❌ 한 백엔드만 사용됨 — 나머지는 유휴. hash 키/upstream 엔트리 확인"; exit 1
    fi ;;

  --sse|sse)
    # 게이트 4 — SSE 스트리밍. proxy_buffering 이 살아 있으면 청크가 한꺼번에 도착한다.
    #   도착 시각을 찍어 '분산 도착'인지 '몰려 도착'인지 눈으로 판정한다.
    echo "[게이트 4] SSE 스트리밍 — data: 청크 도착 시각 (분산돼야 정상)"
    START=$(date +%s.%N)
    curl -N -s --max-time 180 "${GW_URL}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${LMS_MODEL}\",\"stream\":true,\"max_tokens\":120,\"messages\":[{\"role\":\"user\",\"content\":\"Count slowly from 1 to 40, one number per line.\"}]}" \
      | grep --line-buffered '^data:' \
      | awk -v s="$START" '{ "date +%s.%N" | getline now; close("date +%s.%N");
                             printf "  +%.2fs  chunk %d\n", now-s, ++n }' \
      | awk 'NR<=3 || NR%10==0 {print} END{printf "  총 %d 청크\n", NR}'
    echo "  판정: 첫 청크와 마지막 청크의 +초 가 벌어져 있으면 ✅ (모두 같은 시각이면 버퍼링 ❌)"
    exit 0 ;;

  --resilience|resilience)
    # 게이트 6 — 백엔드 재기동 내성. zone+resolve 가 없으면 부팅 시점 IP 를 영구 보존해
    #   백엔드 재생성 후 계속 502 가 난다 (실측).
    echo "[게이트 6] lms-1 재기동 후 게이트웨이 복구 (30s 내)"
    docker restart lms-1 >/dev/null
    echo "  · lms-1 재기동함 — 백엔드 준비까지 대기"
    TRIES=0
    until docker exec lms-1 curl -fsS "http://127.0.0.1:${LMS_PORT}/v1/models" >/dev/null 2>&1; do
      TRIES=$((TRIES+1)); [ "$TRIES" -ge 120 ] && { echo "  ❌ lms-1 자체가 복구 안 됨"; exit 1; }
      sleep 2
    done
    echo "  · lms-1 ready — 게이트웨이 복구 측정 시작"
    T0=$(date +%s); TRIES=0
    until curl -fsS "${GW_URL}/v1/models" >/dev/null 2>&1; do
      TRIES=$((TRIES+1))
      if [ "$TRIES" -ge 15 ]; then
        echo "  ❌ 30s 내 복구 실패 — zone/resolve 쌍 확인 (docker logs $GATEWAY_CONTAINER_NAME)"
        exit 1
      fi
      sleep 2
    done
    echo "  ✅ $(( $(date +%s) - T0 ))s 만에 게이트웨이 복구"
    exit 0 ;;

  --check|check)
    # 진단 경로에서는 errexit/pipefail 을 끈다 (첫 실패에서 나머지 게이트를 잃지 않도록).
    set +e; set +o pipefail
    RC=0

    echo "[게이트 2] 호스트 → 게이트웨이 /v1/models"
    if curl -fsS --max-time 10 "${GW_URL}/v1/models" >/dev/null 2>&1; then
      echo "  ✅ 200"
      curl -fsS "${GW_URL}/v1/models" | head -c 200; echo
    else
      echo "  ❌ 실패 — docker logs $GATEWAY_CONTAINER_NAME"
      docker logs "$GATEWAY_CONTAINER_NAME" 2>&1 | tail -5 | sed 's/^/     /'
      RC=1
    fi

    echo "[게이트 3] cc 컨테이너 → ${GATEWAY_CONTAINER_NAME}:${GATEWAY_INTERNAL_PORT}/v1/models"
    if docker exec "$CLAUDE_CONTAINER_NAME" \
         curl -fsS "http://${GATEWAY_CONTAINER_NAME}:${GATEWAY_INTERNAL_PORT}/v1/models" >/dev/null 2>&1; then
      echo "  ✅ 200"
    else
      echo "  ❌ 실패 — 같은 네트워크인지 확인"
      RC=1
    fi

    echo "[참고] 백엔드 직접 도달 (게이트웨이 우회)"
    for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
      if docker exec "$CLAUDE_CONTAINER_NAME" \
           curl -fsS "http://lms-$i:${LMS_PORT}/v1/models" >/dev/null 2>&1; then
        echo "  ✅ lms-$i 200"
      else
        echo "  ❌ lms-$i 도달 실패 — 게이트웨이가 아니라 백엔드 문제 (step2 로 회귀)"
        RC=1
      fi
    done

    echo "[참고] 전개된 nginx 설정의 핵심 지시어"
    docker exec "$GATEWAY_CONTAINER_NAME" \
      grep -E 'proxy_buffering|proxy_read_timeout|client_max_body_size|hash |zone |server lms' \
      /etc/nginx/conf.d/default.conf 2>/dev/null | sed 's/^/     /'

    echo "[게이트 4] affinity shim (PATH 선순위)"
    WHICH="$(docker exec "$CLAUDE_CONTAINER_NAME" which claude 2>/dev/null)"
    if [ "$WHICH" = "/home/ubuntu/.local/bin/claude" ]; then
      echo "  ✅ $WHICH"
    else
      echo "  ❌ '$WHICH' — shim 이 앞서지 않음. docker run 의 -e PATH 확인"
      RC=1
    fi
    # settings.json 에 정적 X-Session 이 박히면 모든 세션이 한 백엔드로 몰려 분산이 죽는다
    if docker exec "$CLAUDE_CONTAINER_NAME" \
         grep -q 'ANTHROPIC_CUSTOM_HEADERS' /home/ubuntu/.claude/settings.json 2>/dev/null; then
      echo "  ❌ settings.json 에 정적 X-Session 존재 — 전 세션이 한 백엔드로 고정됨"
      RC=1
    else
      echo "  ✅ settings.json 에 정적 헤더 없음 (세션별 고유값 유지)"
    fi

    echo "[게이트 5 보조] VRAM (83% 안전선)"
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader \
        | awk -F'[ ,]+' '{pct=$3/$1*100; printf "  %s/%s MiB = %.1f%% %s\n", $3, $1, pct, (pct<=83?"✅":"❌ 안전선 초과")}'
    fi

    echo
    echo "  남은 게이트: 2(--distribute) · 3(--affinity) · 동시 2세션(수동)"
    exit $RC ;;

  --help|-h|help)
    grep -E '^# ' "$0" | sed 's/^# \?//'
    exit 0 ;;
esac

# ── 사전 확인 ──────────────────────────────────────────────────────────────
for f in entrypoint.lms.sh entrypoint.cc.sh nginx.conf.template; do
  [ -f "$SCRIPT_DIR/$f" ] || { echo "[!] $SCRIPT_DIR/$f 없음"; exit 1; }
done

for img in "$LMS_IMAGE" "$GATEWAY_IMAGE" "$CLAUDE_IMAGE"; do
  docker image inspect "$img" >/dev/null 2>&1 \
    || { echo "[!] 이미지 '$img' 없음 — 'docker load -i <tar>' 후 재시도"; exit 1; }
done

if [ "$LMS_BACKEND_COUNT" -lt 2 ]; then
  echo "[!] step4 는 다중 백엔드를 검증하는 단계 — LMS_BACKEND_COUNT 는 2 이상이어야 함."
  echo "    단일 백엔드 게이트웨이 검증은 step3.cc_gw_lms 소관."
  exit 1
fi

GPU_COUNT=0
if command -v nvidia-smi >/dev/null 2>&1 && [ "$USE_GPU" = "1" ]; then
  USED_MIB="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
  if [ "${USED_MIB:-0}" -gt 1024 ]; then
    echo "[!] GPU 가 이미 ${USED_MIB} MiB 사용 중 — 호스트 LM Studio 또는 다른 단계의 컨테이너 점유."
    echo "    해제: lms unload --all && lms server stop  /  이전 단계 ./run.sh --stop"
    exit 1
  fi

  GPU_COUNT="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
  : "${GPU_COUNT:=0}"
  echo "[*] 감지된 GPU: ${GPU_COUNT}장 / 백엔드: ${LMS_BACKEND_COUNT}개"
  if [ "$GPU_COUNT" -eq 0 ]; then
    echo "[!] nvidia-smi 로 GPU 를 찾지 못함 — '--gpus all' 로 진행 (드라이버/toolkit 확인 필요)"
  elif [ "$LMS_BACKEND_COUNT" -gt "$GPU_COUNT" ]; then
    # 초과 구독 = OOM 경로. 기본은 정지시키고, 의도적일 때만 명시 승인으로 통과.
    echo "[!] 백엔드(${LMS_BACKEND_COUNT}) > GPU(${GPU_COUNT}) — 같은 GPU 에 다중 적재되어 VRAM 초과 위험."
    echo "    권장: LMS_BACKEND_COUNT 를 ${GPU_COUNT} 이하로 낮출 것."
    echo "    (VRAM 이 (모델+KV)×백엔드 를 확실히 감당한다면 LMS_ALLOW_GPU_OVERSUBSCRIBE=1 로 강행)"
    [ "${LMS_ALLOW_GPU_OVERSUBSCRIBE}" = "1" ] || exit 1
    echo "[!] LMS_ALLOW_GPU_OVERSUBSCRIBE=1 — 초과 구독 강행. 로드 후 VRAM ≤83% 를 반드시 확인할 것."
  fi
fi

# ── 0) nginx 설정 정적 검증 (기동 전) ──────────────────────────────────────
echo "[*] nginx 설정 정적 검증"
if ! "$0" --nginx-test >/dev/null 2>&1; then
  echo "[!] nginx -t 실패 — 상세: $0 --nginx-test"
  exit 1
fi
echo "[+] nginx -t 통과"

# ── 1) 네트워크 ────────────────────────────────────────────────────────────
docker network inspect "$LMS_NETWORK_NAME" >/dev/null 2>&1 \
  || { docker network create "$LMS_NETWORK_NAME" >/dev/null; echo "[+] network 생성: $LMS_NETWORK_NAME"; }

# ── 2) 모델 마운트 결정 ────────────────────────────────────────────────────
MODEL_MOUNT_OPT=()
if [ -n "$LMS_MODEL_MOUNT" ]; then
  if [[ "$LMS_MODEL_MOUNT" == /* || "$LMS_MODEL_MOUNT" == \~* ]]; then
    HOST_MODEL_DIR="${LMS_MODEL_MOUNT/#\~/$HOME}"
    mkdir -p "$HOST_MODEL_DIR"
    MODEL_MOUNT_OPT=(-v "$HOST_MODEL_DIR:/home/lms/.lmstudio/models")
  else
    docker volume inspect "$LMS_MODEL_MOUNT" >/dev/null 2>&1 \
      || docker volume create "$LMS_MODEL_MOUNT" >/dev/null
    MODEL_MOUNT_OPT=(-v "$LMS_MODEL_MOUNT:/home/lms/.lmstudio/models")
  fi
  echo "[+] model mount: $LMS_MODEL_MOUNT"
else
  echo "[=] model mount 없음 — 이미지 내장 모델 사용 ($LMS_IMAGE)"
fi

# ── 3) lms-N 기동 ──────────────────────────────────────────────────────────
# GPU 배치: 백엔드 i → GPU (i-1). '--gpus all' 을 N개에 똑같이 주면 전원이 같은 GPU0 에
#   적재된다. GPU 수를 넘어서면 순환(초과 구독이 승인된 경우에만 도달).
for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
  NAME="lms-$i"
  GPU_OPT=()
  if [ "$USE_GPU" = "1" ]; then
    if [ "$GPU_COUNT" -gt 0 ]; then
      GPU_OPT=(--gpus "device=$(( (i-1) % GPU_COUNT ))")
    else
      GPU_OPT=(--gpus all)
    fi
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" \
    --network "$LMS_NETWORK_NAME" \
    --network-alias lms \
    --restart unless-stopped \
    "${GPU_OPT[@]}" \
    "${MODEL_MOUNT_OPT[@]}" \
    -v "$SCRIPT_DIR/entrypoint.lms.sh:/usr/local/bin/entrypoint.lms.sh:ro" \
    --entrypoint /usr/local/bin/entrypoint.lms.sh \
    -e LMS_MODEL="$LMS_MODEL" \
    -e LMS_PORT="$LMS_PORT" \
    -e LMS_HEALTH_TRIES="$LMS_HEALTH_TRIES" \
    -e LMS_CONTEXT_LENGTH="$LMS_CONTEXT_LENGTH" \
    -e LMS_GPU="$LMS_GPU" \
    -e LMS_PARALLEL="$LMS_PARALLEL" \
    -e LMS_SKIP_GET="$LMS_SKIP_GET" \
    -e LMS_GET_TIMEOUT="$LMS_GET_TIMEOUT" \
    -e TZ="$TZ" \
    "$LMS_IMAGE" >/dev/null
  if [ "$USE_GPU" = "1" ] && [ "$GPU_COUNT" -gt 0 ]; then
    echo "[+] $NAME 기동 (GPU $(( (i-1) % GPU_COUNT )))"
  else
    echo "[+] $NAME 기동"
  fi
done

# ── 4) 백엔드 헬스 대기 ────────────────────────────────────────────────────
for i in $(seq 1 "$LMS_BACKEND_COUNT"); do
  NAME="lms-$i"
  echo "[*] $NAME /v1/models 대기 (최대 240s)"
  TRIES=0
  until docker exec "$NAME" curl -fsS "http://127.0.0.1:${LMS_PORT}/v1/models" >/dev/null 2>&1; do
    TRIES=$((TRIES+1))
    [ "$TRIES" -ge 120 ] && { echo "[!] $NAME 무응답 — docker logs $NAME"; exit 1; }
    docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true \
      || { echo "[!] $NAME 종료됨 — docker logs $NAME"; exit 1; }
    sleep 2
  done
  echo "[+] $NAME ready"
done

# ── 5) gateway 기동 ────────────────────────────────────────────────────────
docker rm -f "$GATEWAY_CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$GATEWAY_CONTAINER_NAME" \
  --network "$LMS_NETWORK_NAME" \
  --restart unless-stopped \
  -p "${GATEWAY_BIND_HOST}:${GATEWAY_PORT}:${GATEWAY_INTERNAL_PORT}" \
  -v "$SCRIPT_DIR/nginx.conf.template:/etc/nginx/templates/default.conf.template:ro" \
  -e LMS_PORT="$LMS_PORT" \
  -e LMS_UPSTREAM_SERVERS="$(build_upstream)" \
  -e TZ="$TZ" \
  "$GATEWAY_IMAGE" >/dev/null
echo "[+] $GATEWAY_CONTAINER_NAME 기동 (${GATEWAY_BIND_HOST}:${GATEWAY_PORT})"

# ── 6) gateway 헬스 대기 ───────────────────────────────────────────────────
echo "[*] gateway /v1/models 대기 (최대 90s)"
TRIES=0
until curl -fsS "${GW_URL}/v1/models" >/dev/null 2>&1; do
  TRIES=$((TRIES+1))
  if [ "$TRIES" -ge 45 ]; then
    echo "[!] gateway 무응답 — docker logs $GATEWAY_CONTAINER_NAME"
    docker logs "$GATEWAY_CONTAINER_NAME" 2>&1 | tail -10
    exit 1
  fi
  docker inspect -f '{{.State.Running}}' "$GATEWAY_CONTAINER_NAME" 2>/dev/null | grep -q true \
    || { echo "[!] gateway 종료됨(재시작 루프 의심) — docker logs $GATEWAY_CONTAINER_NAME"; \
         docker logs "$GATEWAY_CONTAINER_NAME" 2>&1 | tail -10; exit 1; }
  sleep 2
done
echo "[+] gateway ready"

# ── 7) claude 기동 ─────────────────────────────────────────────────────────
CODE_MOUNT_OPT=()
if [ -n "$MOUNT_CODE_DIR" ]; then
  HOST_CODE_DIR="${MOUNT_CODE_DIR/#\~/$HOME}"
  mkdir -p "$HOST_CODE_DIR"
  CODE_MOUNT_OPT=(-v "$HOST_CODE_DIR:/home/ubuntu/code")
fi

docker volume inspect "$CLAUDE_HOME_VOLUME" >/dev/null 2>&1 \
  || docker volume create "$CLAUDE_HOME_VOLUME" >/dev/null

docker rm -f "$CLAUDE_CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CLAUDE_CONTAINER_NAME" \
  --network "$LMS_NETWORK_NAME" \
  --restart unless-stopped \
  -it \
  -v "$CLAUDE_HOME_VOLUME:/home/ubuntu" \
  "${CODE_MOUNT_OPT[@]}" \
  -v "$SCRIPT_DIR/entrypoint.cc.sh:/usr/local/bin/entrypoint.cc.sh:ro" \
  --entrypoint /usr/local/bin/entrypoint.cc.sh \
  `# ~/.local/bin 선순위 — entrypoint 가 만드는 claude shim(X-Session affinity 보장)이` \
  `# 'docker exec cc-step4 claude' 처럼 셸 미경유 진입에서도 잡히게 한다. docker exec 는` \
  `# 컨테이너 생성 시 env 를 상속하므로 여기서 PATH 를 지정해야 효과가 있다.` \
  -e PATH="/home/ubuntu/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e ANTHROPIC_BASE_URL="http://${GATEWAY_CONTAINER_NAME}:${GATEWAY_INTERNAL_PORT}" \
  -e ANTHROPIC_AUTH_TOKEN=lms \
  -e ANTHROPIC_MODEL="$LMS_MODEL" \
  -e ANTHROPIC_SMALL_FAST_MODEL="$LMS_MODEL" \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="$CLAUDE_MAX_OUTPUT_TOKENS" \
  -e CLAUDE_DIET="$CLAUDE_DIET" \
  -e GW_HOST="$GATEWAY_CONTAINER_NAME" \
  -e GW_PORT="$GATEWAY_INTERNAL_PORT" \
  -e LMS_MODEL="$LMS_MODEL" \
  -e API_TIMEOUT_MS="$API_TIMEOUT_MS" \
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  -e TZ="$TZ" \
  "$CLAUDE_IMAGE" sleep infinity >/dev/null

echo "[+] $CLAUDE_CONTAINER_NAME 기동"
echo
echo "─────────────────────────────────────────────────────────────"
echo " 게이트 판정: $0 --check      (도달·shim·VRAM)"
echo "              $0 --distribute (2 분산)"
echo "              $0 --affinity   (3 세션 고정)"
echo "              $0 --sse        (SSE 스트리밍)"
echo "              $0 --resilience (재기동 내성)"
echo " 접속:        docker exec -it $CLAUDE_CONTAINER_NAME bash  →  cc"
echo " 게이트웨이:  ${GW_URL}/v1/models"
echo " 정지:        $0 --stop"
echo "─────────────────────────────────────────────────────────────"
